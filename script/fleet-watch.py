#!/usr/bin/env python3
"""One bounded watchdog pass; schedule every five minutes outside the coordinator.

The private config keeps repo_roots (checkout paths), host_caps, and the per-host
paths backup.stamp, heavy_gate.hosts and wrap_up.hosts. A backup host may also set
coordinator_watch. The Run id and coordinator terminal come from Orca each pass
(run-list --full, then run-show --full). Each repo owner/name comes from the origin
remote of a repo_roots path. Issue scan is on when that Run exists. Fleet watch
restarts only a verifier, rework worker, or scanned issue it started. A failed
restart is parked once. A stall it did not start is reported once and not stopped.
A pass that finds no coordinator Run logs `no coordinator run`,
leaves notices queued, and exits 0.
The same pass dispatches one verifier when head-checks succeeded and the head has no Verdict,
once per head (babysit.per_pass_cap, default 2). Fix workers and shipping runs stay in issue_scan.
--babysit-dry-run lists those actions and starts nothing. --state FILE persists missing-waiter timers and alerts.
Counts every active Dispatch, including descendants. Restarts a stalled worker only when this pass started it.
"""
import argparse
import calendar
import contextlib
import copy
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import worker_count  # noqa: E402  one count rule shared with fleet-workers.py (#1942)

def _load_receipt_state():
    path = Path(__file__).resolve().parent / 'receipt-state.py'
    spec = importlib.util.spec_from_file_location('receipt_state', path)
    if spec is None or spec.loader is None:
        raise ImportError('receipt-state.py missing beside fleet-watch.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rs = _load_receipt_state()

_SIBLINGS = {}


def _sibling(name, filename):
    module = _SIBLINGS.get(name)
    if module is not None:
        return module
    path = Path(__file__).resolve().parent / filename
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError('%s missing beside fleet-watch.py' % filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _SIBLINGS[name] = module
    return module


def _with_preamble(text, role):
    brief_role = 'fullstack-dev' if role in (None, '', 'builder') else role
    return _sibling('worker_preamble', 'worker-preamble.py').prepend(text, brief_role)


class Urgent(str):
    """A notice that skips the digest wait. alerts() returns this type, so routing never reads the text."""


class Verdict(str):
    """A Verdict notice. ``author`` is the author dispatch named on the Verdict line, or None."""
    author = None


class OrcaReadError(Exception):
    """Orca inventory could not be read or parsed."""


class TerminalNotFound(OrcaReadError):
    """Orca reports this terminal handle does not exist (lead pane gone)."""


SEND_ERRORS = (
    subprocess.CalledProcessError,
    subprocess.TimeoutExpired,
    RuntimeError,
    OSError,
    ValueError,
    KeyError,
    OrcaReadError,
)
NOTICE_MAX_AGE_SECONDS = 24 * 60 * 60
STALL_RESTART_ATTEMPTS = 1  # a failed restart is parked; it is not tried again
DIGEST_SECONDS = 600
ORCA_SKIP_NOTICE = 'Orca could not be read; skipping worker inbox alerts this run'
FAULT_REPO = 'mingster/agent-state'
NO_COORDINATOR_RUN = 'no coordinator run'


def _json_object_from_orca_process(proc):
    """If stdout or stderr is a JSON object, return it; else None."""
    for part in (proc.stdout, proc.stderr):
        if not part or not str(part).strip():
            continue
        try:
            data = json.loads(part.strip())
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            return data
    return None


_TERMINAL_SHOW_GONE_CODES = frozenset(('terminal_handle_stale', 'terminal_not_found'))


def _terminal_error_code(value):
    """Orca error code: top-level string, or nested error.code / error when dict."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ('code', 'message', 'error'):
            v = value.get(key)
            if isinstance(v, str) and v:
                return v
    return None


def _orca_failed_reply_error_code(receipt):
    """Orca JSON reply with ok=false: stable error code string, or None."""
    if not isinstance(receipt, dict) or receipt.get('ok') is not False:
        return None
    code = _terminal_error_code(receipt.get('error'))
    if code:
        return code
    for key in ('code', 'errors', 'reason'):
        code = _terminal_error_code(receipt.get(key))
        if code:
            return code
    return None


def orchestration_failure_log_code(exc):
    """Log segment for a failed orchestration rpc: Orca error code if present, else exception type name."""
    code = getattr(exc, 'orca_error_code', None)
    if isinstance(code, str) and code:
        return code
    chain = exc.__cause__ if exc.__cause__ is not None else exc
    if isinstance(chain, subprocess.CalledProcessError):
        for part in (chain.stdout, chain.stderr):
            if not part or not str(part).strip():
                continue
            try:
                data = json.loads(part.strip())
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                parsed = _orca_failed_reply_error_code(data)
                if parsed:
                    return parsed
    return type(exc).__name__


def _receipt_denies_terminal_show(args_tuple, receipt):
    """True when terminal show failed for a missing or stale handle (exact Orca error codes)."""
    if len(args_tuple) < 2 or args_tuple[0] != 'terminal' or args_tuple[1] != 'show':
        return False
    if not isinstance(receipt, dict):
        return False
    if receipt.get('ok') is not False:
        return False
    err = receipt.get('error')
    code = _terminal_error_code(err)
    if code in _TERMINAL_SHOW_GONE_CODES:
        return True
    if isinstance(err, list):
        for item in err:
            if _terminal_error_code(item) in _TERMINAL_SHOW_GONE_CODES:
                return True
    for key in ('errors', 'code', 'message', 'reason'):
        if _terminal_error_code(receipt.get(key)) in _TERMINAL_SHOW_GONE_CODES:
            return True
    return False


def rpc(*args):
    is_direct_script = bool(args) and (args[0] == 'bash' or str(args[0]).endswith('worker-startup.sh'))
    if is_direct_script:
        cmd = list(args)
        timeout = 180
    else:
        command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
        cmd = command + list(args) + ['--json']
        timeout = 15
    try:
        output = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        raise OrcaReadError('orca CLI failed') from e

    if output.returncode != 0:
        receipt = _json_object_from_orca_process(output)
        if isinstance(receipt, dict) and _receipt_denies_terminal_show(args, receipt):
            raise TerminalNotFound('terminal_not_found') from subprocess.CalledProcessError(
                output.returncode, cmd, output.stdout, output.stderr
            )
        code = _orca_failed_reply_error_code(receipt) if isinstance(receipt, dict) else None
        err = OrcaReadError(code or 'orca CLI failed')
        err.orca_error_code = code
        raise err from subprocess.CalledProcessError(
            output.returncode, cmd, output.stdout, output.stderr
        )

    try:
        receipt = json.loads(output.stdout)
    except json.JSONDecodeError as e:
        receipt = _json_object_from_orca_process(output)
        if not isinstance(receipt, dict):
            raise OrcaReadError('invalid JSON from orca') from e
    if not isinstance(receipt, dict):
        raise OrcaReadError('orca body is not a JSON object')
    if receipt.get('ok') is False:
        if _receipt_denies_terminal_show(args, receipt):
            raise TerminalNotFound('terminal_not_found')
        code = _orca_failed_reply_error_code(receipt)
        err = OrcaReadError(code or 'Orca refused inventory')
        err.orca_error_code = code
        raise err
    if 'result' not in receipt:
        raise OrcaReadError('missing result in orca reply')
    return receipt['result']


def deduplicate_workers(workers):
    """Deduplicate observations across pages and retries by dispatch and resource identity."""
    by_dispatch = {}
    for w in workers:
        did = w.get('dispatchId')
        if did:
            if did not in by_dispatch:
                by_dispatch[did] = w
            else:
                existing = by_dispatch[did]
                by_dispatch[did] = {**existing, **w}
        else:
            by_dispatch[id(w)] = w

    def worker_priority(w):
        status = worker_inventory_status(w)
        if status in ('running', 'dispatched', 'active', 'pending'):
            return 3
        if status == 'completed':
            return 2
        return 1

    sorted_workers = sorted(by_dispatch.values(), key=worker_priority, reverse=True)
    deduped = []
    seen_resources = set()

    for w in sorted_workers:
        resource = w.get('resource') or {}
        wt = w.get('worktreeId') or resource.get('worktreeId') or ((w.get('projection') or {}).get('workspace') or {}).get('id')
        term = w.get('agentTerminalHandle') or resource.get('terminalHandle') or w.get('terminal')
        host = projection_host_id(w)

        res_keys = []
        if wt:
            res_keys.append(('worktree', host, wt))
        if term:
            res_keys.append(('terminal', host, term))

        if res_keys and any(k in seen_resources for k in res_keys):
            continue
        for k in res_keys:
            seen_resources.add(k)
        deduped.append(w)
    return deduped


def worker_inventory_status(worker):
    """Dispatch status for admit/classify: nested dispatchStatus, else map flat Orca state."""
    w = worker or {}
    status = w.get('dispatchStatus') or w.get('status')
    if status:
        return status
    state = w.get('state')
    if state in ('succeeded', 'completed'):
        return 'completed'
    if state == 'released':
        return 'released'
    if state == 'release_unknown':
        return 'release_unknown'
    if state in ('running', 'ready', 'accepted', 'active', 'pending'):
        return 'running'
    if state == 'failed':
        return 'failed'
    return state


def worker_terminal_released(worker):
    """True when Orca has released the worker terminal (flat and nested rows)."""
    w = worker or {}
    evidence = w.get('evidence') or {}
    projection = w.get('projection') or {}
    status = worker_inventory_status(w)
    if status == 'released':
        return True
    if w.get('released') is True or evidence.get('released') is True or projection.get('released') is True:
        return True
    if evidence.get('release') in (True, 'confirmed'):
        return True
    resource = w.get('resource') or {}
    if 'released' in (resource.get('releaseState'), resource.get('ownershipState')):
        return True
    # A finished dispatch whose resource Orca no longer has holds no terminal, even when it reports "retained" (#1273).
    if (status == 'completed' or worker_settled_kind(w) is not None) \
            and (projection.get('resource') or {}).get('state') == 'absent' \
            and resource.get('retainedReason') != 'unpushed':
        return True
    # Orca drops the resource and terminal of a dispatch it already released (worker-release says already_released).
    if (status == 'completed' and 'resource' in w and not resource
            and not w.get('agentTerminalHandle') and not w.get('terminalState')):
        return True
    return w.get('terminalState') == 'released' or w.get('stage') == 'released'


def worker_freed_by_terminal_exit(worker):
    """Worker-list row with exited liveness and a released terminal does not retain a slot.

    Full rows place liveness under projection.liveness.verdict; flat rows may set top-level liveness.
    """
    w = worker or {}
    return worker_liveness_verdict(w) == 'exited' and w.get('terminalState') == 'released'


_SETTLED_KINDS = ('succeeded', 'stopped', 'failed')
_SETTLED_DISPATCH_STATUSES = ('completed', 'succeeded', 'failed', 'cancelled', 'stopped')
_ARG_BOUNDARY = set(' \t/:=\'",;')


def worker_settled_kind(worker):
    """succeeded, stopped, or failed. completed alone is not settled."""
    w = worker or {}
    proj = w.get('projection') or {}
    stage = proj.get('stage')
    stage_worker = stage.get('worker') if isinstance(stage, dict) else None
    for value in (w.get('workerState'), w.get('state'), w.get('outcome'), proj.get('outcome'), stage_worker):
        if value in _SETTLED_KINDS:
            return value
    return None


def mail_worker(notify, worker, text, allow_settled=False):
    """Send text to a worker terminal unless its dispatch is released, or settled when allow_settled is off.

    Mail to such a worker is never read and comes back to the coordinator as an escalation (#1089).
    Refused mail logs one line. True when sent.
    """
    reason = ''
    if worker_terminal_released(worker):
        reason = 'released'
    elif not allow_settled:
        reason = worker_settled_kind(worker) or ''
    if reason:
        line = 'fleet-watch: mail skipped for %s, dispatch %s' % (worker.get('dispatchId') or worker.get('dispatch_id') or '?', reason)
        print(line, file=sys.stderr)
        log_fleet_watch(line)
        return False
    notify(worker_terminal_handle(worker), text)
    return True


def release_unknown_row(worker):
    """True when the terminal no longer resolves, or release itself came back release_unknown."""
    w = worker or {}
    if w.get('terminalState') == 'release_unknown':
        return True
    evidence = w.get('evidence') or {}
    return bool(
        worker_inventory_status(w) == 'release_unknown' or
        w.get('releaseStatus') == 'release_unknown' or
        evidence.get('release') == 'release_unknown' or
        w.get('released') == 'release_unknown'
    )


def safe_workspace_path(path):
    """Absolute workspace path worth comparing to a process. Short paths match too much."""
    if not isinstance(path, str):
        return ''
    path = path.rstrip('/')
    if len(path) < 2 or not path.startswith('/') or path.startswith('//'):
        return ''
    if len([part for part in path.split('/') if part]) < 3:
        return ''
    return path


def worker_on_local_machine(worker, config, env_names):
    """True when this process can see that worker's host. A remote row stays occupying."""
    raw = projection_host_id(worker)
    if _is_local_coordinator_host(raw, config):
        return True
    return _is_local_coordinator_host(host_cap_name(raw, config or {}, env_names or {}), config)


def command_names_path(command, path):
    """True when path is one argument, or the prefix of an argument, not a sibling prefix."""
    if not command or not path:
        return False
    start = 0
    while True:
        found = command.find(path, start)
        if found < 0:
            return False
        end = found + len(path)
        before = command[found - 1] if found else ''
        after = command[end] if end < len(command) else ''
        before_ok = found == 0 or before in _ARG_BOUNDARY
        after_ok = end == len(command) or after in _ARG_BOUNDARY
        if before_ok and after_ok:
            return True
        start = found + 1


def cwd_is_workspace(cwd, path):
    if not isinstance(cwd, str) or not path:
        return False
    if cwd.endswith(' (deleted)'):
        cwd = cwd[:-len(' (deleted)')]
    if len(cwd) > 1:
        cwd = cwd.rstrip('/')
    return cwd == path or cwd.startswith(path + '/')


def place_keys(path):
    """Recorded path and its real path. macOS reports /var cwd values under /private/var."""
    if not path:
        return []
    keys = [path]
    try:
        real = os.path.realpath(path)
    except OSError:
        real = ''
    if real and real not in keys:
        keys.append(real)
    return keys


def process_uses_workspace(path, commands, cwds):
    places = place_keys(path)
    for cwd in cwds:
        raw = cwd[:-len(' (deleted)')] if isinstance(cwd, str) and cwd.endswith(' (deleted)') else cwd
        for key in place_keys(raw):
            for place in places:
                if cwd_is_workspace(key, place):
                    return True
    for place in places:
        for command in commands:
            if command_names_path(command, place):
                return True
    return False


def worktree_disposition(path, run=None):
    """removed, clean, dirty, or unknown. unknown keeps the seat."""
    if not safe_workspace_path(path):
        return 'unknown'
    try:
        if not os.path.exists(path):
            return 'removed'
        if not os.path.isdir(path):
            return 'unknown'
    except OSError:
        return 'unknown'
    run = run or subprocess.run
    try:
        proc = run(
            ['git', '-C', path, '-c', 'status.showUntrackedFiles=all', 'status', '--porcelain', '--untracked-files=all'],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'
    if getattr(proc, 'returncode', 1) != 0:
        return 'unknown'
    if (getattr(proc, 'stdout', '') or '').strip() == '':
        return 'clean'
    return 'dirty'


class GoneProof:
    """One process and worktree snapshot. failed means the process list could not be read."""

    def __init__(self, commands=(), cwds=(), dispositions=None, failed=False):
        self.commands = commands
        self.cwds = cwds
        self.dispositions = dispositions or {}
        self.failed = failed

    def clears(self, path):
        if self.failed or not path:
            return False
        if process_uses_workspace(path, self.commands, self.cwds):
            return False
        return self.dispositions.get(path) in ('removed', 'clean')


def lsof_cwds(text):
    cwds = []
    want = False
    for line in (text or '').splitlines():
        if line.startswith('f'):
            want = line[1:] == 'cwd'
            continue
        if want and line.startswith('n'):
            cwds.append(line[1:])
            want = False
            continue
        if line.startswith('p'):
            want = False
    return cwds


def proc_cwds(root='/proc'):
    """Working directories of this uid, or None when /proc cannot be listed."""
    try:
        uid = os.getuid()
        names = os.listdir(root)
    except OSError:
        return None
    cwds = []
    for name in names:
        if not name.isdigit():
            continue
        pid_path = os.path.join(root, name)
        try:
            if os.stat(pid_path).st_uid != uid:
                continue
            dest = os.readlink(os.path.join(pid_path, 'cwd'))
        except OSError:
            continue
        if dest:
            cwds.append(dest)
    return cwds


def read_process_snapshot(run=None):
    """(commands, cwds) or None. An empty cwd list cannot prove that no process is using a workspace."""
    run = run or subprocess.run
    try:
        ps = run(['ps', '-axww', '-o', 'command='], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if getattr(ps, 'returncode', 1) != 0:
        return None
    commands = tuple((ps.stdout or '').splitlines())
    cwds = None
    if sys.platform != 'darwin' and os.path.isdir('/proc'):
        cwds = proc_cwds('/proc')
    if not cwds:
        try:
            listed = run(['lsof', '-n', '-P', '-d', 'cwd', '-Fn'], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if getattr(listed, 'returncode', 1) not in (0, 1):
            return None
        cwds = lsof_cwds(listed.stdout or '')
    if not cwds:
        return None
    return commands, tuple(cwds)


def build_gone_proof(workers, config, env_names, run=None):
    """Snapshot processes once, then read only the local settled release_unknown worktrees."""
    paths = []
    for worker in workers or []:
        if not isinstance(worker, dict) or worker_settled_kind(worker) is None:
            continue
        if not release_unknown_row(worker) or not worker_on_local_machine(worker, config, env_names):
            continue
        path = safe_workspace_path(worker_checkout_path(worker))
        if path:
            paths.append(path)
    if not paths:
        return GoneProof()
    snapshot = read_process_snapshot(run)
    if snapshot is None:
        return GoneProof(failed=True)
    commands, cwds = snapshot
    dispositions = {path: worktree_disposition(path, run) for path in dict.fromkeys(paths)}
    return GoneProof(commands, cwds, dispositions, False)


def worker_proven_gone(worker, proof, config, env_names):
    """True only when every proof check passed. A missing proof keeps the seat."""
    if proof is None or proof.failed:
        return False
    if worker_settled_kind(worker) is None or not release_unknown_row(worker):
        return False
    if not worker_on_local_machine(worker, config, env_names):
        return False
    path = safe_workspace_path(worker_checkout_path(worker))
    if not path:
        return False
    return proof.clears(path)


def _resource_holds_seat(resource):
    if not isinstance(resource, dict):
        return False
    if resource.get('retainedReason') == 'unpushed':
        return True
    if resource.get('ownershipState') == 'owned':
        return True
    return resource.get('releaseState') in ('pending', 'retained')


def _unpushed_resource(worker):
    """Orca itself says the retained resource holds unpushed commits."""
    w = worker or {}
    for resource in (w.get('resource'), (w.get('projection') or {}).get('resource')):
        if isinstance(resource, dict) and resource.get('retainedReason') == 'unpushed':
            return True
    return False


def worktree_has_unpushed_commits(path):
    """True when HEAD has commits on no remote. Unknown keeps the seat."""
    try:
        proc = subprocess.run(
            ['git', '-C', path, 'rev-list', '--count', 'HEAD', '--not', '--remotes'],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return True
    if getattr(proc, 'returncode', 1) != 0:
        return True
    try:
        return int((proc.stdout or '0').strip() or '0') > 0
    except ValueError:
        return True


def worker_exit_still_holds_seat(worker):
    """An exited worker keeps a seat only while Orca owns a resource or the visible worktree has unpushed commits.

    worker-release can return ok with processAction none when the execution host is missing.
    The list row stays terminalState retained and projection.resource state absent. That is not a seat.
    """
    w = worker or {}
    projection = w.get('projection') or {}
    if _resource_holds_seat(w.get('resource')) or _resource_holds_seat(projection.get('resource')):
        return True
    path = safe_workspace_path(worker_checkout_path(w))
    if not path or not os.path.isdir(path):
        return False
    return worktree_has_unpushed_commits(path)


def worker_retained_resource_live(worker):
    """A retained row holds a seat only while its resource is live: a running terminal,
    or a worktree on disk with unpushed commits or dirty files. Gone, or clean and pushed, is not a seat."""
    if worker_liveness_verdict(worker) == 'live':
        return True
    path = worker_checkout_path(worker)
    if not path or not os.path.exists(path):
        return False
    if not os.path.isdir(path):
        return True
    return worktree_has_unpushed_commits(path) or worktree_disposition(path) != 'clean'


def classify_worker(worker, proof=None, config=None, env_names=None):
    """Classifies a worker and determines if it occupies a host slot with evidence.
    Returns: (occupies: bool, classification: dict, has_release_unknown: bool)
    """
    status = worker_inventory_status(worker)
    projection = worker.get('projection') or {}
    host = projection_host_id(worker)
    role = projection.get('role') or worker.get('role') or 'builder'
    is_child = bool(worker.get('parentDispatchId') or role == 'child')
    is_qa = role in ('qa', 'qa-sdet', 'reviewer')
    evidence_dict = worker.get('evidence') or {}

    release_unknown = bool(
        status == 'release_unknown' or
        worker.get('releaseStatus') == 'release_unknown' or
        evidence_dict.get('release') == 'release_unknown' or
        worker.get('released') == 'release_unknown'
    )

    pushed = bool(
        worker.get('pushed') is True or
        evidence_dict.get('pushed') is True or
        projection.get('pushed') is True or
        worker.get('pushConfirmed') is True or
        evidence_dict.get('push') in (True, 'confirmed')
    )

    released = worker_terminal_released(worker) and not release_unknown

    dispatch_id = worker.get('dispatchId')

    if worker_proven_gone(worker, proof, config, env_names):
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'freed',
            'role': role,
            'evidence': {
                'status': status,
                'pushed': pushed,
                'released': False,
                'release_unknown': True,
                'proven_gone': True,
            },
        }
        return False, info, False

    if release_unknown:
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'retained',
            'role': role,
            'evidence': {'status': status, 'pushed': pushed, 'released': False, 'release_unknown': True}
        }
        return True, info, True

    if worker_freed_by_terminal_exit(worker):
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'freed',
            'role': role,
            'evidence': {
                'status': status,
                'pushed': pushed,
                'released': True,
                'liveness': 'exited',
                'terminalState': 'released',
            }
        }
        return False, info, False

    if worker_liveness_verdict(worker) == 'exited':
        holds_seat = worker_exit_still_holds_seat(worker)
        if holds_seat and status in _SETTLED_DISPATCH_STATUSES and not _unpushed_resource(worker):
            # A settled, exited worker holds a seat only for unpushed work, released or not (#1411).
            path = safe_workspace_path(worker_checkout_path(worker))
            holds_seat = bool(path and os.path.isdir(path) and worktree_has_unpushed_commits(path))
        if holds_seat and status in ('dispatched', 'running', 'pending', 'active'):
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'retained',
                'role': role,
                'evidence': {
                    'status': status,
                    'pushed': pushed,
                    'released': False,
                    'liveness': 'exited',
                },
            }
            return True, info, False
        if not holds_seat:
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'freed',
                'role': role,
                'evidence': {
                    'status': status,
                    'pushed': pushed,
                    'released': False,
                    'liveness': 'exited',
                },
            }
            return False, info, False

    if status in ('dispatched', 'running', 'pending', 'active'):
        category = 'live_child' if is_child else ('live_qa' if is_qa else 'live_builder')
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'live',
            'role': 'child' if is_child else ('qa' if is_qa else 'builder'),
            'live_type': category,
            'evidence': {'status': status, 'role': role, 'live': True}
        }
        return True, info, False

    if status == 'completed' and worker_is_settled_remote(worker):
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'freed',
            'role': role,
            'evidence': {'status': status, 'pushed': pushed, 'released': False, 'settled_remote': True}
        }
        return False, info, False

    if status == 'completed':
        # A released terminal frees the seat; a worker that pushed nothing (verifier, auditor) has nothing to keep.
        if released:
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'freed',
                'role': role,
                'evidence': {'status': status, 'pushed': pushed, 'released': True}
            }
            return False, info, False
        elif (
            not release_unknown_row(worker)
            and not _unpushed_resource(worker)
            and worker_on_local_machine(worker, config, env_names)
            and not worker_retained_resource_live(worker)
        ):
            # Settled local row whose retained resource is not live and nothing unpushed: only a row, not a seat (#1155).
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'freed',
                'role': role,
                'evidence': {'status': status, 'pushed': pushed, 'released': False, 'no_seat_evidence': True}
            }
            return False, info, False
        else:
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'retained',
                'role': role or 'author',
                'evidence': {'status': status, 'pushed': pushed, 'released': released}
            }
            return True, info, False

    if status == 'released':
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'freed',
            'role': role,
            'evidence': {'status': status, 'pushed': pushed, 'released': True}
        }
        return False, info, False

    info = {
        'dispatchId': dispatch_id,
        'host': host,
        'category': 'inactive',
        'role': role,
        'evidence': {'status': status}
    }
    return False, info, False


def list_pages(*command):
    """Yield every page of an orca list command. A page that cannot prove it is the last, or a repeated cursor, raises.

    Current Orca puts nextCursor at the top level and omits it on the last page. Older Orca nested it under page
    with hasMore.
    """
    cursor, seen = None, set()
    while True:
        result = rpc(*command, *(['--cursor', cursor] if cursor else []))
        if not isinstance(result, dict):
            raise OrcaReadError('list page is not an object')
        sub = command[1] if len(command) > 1 else None
        if sub == 'run-list':
            if 'runs' not in result or not isinstance(result['runs'], list):
                raise OrcaReadError('malformed run-list page')
        elif sub == 'worker-list':
            if 'workers' not in result or not isinstance(result['workers'], list):
                raise OrcaReadError('malformed worker-list page')
        yield result
        if 'page' in result:
            page = result['page']
            if not isinstance(page, dict) or 'hasMore' not in page:
                raise OrcaReadError('bad page')
            if page['hasMore'] not in (True, False):
                raise OrcaReadError('bad page')
            cursor = page.get('nextCursor') if page['hasMore'] else None
            if cursor is None and page['hasMore']:
                raise OrcaReadError('bad cursor')
        else:
            cursor = result.get('nextCursor')
        if cursor is None:
            return
        if not isinstance(cursor, str) or not cursor or cursor in seen:
            raise OrcaReadError('bad cursor')
        seen.add(cursor)


def read_full_inbox_bodies():
    """Message id to full body, from one inbox --full read (the concise view cuts bodies at 200 characters)."""
    inbox = rpc('orchestration', 'inbox', '--limit', '5000', '--full')
    if not isinstance(inbox, dict) or not isinstance(inbox.get('messages'), list):
        raise OrcaReadError('malformed full inbox reply')
    return {m.get('id'): str(m.get('body') or '') for m in inbox['messages'] if isinstance(m, dict)}


def read_orca_inventory(config):
    """Read inbox, workers, lead terminals, and pgrep in one pass; validate JSON shapes. Raises OrcaReadError."""
    inbox = rpc('orchestration', 'inbox', '--limit', str(INBOX_LIMIT))
    if not isinstance(inbox, dict) or 'messages' not in inbox or not isinstance(inbox['messages'], list):
        raise OrcaReadError('malformed inbox reply')
    for m in inbox['messages']:
        if not isinstance(m, dict):
            raise OrcaReadError('malformed inbox message element')
    workers = fetch_workers(config)
    for w in workers:
        if not isinstance(w, dict):
            raise OrcaReadError('malformed worker element')
        did = w.get('dispatchId')
        if did is None or (isinstance(did, str) and not did.strip()):
            raise OrcaReadError('worker missing dispatchId')
    alive = {}
    for run in config['runs']:
        try:
            proc = subprocess.run(
                ['pgrep', '-f', run['waiter_pattern']], capture_output=True, timeout=5
            )
        except (subprocess.SubprocessError, OSError) as e:
            raise OrcaReadError('pgrep failed') from e
        alive[run['id']] = proc.returncode == 0
    leads = {}
    for lead in config.get('leads', []):
        handle = lead['terminal']
        try:
            rpc('terminal', 'show', '--terminal', handle)
        except TerminalNotFound:
            leads[handle] = False
            continue
        leads[handle] = True
    return {'messages': inbox['messages'], 'workers': workers, 'alive': alive, 'leads': leads}


def worker_run_id(w):
    """Orca run id from a worker-list row when present (several JSON shapes)."""
    w = w or {}
    for key in ('runId', 'run_id'):
        v = w.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    proj = w.get('projection') or {}
    for key in ('runId', 'run_id', 'run'):
        v = proj.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    resource = w.get('resource') or {}
    for key in ('runId', 'run_id'):
        v = resource.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    scope = w.get('scope') or {}
    v = scope.get('run')
    if isinstance(v, str) and v.strip():
        return v.strip()
    return ''


def default_list_run_id(config):
    """When exactly one run is configured, use it as fallback for rows with no run id (legacy state)."""
    runs = config.get('runs') or []
    if len(runs) == 1:
        rid = runs[0].get('id', '')
        return rid.strip() if isinstance(rid, str) else ''
    return ''


def run_id_for_stall_restart(w, persisted=''):
    """Resolved run id for worker-start: row fields, list pass tag, then persisted fallback."""
    r = worker_run_id(w)
    if r:
        return r
    if isinstance(w, dict):
        tag = w.get('_fleet_watch_list_run')
        if isinstance(tag, str) and tag.strip():
            return tag.strip()
    if isinstance(persisted, str) and persisted.strip():
        return persisted.strip()
    return ''


def task_rows(run_id):
    """Map task id to its task-list --full row for a Run; empty when the task list cannot be read (worker rows then
    carry no title or spec)."""
    try:
        result = rpc('orchestration', 'task-list', '--run', run_id, '--full')
    except Exception:
        return {}
    tasks = result.get('tasks') if isinstance(result, dict) else None
    return {t['id']: t for t in tasks or [] if isinstance(t, dict) and t.get('id')}


def fetch_workers(config):
    """Retrieve and deduplicate workers across runs and pagination.

    worker-list without --run shows only the caller's Run, so without configured runs read every Run.
    Rows that omit run id get _fleet_watch_list_run set from the list pass for stall restarts.
    """
    run_ids = [run['id'] for run in config.get('runs', [])]
    if not run_ids:
        run_ids = [run['id'] for page in list_pages('orchestration', 'run-list') for run in page['runs']]
    workers = []
    for run_id in run_ids:
        tasks = task_rows(run_id)
        for result in list_pages('orchestration', 'worker-list', '--run', run_id, '--include-remote', '--full'):
            for w in result.get('workers', []):
                task = tasks.get(worker_task_id(w)) if isinstance(w, dict) else None
                if task and task.get('title'):
                    w['_task_title'] = task['title']
                if task and isinstance(task.get('spec'), str):
                    w['_task_spec'] = task['spec']
                if isinstance(w, dict) and not worker_run_id(w):
                    w['_fleet_watch_list_run'] = run_id
                workers.append(w)
    return deduplicate_workers(workers)


COORDINATOR_MAX_LOAD_PER_CORE = 0.7
COORDINATOR_MIN_FREE_GB = 4.0


def coordinator_load_per_core():
    """1-minute load average per CPU core on this host (or FLEET_WATCH_TEST_LOAD_PER_CORE override)."""
    override = os.environ.get('FLEET_WATCH_TEST_LOAD_PER_CORE')
    if override is not None and str(override).strip() != '':
        try:
            return float(str(override).strip())
        except ValueError:
            pass
    try:
        load1 = float(os.getloadavg()[0])
        cores = max(1, int(os.cpu_count() or 1))
        return load1 / cores
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def _parse_vm_stat_free_gb(stats):
    if not isinstance(stats, str) or 'Pages free' not in stats:
        return None
    page_match = re.search(r'page size of (\d+) bytes', stats)
    page_size = int(page_match.group(1)) if page_match else 4096
    pages = 0
    matched = False
    for label in ('Pages free', 'Pages inactive', 'Pages speculative'):
        m = re.search(r'^' + label + r':\s+(\d+)', stats, re.M)
        if m:
            pages += int(m.group(1))
            matched = True
    if not matched:
        return None
    return (pages * page_size) / (1024.0 ** 3)


def _parse_meminfo_free_gb(text):
    if not isinstance(text, str):
        return None
    stats = dict(re.findall(r'^(\w+):\s+(\d+)', text, re.M))
    if 'MemAvailable' in stats:
        return int(stats['MemAvailable']) / (1024.0 * 1024.0)
    if 'MemFree' in stats:
        avail_kb = int(stats['MemFree']) + int(stats.get('Buffers', 0)) + int(stats.get('Cached', 0))
        return avail_kb / (1024.0 * 1024.0)
    return None


def coordinator_free_gb(vm_stat_runner=None, meminfo_path='/proc/meminfo'):
    """Free/available memory in GiB via vm_stat (macOS) or /proc/meminfo (Linux), with FLEET_WATCH_TEST_FREE_GB override."""
    override = os.environ.get('FLEET_WATCH_TEST_FREE_GB')
    if override is not None and str(override).strip() != '':
        try:
            return float(str(override).strip())
        except ValueError:
            pass
    if sys.platform == 'darwin':
        try:
            if vm_stat_runner is not None:
                stats = vm_stat_runner()
            elif getattr(subprocess.check_output, '__module__', '') != 'subprocess':
                stats = subprocess.check_output(['vm_stat'], text=True, timeout=5)
            else:
                with subprocess.Popen(
                    ['vm_stat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
                ) as proc:
                    stats, _ = proc.communicate(timeout=5)
            return _parse_vm_stat_free_gb(stats)
        except Exception:
            return None
    try:
        path = Path(meminfo_path)
        if path.exists():
            return _parse_meminfo_free_gb(path.read_text())
    except Exception:
        pass
    return None


def _is_local_coordinator_host(host, config):
    local_host = (config or {}).get('local_host')
    if host in ('local', None, ''):
        return True
    if isinstance(local_host, str) and local_host.strip() and host == local_host.strip():
        return True
    return False


def _environment_names(call):
    try:
        result = call('environment', 'list')
    except Exception:
        return {}
    envs = result.get('environments') if isinstance(result, dict) else None
    names = {}
    for env in envs or []:
        if not isinstance(env, dict):
            continue
        eid, name = env.get('id'), env.get('name')
        if isinstance(eid, str) and eid and isinstance(name, str) and name.strip():
            names[eid] = name.strip()
    return names


def environment_name_by_id(rpc_call=None):
    """Map an Orca environment id to its name. Empty when the list cannot be read.

    A pass reads the list once. A caller that passes rpc_call always reads again.
    """
    global _ENV_NAMES_CACHE
    cache_on = rpc_call is None and _PASS is not None and _ENV_PASS_ID == id(_PASS)
    if cache_on and _ENV_NAMES_CACHE is not None:
        return _ENV_NAMES_CACHE
    names = _environment_names(rpc if rpc_call is None else rpc_call)
    if cache_on:
        _ENV_NAMES_CACHE = names
    return names


def host_cap_name(raw, config, env_names):
    """host_caps key for a worker-list host id.

    Full rows use an environment id. host_caps is keyed by the environment name.
    """
    if not isinstance(raw, str) or not raw or raw == 'local':
        return 'local'
    config = config or {}
    caps = config.get('host_caps') or {}
    local_host = config.get('local_host')
    if raw in caps or raw == local_host:
        return raw
    mapped = (env_names or {}).get(raw)
    if not isinstance(mapped, str) or not mapped:
        return raw
    if mapped in caps or mapped == local_host:
        return mapped
    folded = {}
    for key in list(caps) + ([local_host] if isinstance(local_host, str) else []):
        if isinstance(key, str):
            folded.setdefault(key.lower(), key)
    return folded.get(mapped.lower(), mapped)


def _hosts_need_env_map(workers, config):
    config = config or {}
    known = set(config.get('host_caps') or {})
    known.update({'local', ''})
    local_host = config.get('local_host')
    if isinstance(local_host, str) and local_host.strip():
        known.add(local_host.strip())
    for worker in workers or []:
        if not isinstance(worker, dict):
            continue
        host_id = projection_host_id(worker)
        if host_id not in known:
            return True
    return False


def _resolve_env_names(workers, config, env_names):
    if env_names is not None:
        return env_names
    if not _hosts_need_env_map(workers, config):
        return {}
    return environment_name_by_id()


def _host_maps_repo(config, host, repo):
    """False when worker_placement.repos exists and this host has no entry for repo.

    No table means the caller still asks Orca. The local host is always mapped.
    A table keyed by the local Orca repo id matches that id as well as owner/name
    and path:<root>.
    """
    placement = _sibling('worker_placement', 'worker-placement.py')
    if not placement.repos_for_env(config or {}):
        return True
    local = (config or {}).get('local_host')
    local = local.strip() if isinstance(local, str) and local.strip() else None
    selectors = [repo]
    root = _issue_scan_repo_root(config, repo)
    if root:
        selectors.append('path:' + root)
    if any(placement.host_has_repo_mapping(config, host, local, sel) for sel in selectors):
        return True
    local_id = default_local_repo_id(repo)
    if not isinstance(local_id, str) or not local_id.strip():
        return False
    return placement.host_has_repo_mapping(config, host, local, 'id:' + local_id.strip())


def _overflow_host_ok(config, host, repo, lookup):
    """True when this host may take overflow for repo. No repo means no filter."""
    if not repo:
        return True
    placement = _sibling('worker_placement', 'worker-placement.py')
    if placement.repos_for_env(config or {}):
        return _host_maps_repo(config, host, repo)
    owner = repo
    if repo.startswith('path:'):
        owner = github_repo_from_origin(repo[5:]) or ''
    elif repo.startswith('id:'):
        owner = ''
    if not owner or '/' not in owner:
        return False
    if lookup is None:
        lookup = default_repo_id_lookup
    try:
        return bool(lookup(host, owner))
    except Exception:
        return False


def _first_admitted_overflow_host(host, config, workers, env_names=None, repo=None, repo_lookup=None):
    local_host = (config or {}).get('local_host')
    local_names = {'local', host}
    if isinstance(local_host, str) and local_host.strip():
        local_names.add(local_host.strip())
    for candidate in ((config or {}).get('host_caps') or {}):
        if candidate in local_names:
            continue
        if not _overflow_host_ok(config, candidate, repo, repo_lookup):
            continue
        remote_receipt = admit(candidate, config, workers=workers, env_names=env_names if env_names is not None else {})
        if remote_receipt.get('admitted'):
            return candidate
    return None


def admit(host, config, workers=None, env_names=None, repo=None, repo_lookup=None, released_ids=None):
    """Evaluate host admission under its configured cap.
    Returns an admission receipt dict. Missing/failed remote inventory and release_unknown never authorize a start.
    """
    config = config or {}
    host_caps = config.get('host_caps') or {}
    local_host = config.get('local_host')
    is_local = _is_local_coordinator_host(host, config)
    if host in host_caps:
        cap = host_caps[host]
    elif is_local and isinstance(local_host, str) and local_host in host_caps:
        cap = host_caps[local_host]
    else:
        cap = host_caps.get('local', 4) if is_local else host_caps.get(host, 4)

    load_per_core = coordinator_load_per_core() if is_local else None
    free_gb = coordinator_free_gb() if is_local else None
    load_breached = is_local and load_per_core is not None and load_per_core >= COORDINATOR_MAX_LOAD_PER_CORE
    mem_breached = is_local and free_gb is not None and free_gb < COORDINATOR_MIN_FREE_GB

    if workers is None:
        test_override = (
            os.environ.get('FLEET_WATCH_TEST_LOAD_PER_CORE') is not None
            or os.environ.get('FLEET_WATCH_TEST_FREE_GB') is not None
            or os.environ.get('USAGE_GATE_ORCA') == 'false'
        )
        rpc_mocked = getattr(rpc, '__module__', '') != __name__ or 'ORCA_CLI_COMMAND' in os.environ
        if is_local and test_override and not rpc_mocked:
            workers = []
        else:
            try:
                workers = fetch_workers(config)
            except Exception as e:
                if load_breached or mem_breached or (is_local and test_override):
                    workers = []
                else:
                    return {
                        'ok': False,
                        'admitted': False,
                        'host': host,
                        'cap': cap,
                        'occupied': None,
                        'live_count': 0,
                        'retained_count': 0,
                        'resources': [],
                        'overflow_host': None,
                        'reason': 'missing or failed remote inventory: %s' % str(e),
                        'receipt': {
                            'host': host,
                            'admitted': False,
                            'status': 'rejected',
                            'error': 'missing or failed remote inventory'
                        }
                    }

    deduped = deduplicate_workers(workers)
    for w in deduped:
        if released_ids and isinstance(w, dict) and w.get('dispatchId') in released_ids:
            _mark_worker_released(w)
    env_names = _resolve_env_names(deduped, config, env_names)
    proof = build_gone_proof(deduped, config, env_names)
    host_resources = []
    has_any_release_unknown = False
    live_count = 0
    retained_count = 0
    local_names = {'local', host}
    if is_local and isinstance(local_host, str) and local_host.strip():
        local_names.add(local_host.strip())

    for w in deduped:
        occupies, info, release_unk = classify_worker(w, proof, config, env_names)
        if release_unk:
            has_any_release_unknown = True
        w_host = host_cap_name(info.get('host'), config, env_names)
        info = dict(info)
        info['host'] = w_host
        matches_host = (w_host in local_names) if is_local else (w_host == host)
        if matches_host and occupies:
            host_resources.append(info)
            if info.get('category') == 'live':
                live_count += 1
            else:
                retained_count += 1

    occupied_count = len(host_resources)

    if load_breached or mem_breached:
        overflow_host = _first_admitted_overflow_host(
            host, config, deduped, env_names, repo, repo_lookup)
        breaches = []
        if load_breached:
            breaches.append('coordinator 1m load per core %.2f >= %.2f' % (load_per_core, COORDINATOR_MAX_LOAD_PER_CORE))
        if mem_breached:
            breaches.append('coordinator free memory %.2f GB < %.1f GB' % (free_gb, COORDINATOR_MIN_FREE_GB))
        breach_text = ' and '.join(breaches)
        if overflow_host:
            reason = '%s; overflow to %s: use script/start-remote-worker.sh --on %s' % (
                breach_text, overflow_host, overflow_host
            )
        elif repo:
            reason = '%s; no remote overflow host has this repo (use script/start-remote-worker.sh --on <host>)' % (
                breach_text,
            )
        else:
            reason = '%s; no remote overflow host has free capacity (use script/start-remote-worker.sh --on <host>)' % (
                breach_text,
            )
        return {
            'ok': True,
            'admitted': False,
            'host': host,
            'cap': cap,
            'occupied': occupied_count,
            'live_count': live_count,
            'retained_count': retained_count,
            'resources': host_resources,
            'overflow_host': overflow_host,
            'load_per_core': load_per_core,
            'free_gb': free_gb,
            'reason': reason,
            'receipt': {
                'host': host,
                'admitted': False,
                'status': 'rejected',
                'cap': cap,
                'occupied': occupied_count,
                'live_count': live_count,
                'retained_count': retained_count,
                'overflow_host': overflow_host,
                'error': reason,
            }
        }

    if has_any_release_unknown:
        return {
            'ok': False,
            'admitted': False,
            'host': host,
            'cap': cap,
            'occupied': occupied_count,
            'live_count': live_count,
            'retained_count': retained_count,
            'resources': host_resources,
            'overflow_host': None,
            'reason': 'release_unknown never authorizes another start',
            'receipt': {
                'host': host,
                'admitted': False,
                'status': 'rejected',
                'error': 'release_unknown never authorizes another start'
            }
        }

    gate_names = sorted(local_names) if is_local else [host]
    gate_lock = next(filter(None, (head_checks_gate_lock(name) for name in gate_names)), None)
    admitted = occupied_count < cap and not gate_lock
    if gate_lock:
        refusal = 'head checks hold the heavy gate on %s (%s)' % (host, gate_lock)
    else:
        refusal = 'host cap exceeded: %s %d/%d (live=%d retained=%d)' % (host, occupied_count, cap, live_count, retained_count)
    overflow_host = None if admitted else (
        _first_admitted_overflow_host(host, config, deduped, env_names, repo, repo_lookup) if is_local else None
    )
    return {
        'ok': True,
        'admitted': admitted,
        'host': host,
        'cap': cap,
        'occupied': occupied_count,
        'live_count': live_count,
        'retained_count': retained_count,
        'resources': host_resources,
        'overflow_host': overflow_host,
        'reason': 'admitted' if admitted else refusal,
        'receipt': {
            'host': host,
            'admitted': admitted,
            'status': 'admitted' if admitted else 'rejected',
            'cap': cap,
            'occupied': occupied_count,
            'live_count': live_count,
            'retained_count': retained_count,
            'overflow_host': overflow_host,
        }
    }


def worker_failure_is_quiet(worker):
    """A failed dispatch that is already released or settled is not a new alert.

    A worker someone stopped is not a failure to report: a remote server record has no release fields, only
    workerState stopped with dispatchStatus failed (a signed out antigravity start undoes itself that way, #1832)."""
    if worker_terminal_released(worker) or (worker.get('workerState') or worker.get('state')) == 'stopped':
        return True
    stage = (worker.get('projection') or {}).get('stage')
    detail = stage.get('detail') if isinstance(stage, dict) else ''
    if detail == 'settled' or worker.get('stage') == 'settled':
        return True
    if worker_liveness_verdict(worker) == 'settled':
        return True
    outcome = (worker.get('projection') or {}).get('outcome') or worker.get('outcome')
    return outcome == 'settled'


def alerts(config, state, now, messages, workers, waiter_alive, lead_alive=None):
    notices = []
    counts = {}
    held = {}
    # The first pass only records the failures that already exist.
    baseline = 'failed' not in state
    state.setdefault('failed', [])
    for worker in workers:
        status = worker.get('dispatchStatus')
        dispatch = worker['dispatchId']
        retried = any(w.get('taskId') == worker.get('taskId') and w.get('dispatchStatus') != 'failed' for w in workers) if worker.get('taskId') else False
        if status == 'failed' and not retried and dispatch not in state['failed']:
            if not baseline and not worker_failure_is_quiet(worker):
                notices.append(Urgent('failed dispatch ' + dispatch + '; inspect worker-show and provider capacity'))
            state['failed'].append(dispatch)
            stall_cfg = config.get('worker_stall') or {}
            fixed = stall_cfg.get('label_repo')
            if isinstance(fixed, str) and fixed.strip():
                fixed = fixed.strip()
            elif stall_cfg.get('from_system'):
                fixed = repo_for_worker(worker, config) or ''
            else:
                fixed = ''
            pr_num = worker_pr_number(worker)
            if fixed and pr_num:
                state.setdefault('failed_refs', {})[dispatch] = {'repo': fixed, 'pr': pr_num}

    deduped = deduplicate_workers(workers)
    proof = build_gone_proof(deduped, config, {})
    for worker in deduped:
        occupies, info, _ = classify_worker(worker, proof, config, {})
        if occupies:
            host = info['host']
            counts[host] = counts.get(host, 0) + 1
            kind = 'live' if info.get('category') == 'live' else 'retained'
            held.setdefault(host, {'live': 0, 'retained': 0})[kind] += 1

    for host, cap in config.get('host_caps', {}).items():
        if counts.get(host, 0) > cap:
            split = held.get(host, {})
            notices.append(Urgent('host cap exceeded: %s %d/%d live=%d retained=%d (includes child dispatches)' % (
                host, counts[host], cap, split.get('live', 0), split.get('retained', 0))))
    # A lead pane can vanish (terminal_not_found) while its merges silently stop.
    dead = state.setdefault('dead_leads', [])
    for lead in config.get('leads', []):
        handle = lead['terminal']
        if (lead_alive or {}).get(handle, True):
            if handle in dead:
                dead.remove(handle)
        elif handle not in dead:
            notices.append(Urgent('lead pane gone: %s (%s); restart it or move its PRs to a live lead' % (lead['name'], handle)))
            dead.append(handle)
    for run in config['runs']:
        key = run['id']
        pending = any(m.get('run_id') == key and not m.get('read') for m in messages)
        if waiter_alive[key] or not pending:
            state.pop(key, None)
            continue
        timer = state.setdefault(key, {'since': now, 'alerted': False})
        if now - timer['since'] >= 600 and not timer['alerted']:
            notices.append(Urgent('inbox waiter absent for 10 minutes with unacked deliveries: ' + key))
            timer['alerted'] = True
    return notices


_PR_LIST_FIELDS = (
    'number,state,isDraft,headRefOid,headRefName,baseRefOid,mergeable,mergeStateStatus,'
    'reviewDecision,files,labels,comments,statusCheckRollup,mergeCommit,body,updatedAt'
)


def _fetch_pr_list(repo, state, run=None):
    """Recent PRs in one gh call, or None when gh fails."""
    if run is None:
        run = subprocess.run
    command = [
        'gh', 'pr', 'list', '--repo', repo, '--state', state, '--limit', '50',
        '--json', _PR_LIST_FIELDS,
    ]
    try:
        output = run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def fetch_prs(repo):
    """Recent PRs in every state, for merge and Verdict notices."""
    return _fetch_pr_list(repo, 'all')


def fetch_open_prs(repo):
    """Open PRs, including ones older than the newest closed PRs."""
    return _fetch_pr_list(repo, 'open')


newest_comment_receipt = rs.newest_comment_receipt
_receipt_first_line = rs.receipt_first_line


def newest_checks_kind(comments, head):
    return rs.newest_receipt_kind(comments, 'Checks', head)


def newest_checks_comment(comments, head):
    """Newest Checks receipt comment at head, if any."""
    return newest_comment_receipt(comments, 'Checks', head)


def failing(pr):
    """The newest Checks receipt at this head decides, unless a status check failed after it; otherwise any failed status check."""
    head = pr.get('headRefOid') or ''
    return rs.status_rollup_failure_at_head(pr, head)


_RECEIPT_LINE_RE = re.compile(r'^(?:Verdict|Review): (?:PASS\+NOTES|PASS|FAIL) head=[0-9a-f]{40}\b')


def pr_events(repo, old, prs, now, stuck_seconds):
    """Compare PR data with the last pass. The first pass records and reports nothing."""
    baseline = old is None
    old = old or {}
    merged = list(old.get('merged', []))
    verdicts = list(old.get('verdicts', []))
    stuck = {}
    events = []
    for pr in prs:
        number = pr['number']
        for comment in pr['comments']:
            first = comment['body'].split('\n')[0]
            if (first.startswith('Verdict:') or first.startswith('Review:')) and comment['id'] not in verdicts:
                verdicts.append(comment['id'])
                if not baseline and pr['state'] == 'OPEN' and not _RECEIPT_LINE_RE.match(first):
                    # ship.sh reads only the one line form, so a Verdict in another shape is invisible to it (#1157).
                    events.append(Urgent('malformed %s on %s #%d: first line %r; repost with script/post-verdict.sh' % (
                        first.split(':')[0], repo, number, first[:80])))
                elif not baseline:
                    event = Verdict('%s #%d %s' % (repo, number, first))
                    found = re.search(r'\bauthor=([A-Za-z0-9_-]+)', first)
                    if found:
                        event.author = found.group(1)
                    events.append(event)
        if pr['state'] == 'MERGED' and number not in merged:
            merged.append(number)
            if not baseline:
                events.append('merged %s #%d %s' % (repo, number, (pr.get('mergeCommit') or {}).get('oid')))
        if pr['state'] != 'OPEN' or not failing(pr):
            continue
        timer = old.get('stuck', {}).get(str(number), {})
        if timer.get('head') != pr['headRefOid']:
            timer = {'head': pr['headRefOid'], 'since': now, 'alerted': False}
        timer = dict(timer)
        if now - timer['since'] >= stuck_seconds and not timer['alerted']:
            timer['alerted'] = True
            events.append('stuck %s #%d head %s failing for %d minutes' % (repo, number, pr['headRefOid'], (now - timer['since']) // 60))
        stuck[str(number)] = timer
    return events, {'merged': merged, 'verdicts': verdicts, 'stuck': stuck}


def pr_notices(config, state, now, fetch=None):
    """A repo whose fetch failed keeps its state, so its events arrive on a later pass."""
    if fetch is None:
        fetch = fetch_prs
    watch = config.get('pr_watch')
    if not watch:
        return []
    notices = []
    seen = state.setdefault('pr_watch', {})
    for repo in watch['repos']:
        prs = fetch(repo)
        if prs is None:
            continue
        events, seen[repo] = pr_events(repo, seen.get(repo), prs, now, watch.get('stuck_minutes', 30) * 60)
        notices.extend(events)
    return notices


RUN_WINDOW = 2 * 3600
BACKUP_LIMIT = 30 * 60
BACKUP_STALE_LOG = 10 * 60
HEAVY_GATE_MEDIAN_LIMIT = 2 * 60
HEAVY_GATE_WAIT_MEDIAN_DEFAULT_MAX_AGE_SECONDS = 24 * 3600
WRAP_UP_STALE_LIMIT = 20 * 60
WRAP_UP_STALE_LOG = 10 * 60
STALL_IDLE_LIMIT_DEFAULT = 30 * 60
VERIFIER_REWORK_IDLE_SECONDS = 60 * 60
_AVOID_FAMILIES = {'claude', 'gpt', 'gemini', 'composer', 'grok'}
STALL_RESTART_RECORD_TTL_DEFAULT = 24 * 3600
PASS_FAIL_LIMIT = 4 * 60


def stall_idle_limit_seconds(config):
    """Seconds of terminal silence before stall; config or FLEET_WATCH_STALL_IDLE_SECONDS override default."""
    cfg = (config or {}).get('worker_stall') or {}
    if 'stall_idle_seconds' in cfg:
        try:
            return max(0, int(cfg['stall_idle_seconds']))
        except (TypeError, ValueError):
            pass
    env_raw = os.environ.get('FLEET_WATCH_STALL_IDLE_SECONDS')
    if env_raw is not None and str(env_raw).strip() != '':
        try:
            return max(0, int(env_raw.strip(), 10))
        except ValueError:
            pass
    return STALL_IDLE_LIMIT_DEFAULT


def _remote_server_row(w):
    """True for a remote --include-remote row that carries server metadata and no local terminal/resource."""
    w = w or {}
    server = w.get('server')
    named = isinstance(server, dict) or (isinstance(server, str) and bool(server.strip()))
    # worker-show returns a flat record: server is a string and stage is server_record (#1394).
    return ((named or w.get('stage') == 'server_record')
            and not w.get('projection')
            and not w.get('agentTerminalHandle')
            and not w.get('terminalState')
            and not w.get('resource'))


def projection_host_id(w):
    """Host id from worker-list row: full rows use projection.host object; list view may use host string."""
    w = w or {}
    proj = w.get('projection') or {}
    h = proj.get('host')
    if isinstance(h, dict):
        hid = h.get('id')
        if isinstance(hid, str) and hid:
            return hid
    elif isinstance(h, str) and h:
        return h
    top = w.get('host')
    if isinstance(top, str) and top:
        return top
    if _remote_server_row(w):
        srv = w.get('server') or {}
        if isinstance(srv, str):
            if srv.strip():
                return srv.strip()
            srv = {}
        for key in ('name', 'environmentId', 'id'):
            val = srv.get(key)
            if isinstance(val, str) and val.strip():
                return val.strip()
    return 'local'

AGENT_STATE_BACKUP_STALE_TITLE = 'agent-state backup has not pushed for 30 minutes'
HEAVY_GATE_MEDIAN_TITLE = 'heavy-gate median wait exceeds 2 minutes on %s'
HEAVY_GATE_STUCK_LIMIT = 10 * 60
HEAVY_GATE_STUCK_TITLE = 'heavy-gate slot %s stuck on %s'

_heavy_gate_module = None


def heavy_gate_module():
    """Load script/heavy-gate.py for slot inspection."""
    global _heavy_gate_module
    if _heavy_gate_module is None:
        path = Path(__file__).resolve().parent / 'heavy-gate.py'
        spec = importlib.util.spec_from_file_location('heavy_gate', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _heavy_gate_module = mod
    return _heavy_gate_module
WRAP_UP_STALE_TITLE = 'wrap-up last round stale on %s'


def open_fixed_title_issue_exists(repo, title, run=subprocess.run):
    """True if an open issue has the exact title, False if search succeeded with no match, None if search failed."""
    q = '"%s" in:title' % title.replace('\\', '\\\\').replace('"', '\\"')
    try:
        proc = run(
            [
                'gh',
                'issue',
                'list',
                '--repo',
                repo,
                '--state',
                'open',
                '--search',
                q,
                '--json',
                'title',
                '--limit',
                '20',
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if proc.returncode != 0:
            return None
        rows = json.loads(proc.stdout)
        if not isinstance(rows, list):
            return None
        return any(isinstance(row, dict) and row.get('title') == title for row in rows)
    except (subprocess.SubprocessError, OSError, ValueError, TypeError, json.JSONDecodeError):
        return None


def open_backup_issue_exists(repo, title=AGENT_STATE_BACKUP_STALE_TITLE, run=subprocess.run):
    return open_fixed_title_issue_exists(repo, title, run=run)


def heavy_gate_wait_median_max_age_seconds():
    value = (os.environ.get('HEAVY_GATE_WAIT_MEDIAN_MAX_AGE_SECONDS') or '').strip()
    if value:
        try:
            seconds = float(value)
            if math.isfinite(seconds) and seconds > 0:
                return seconds
        except ValueError:
            pass
    return HEAVY_GATE_WAIT_MEDIAN_DEFAULT_MAX_AGE_SECONDS


def wait_log_line_age_seconds(token, now):
    """Seconds since a wait-log timestamp token, or None when unparsable."""
    for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            stamp = datetime.datetime.strptime(token, fmt)
        except ValueError:
            continue
        if stamp.tzinfo is not None:
            return now - stamp.timestamp()
        return now - calendar.timegm(stamp.timetuple())
    return None


def read_heavy_gate_waits(log_path, now=None):
    """Seconds from recent heavy-gate wait log lines, in file order."""
    if now is None:
        now = time.time()
    max_age = heavy_gate_wait_median_max_age_seconds()
    try:
        text = Path(log_path).read_bytes().decode('utf-8', errors='replace')
    except OSError:
        return []
    waits = []
    for line in text.splitlines():
        if not line.strip():
            continue
        token = line.split(None, 1)[0]
        age = wait_log_line_age_seconds(token, now)
        if age is not None and age > max_age:
            continue
        match = re.search(r'\bwait_s=([0-9]+(?:\.[0-9]+)?)', line)
        if not match:
            continue
        try:
            value = float(match.group(1))
        except ValueError:
            continue
        if math.isfinite(value) and value >= 0:
            waits.append(value)
    return waits


def wrap_up_last_line_age_seconds(log_path, now):
    """Age of the last wrap-up-scheduled log line, or None when missing or unparsable."""
    try:
        text = Path(log_path).read_bytes().decode('utf-8', errors='replace')
    except OSError:
        return None
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None
    token = lines[-1].split(None, 1)[0]
    for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            stamp = datetime.datetime.strptime(token, fmt)
        except ValueError:
            continue
        if stamp.tzinfo is not None:
            return now - stamp.timestamp()
        return now - calendar.timegm(stamp.timetuple())
    return None


def heavy_gate_stuck_notices(block, state, now, repo, act, issue_exists):
    """Open one issue per held slot after it stays stuck beyond the limit."""
    slot_roots = block.get('slot_roots') or {}
    if not slot_roots or not repo:
        return [], []
    limit = block.get('stuck_limit_seconds', HEAVY_GATE_STUCK_LIMIT)
    mod = heavy_gate_module()
    since = state.setdefault('heavy_gate_stuck_since', {})
    tracked = state.setdefault('heavy_gate_stuck_issues', {})
    notices = []
    log_bits = []
    seen = set()
    for host, root in slot_roots.items():
        try:
            stuck = mod.stuck_slot_names(root)
        except OSError:
            continue
        for slot in stuck:
            key = '%s:%s' % (host, slot)
            seen.add(key)
            log_bits.append('heavy_gate_stuck_%s_%s' % (host, slot))
            first = since.get(key)
            if first is None:
                since[key] = now
                continue
            if now - first < limit:
                continue
            title = HEAVY_GATE_STUCK_TITLE % (slot, host)
            if tracked.get(key):
                continue
            exists = issue_exists(repo, title)
            if exists is None:
                continue
            if exists:
                tracked[key] = True
                continue
            if act(['gh', 'issue', 'create', '--repo', repo, '--title', title,
                    '--body', 'slot %s on host %s held with dead owner; inspect %s/%s'
                    % (slot, host, root, slot)]):
                notices.append('%s, issue not opened' % title)
                continue
            tracked[key] = True
            notices.append(title)
    for key in list(since):
        if key not in seen:
            since.pop(key, None)
            tracked.pop(key, None)
    return notices, log_bits


def heavy_gate_notices(config, state, now, act=None, issue_exists=None):
    """Median wait-log check and held-slot inspection."""
    block = config.get('heavy_gate') or {}
    hosts = block.get('hosts') or {}
    repo = block.get('issue_repo')
    if not repo:
        return [], []
    if act is None:
        act = run_gh
    if issue_exists is None:
        issue_exists = open_fixed_title_issue_exists
    notices = []
    log_bits = []
    if hosts:
        limit = block.get('median_limit_seconds', HEAVY_GATE_MEDIAN_LIMIT)
        tracked = state.setdefault('heavy_gate_issues', {})
        for host, path in hosts.items():
            waits = read_heavy_gate_waits(path, now)
            median = statistics.median(waits) if waits else None
            if median is not None:
                log_bits.append('heavy_gate_median_%s=%.0f' % (host, median))
            if median is None or median <= limit:
                tracked.pop(host, None)
                continue
            log_bits.append('heavy_gate_slow_%s' % host)
            title = HEAVY_GATE_MEDIAN_TITLE % host
            if tracked.get(host):
                continue
            exists = issue_exists(repo, title)
            if exists is None:
                continue
            if exists:
                tracked[host] = True
                continue
            if act(['gh', 'issue', 'create', '--repo', repo, '--title', title,
                    '--body', 'median wait %.0fs on host %s; see %s' % (median, host, path)]):
                notices.append('%s, issue not opened' % title)
                continue
            tracked[host] = True
            notices.append(title)
    stuck_notices, stuck_log = heavy_gate_stuck_notices(block, state, now, repo, act, issue_exists)
    notices.extend(stuck_notices)
    log_bits.extend(stuck_log)
    return notices, log_bits


BOARD_STALE_CHECK_SECONDS = 3600
BOARD_STALE_NOTICES_PER_PASS = 5
_BOARD_WOULD_SET_RE = re.compile(r'^\[dry-run\] would set (?P<path>.+) completed \((?P<why>[^)]*)\) environment=(?P<env>\S+)$')


def board_dry_run_output():
    """Text of `board-done.py --fleet` in its default dry run, or None when it fails."""
    script = Path(__file__).with_name('board-done.py')
    try:
        proc = subprocess.run([sys.executable, str(script), '--fleet'], capture_output=True, text=True, timeout=110, check=False)
    except (subprocess.SubprocessError, OSError):
        return None
    return proc.stdout if proc.returncode == 0 else None


def stale_board_notices(config, state, now, run=None):
    """Report a worktree whose card board-done would move to Done but that still sits there an hour later (#1160).

    Opt in with board_stale_check in the private config. The check runs at most once an hour (board_stale_check_seconds). A card is first seen, then reported once
    when a later check still finds it. At most five are reported per pass.
    """
    if not config.get('board_stale_check'):
        return []
    block = state.setdefault('board_stale', {'checked_at': None, 'seen': {}, 'reported': []})
    interval = config.get('board_stale_check_seconds', BOARD_STALE_CHECK_SECONDS)
    if block['checked_at'] is not None and now - block['checked_at'] < interval:
        return []
    text = (run or board_dry_run_output)()
    if text is None:
        return []
    block['checked_at'] = now
    current = {}
    for line in text.splitlines():
        found = _BOARD_WOULD_SET_RE.match(line.strip())
        if found:
            current['%s\t%s' % (found.group('env'), found.group('path'))] = found.group('why')
    seen = {key: block['seen'].get(key, now) for key in current}
    block['seen'] = seen
    block['reported'] = [key for key in block['reported'] if key in current]
    notices = []
    for key, first in sorted(seen.items(), key=lambda item: item[1]):
        if key in block['reported'] or now - first < interval:
            continue
        if len(notices) == BOARD_STALE_NOTICES_PER_PASS:
            break
        block['reported'].append(key)
        env, path = key.split('\t', 1)
        notices.append('settled worktree still open on the board: %s on %s (%s); wrap-up board-done has not moved it to Done' % (
            path, env, current[key]))
    return notices


FLEET_PULL_LOG_DEFAULT = os.path.expanduser('~/.claude/state/fleet-pull-after-ship.log')


def fleet_pull_after_ship_notices(config, state, now, path=None):
    """Report a fleet-pull that ship.sh ran after a dotfiles merge and that did not update every host (#1173).

    ship.sh appends one block per run: a header 'fleet-pull <utc> pr=<n> sha=<sha> exit=<rc>' then the ok/fail line
    per host (duration_s is optional). Each block is read once (by byte offset); a block with a failed host or a nonzero exit is one notice.
    """
    log = Path(path or os.environ.get('SHIP_FLEET_PULL_LOG') or FLEET_PULL_LOG_DEFAULT)
    try:
        data = log.read_bytes()
    except OSError:
        return []
    block = state.setdefault('fleet_pull_log', {'offset': 0})
    offset = block.get('offset', 0)
    if offset > len(data):
        offset = 0
    block['offset'] = len(data)
    runs = []
    for text in data[offset:].decode('utf-8', 'replace').splitlines():
        header = re.match(r'^fleet-pull \S+ pr=(\S+) sha=(\S+) exit=(\d+)(?: duration_s=(\d+))?$', text)
        if header:
            runs.append({'pr': header.group(1), 'exit': int(header.group(3)), 'duration_s': header.group(4), 'failed': []})
        elif runs and text.startswith('fail '):
            runs[-1]['failed'].append(text[5:].strip())
    notices = []
    for run in runs:
        if run['exit'] == 0 and not run['failed']:
            continue
        why = 'timed out' if run['exit'] == 124 else 'exit %d' % run['exit']
        hosts = '; '.join(run['failed']) if run['failed'] else 'no host line'
        if run['duration_s'] is not None:
            why += ' duration_s=' + run['duration_s']
        notices.append('fleet-pull after the merge of PR %s did not finish clean (%s): %s' % (run['pr'], why, hosts))
    return notices


TEMPLATE_SYNC_STATE_DEFAULT = os.path.expanduser('~/.claude/state/template-sync.json')
TEMPLATE_PIN_LAG = 24 * 3600
TEMPLATE_PATHS = ('templates/agent-team', 'script/agent-team.sh')


def _git_out(cwd, *args):
    try:
        out = subprocess.run(['git', '-C', str(cwd)] + list(args), capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return (getattr(out, 'stdout', None) or '').strip() if getattr(out, 'returncode', 1) == 0 else None


def template_pin_notices(config, state, now, dotfiles=None, sync_state=None, origin_of=None):
    """Report a project whose .claude/agent-team-pin lags a dotfiles template change by more than 24 h, and a
    pin bump PR template-sync-pr.sh left red or failed (#1247). Each one is reported once per template commit.

    The pin is read from each repo_roots checkout's origin/main; a project without a pin is not on the pinned
    template yet and is skipped. The last template change is the newest dotfiles origin/main commit that touched
    templates/agent-team or script/agent-team.sh.
    """
    dotfiles = dotfiles or os.environ.get('DOTFILES') or str(Path(__file__).resolve().parent.parent)
    origin_of = origin_of or github_repo_from_origin
    seen = state.setdefault('template_pin', {})
    notices = []
    last = _git_out(dotfiles, 'log', '-1', '--format=%H %ct', 'origin/main', '--', *TEMPLATE_PATHS)
    # Without a readable dotfiles history, keep the lag keys so a later pass does not report them again.
    keep = {} if last else {k: v for k, v in seen.items() if k.startswith('lag ')}
    if last:
        change, when = last.split()
        if now - int(when) > TEMPLATE_PIN_LAG:
            for path in iter_repo_root_paths(config.get('repo_roots')):
                pin = _git_out(path, 'show', 'origin/main:.claude/agent-team-pin')
                if not pin:
                    continue
                pin = pin.splitlines()[0].strip()
                if _git_out(dotfiles, 'merge-base', '--is-ancestor', change, pin) is not None:
                    continue
                repo = origin_of(path) or path
                key = 'lag %s %s' % (repo, change)
                keep[key] = seen.get(key, now)
                if key not in seen:
                    notices.append('%s: .claude/agent-team-pin %s lags the dotfiles template change %s by more than 24 h; '
                                   'run script/template-sync-pr.sh or land its bump PR' % (repo, pin[:12], change[:12]))
    try:
        synced = json.loads(Path(sync_state or os.environ.get('TEMPLATE_SYNC_STATE') or TEMPLATE_SYNC_STATE_DEFAULT).read_text())
    except (OSError, ValueError):
        synced = {}
    for repo, entry in sorted(synced.items()) if isinstance(synced, dict) else []:
        if not isinstance(entry, dict) or entry.get('state') not in ('red', 'failed'):
            continue
        key = '%s %s %s' % (entry['state'], repo, entry.get('sha'))
        keep[key] = seen.get(key, now)
        if key not in seen:
            pr = ' PR #%s' % entry['pr'] if entry.get('pr') else ''
            notices.append('%s: template bump%s for dotfiles %s is %s; fix it, then rerun script/template-sync-pr.sh' % (
                repo, pr, str(entry.get('sha'))[:12], entry['state']))
    state['template_pin'] = keep
    return notices


TEMPLATE_SYNC_RETRY = 6 * 3600
TEMPLATE_SYNC_CLEAN_RECHECK = 1800
TEMPLATE_SYNC_LOG_DEFAULT = os.path.expanduser('~/.claude/state/template-sync-reconcile.log')


def _default_template_check(path, dotfiles):
    """True when agent-team.sh check finds drift in the project's origin/main (read-only, project rules only).

    A bump PR merged on GitHub does not move the checkout on disk, so the check runs on a throwaway worktree of origin/main.
    """
    script = os.path.join(dotfiles, 'script', 'agent-team.sh')
    tmp = tempfile.mkdtemp(prefix='template-check-')
    wt = os.path.join(tmp, 'wt')
    try:
        if _git_out(path, 'worktree', 'add', '-q', '--detach', wt, 'origin/main') is None:
            return False
        proc = subprocess.run(['bash', script, 'check', '--project-only', wt], capture_output=True, text=True,
                              timeout=120, env=dict(os.environ, DOTFILES=dotfiles))
        return proc.returncode != 0
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        _git_out(path, 'worktree', 'remove', '--force', wt)
        shutil.rmtree(tmp, ignore_errors=True)


def _default_template_launch(path, verdict_from, dotfiles):
    """Start template-sync-pr.sh for one project, detached; its output goes to the reconcile log."""
    script = os.path.join(dotfiles, 'script', 'template-sync-pr.sh')
    log = os.environ.get('TEMPLATE_SYNC_RECONCILE_LOG') or TEMPLATE_SYNC_LOG_DEFAULT
    os.makedirs(os.path.dirname(os.path.abspath(log)), exist_ok=True)
    with open(log, 'ab') as fh:
        subprocess.Popen(['bash', script, '--verdict-from', verdict_from, '--project', path],
                         stdout=fh, stderr=fh, stdin=subprocess.DEVNULL, start_new_session=True)


def template_sync_reconcile(config, state, now, dotfiles=None, check=None, launch=None, origin_of=None):
    """Open the bump PR for a project that drifted from the dotfiles template (#1329).

    ship.sh starts template-sync-pr.sh once after a template merge. A failed or skipped run, or a merge outside
    ship.sh, leaves the project drifted for good. Each pass checks every pinned repo_roots checkout with
    agent-team.sh check and, on drift, starts template-sync-pr.sh for that project alone. It reuses the open PR,
    and a project is tried again only after a new template commit on dotfiles origin/main or TEMPLATE_SYNC_RETRY seconds.
    Returns notices for a launch that failed.
    """
    dotfiles = dotfiles or os.environ.get('DOTFILES') or str(Path(__file__).resolve().parent.parent)
    origin_of = origin_of or github_repo_from_origin
    check = check or (lambda path: _default_template_check(path, dotfiles))
    launch = launch or (lambda path, verdict_from: _default_template_launch(path, verdict_from, dotfiles))
    tried = state.setdefault('template_sync_run', {})
    clean = state.setdefault('template_sync_clean', {})
    last = _git_out(dotfiles, 'log', '-1', '--format=%H %s', 'origin/main', '--', *TEMPLATE_PATHS)
    head, _, subject = (last or '').partition(' ')
    found = re.search(r'\(#(\d+)\)\s*$', subject)
    home = origin_of(dotfiles)
    if not (found and head and home):
        return []
    verdict_from = '%s#%s' % (home, found.group(1))
    notices = []
    for path in iter_repo_root_paths(config.get('repo_roots')):
        repo = origin_of(path) or path
        if repo == home or not _git_out(path, 'show', 'origin/main:.claude/agent-team-pin'):
            continue
        entry = tried.get(repo) or {}
        if entry.get('sha') == head and now - entry.get('at', 0) < TEMPLATE_SYNC_RETRY:
            continue
        # A clean check is trusted for TEMPLATE_SYNC_CLEAN_RECHECK seconds at the same template commit (#1820).
        seen_clean = clean.get(repo) or {}
        if seen_clean.get('sha') == head and now - seen_clean.get('at', 0) < TEMPLATE_SYNC_CLEAN_RECHECK:
            continue
        if not check(path):
            tried.pop(repo, None)
            clean[repo] = {'sha': head, 'at': now}
            continue
        clean.pop(repo, None)
        try:
            launch(path, verdict_from)
        except (OSError, subprocess.SubprocessError) as error:
            notices.append('%s: could not start template-sync-pr.sh for the drifted team template: %s' % (repo, error))
            continue
        tried[repo] = {'sha': head, 'at': now}
    return notices


CHANGELOG_FRAGMENT_WARN = 50


def changelog_fragment_notices(config, state, origin_of=None):
    """One notice per repo whose changelog.d holds more than the limit of uncompiled fragments (#1161).

    It repeats only when the count doubles since the last notice; a count back under the limit resets it.
    """
    limit = config.get('changelog_fragment_warn', CHANGELOG_FRAGMENT_WARN)
    tracked = state.setdefault('changelog_fragments', {})
    origin_of = origin_of or github_repo_from_origin
    notices = []
    for path in iter_repo_root_paths(config.get('repo_roots')):
        repo = origin_of(path) or path
        try:
            count = sum(1 for f in Path(path, 'changelog.d').glob('*.md') if f.name.lower() != 'readme.md')
        except OSError:
            continue
        if count <= limit:
            tracked.pop(repo, None)
            continue
        last = tracked.get(repo)
        if last and count < 2 * last:
            continue
        tracked[repo] = count
        notices.append('%s: changelog.d holds %d uncompiled fragments (limit %d); compile them before the next deploy' % (
            repo, count, limit))
    return notices


STALE_WORKTREE_EVERY = 1800


def stale_worktree_notices(config, state=None, now=None, run=None):
    """One notice per stale worktree in each repo_roots checkout on this host (#1188), from check-stale-worktrees.sh.

    The check takes 6 to 9 s per checkout, so with `state` it runs once per STALE_WORKTREE_EVERY seconds (#1820)."""
    if state is not None:
        now = time.time() if now is None else now
        last = state.get('stale_worktree_at')
        if last is not None and now - float(last) < STALE_WORKTREE_EVERY:
            return []
        state['stale_worktree_at'] = now
    run = run or subprocess.run
    script = str(Path(__file__).with_name('check-stale-worktrees.sh'))
    notices = []
    for path in iter_repo_root_paths(config.get('repo_roots')):
        if not os.path.isdir(path):
            continue
        try:
            result = run(['bash', script, path], capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.SubprocessError):
            continue
        if result.returncode != 1:
            continue
        for line in result.stdout.splitlines():
            if line.strip():
                notices.append('%s: stale worktree %s; remove it with worker-release or git worktree remove' % (
                    os.path.basename(path.rstrip('/')) or path, line.strip()))
    return notices


REAP_ORPHAN_SCRIPT = Path(__file__).with_name('reap-orphan-tests.sh')
REAP_ORPHAN_REMOTE = 'bash "$HOME/dotfiles/script/reap-orphan-tests.sh" || echo "reap-orphan-tests failed"'


PROBE_POLL_SECONDS = 2
PROBE_DEADLINE_SECONDS = 60


def _probe_output_when_done(rpc_call, host, handle):
    """Poll the probe terminal until it stops running, then read its output (#2078).

    One `terminal wait` cannot cover a slow probe: rpc() caps every Orca call at 15 s, so a wait that outlasts that
    raised OrcaReadError and the host was reported unread. A read is quick, so poll it instead."""
    deadline = time.monotonic() + PROBE_DEADLINE_SECONDS
    while True:
        read = rpc_call('terminal', 'read', '--environment', host, '--terminal', handle, '--limit', '200')
        status = ((read or {}).get('terminal') or {}).get('status')
        if status != 'running' or time.monotonic() >= deadline:
            return read
        time.sleep(PROBE_POLL_SECONDS)


def reap_orphan_remote_lines(rpc_call, host, command=REAP_ORPHAN_REMOTE):
    """Run reap-orphan-tests.sh (or another probe command) on a remote host the way start-remote-worker.sh runs a probe: a terminal there."""
    worktrees = (rpc_call('worktree', 'list', '--environment', host) or {}).get('worktrees') or []
    rows = [r for r in worktrees if isinstance(r, dict) and r.get('path') and not r.get('isArchived')]
    rows.sort(key=lambda r: not r.get('isMainWorktree'))
    if not rows:
        return []
    created = rpc_call('terminal', 'create', '--environment', host, '--worktree', 'path:%s' % rows[0]['path'],
                       '--command', command)
    handle = ((created or {}).get('terminal') or {}).get('handle')
    if not handle:
        return []
    try:
        read = _probe_output_when_done(rpc_call, host, handle)
    finally:
        close_worker_terminal(rpc_call, handle, host)
    return [str(line) for line in ((read or {}).get('terminal') or {}).get('tail') or []]


def orphan_reaper_notices(config, rpc_call=None, run=None):
    """Run reap-orphan-tests.sh on this host and on every other host_caps host; one notice per kill line (#1954).

    Runs only when the private config has an "orphan_reaper" block that is not {"enabled": false}, so a test config or a
    host that opted out kills nothing. A host that cannot be reached is skipped: the next pass runs it again."""
    block = config.get('orphan_reaper')
    if not isinstance(block, dict) or block.get('enabled') is False:
        return []
    rpc_call = rpc_call or rpc
    run = run or subprocess.run
    local_host = (config.get('local_host') or '').strip() or 'local'
    hosts = [(local_host, None)] + [(h, h) for h in (config.get('host_caps') or {}) if h != local_host]
    notices = []
    for name, remote in hosts:
        try:
            if remote is None:
                result = run(['bash', str(REAP_ORPHAN_SCRIPT)], capture_output=True, text=True, timeout=60)
                lines = (result.stdout or '').splitlines()
            else:
                lines = reap_orphan_remote_lines(rpc_call, remote)
        except (OSError, subprocess.SubprocessError, OrcaReadError, TerminalNotFound):
            continue
        for line in lines:
            line = line.strip()
            if line.startswith('reaped '):
                notices.append('%s: orphan test runner %s' % (name, line))
            elif line == 'reap-orphan-tests failed':
                notices.append('%s: reap-orphan-tests failed to run' % name)
    return notices


SIM_STALL_SCRIPT = Path(__file__).with_name('sim-stall-list.sh')
SIM_STALL_REMOTE = 'bash "$HOME/dotfiles/script/sim-stall-list.sh"'
SIM_STALL_SECONDS = 15 * 60
SIM_RECORD_RE = re.compile(r'SIM\|(\d+)\|(\d+(?:\.\d+)?)\|(\d+)\|([^|]*)\|(.*?)\|EOR')


def sim_stall_processes(rpc_call, host, run=subprocess.run):
    """xcodebuild and build-and-test.sh processes on one host ('' is this one), or None when it cannot be read."""
    try:
        if host:
            lines = reap_orphan_remote_lines(rpc_call, host, SIM_STALL_REMOTE)
        else:
            done = run(['bash', str(SIM_STALL_SCRIPT)], capture_output=True, text=True, timeout=60)
            if done.returncode != 0:
                return None
            lines = (done.stdout or '').splitlines()
    except (OSError, subprocess.SubprocessError, OrcaReadError, TerminalNotFound) + SEND_ERRORS:
        return None
    # A terminal read returns screen rows, so a long record may be wrapped: join the rows, then cut on the markers.
    text = ''.join(str(line) for line in lines)
    if 'SIM-END' not in text:
        return None
    return [{'pid': int(pid), 'cpu': float(cpu), 'age': int(age), 'cwd': cwd, 'command': command}
            for pid, cpu, age, cwd, command in SIM_RECORD_RE.findall(text)]


def _sim_owner(proc, rows):
    """The live worker row whose checkout holds the process's directory or is named in its command."""
    for row in rows:
        path = (worker_checkout_path(row) or str(row.get('_host_workspace') or '').split('::')[-1]).rstrip('/')
        if not path.startswith('/'):
            continue
        if proc['cwd'] == path or proc['cwd'].startswith(path + '/') or (path + '/') in proc['command']:
            return row
    return None


def sim_stall_pass(config, state, now, workers, rpc_call, processes=sim_stall_processes, env_names=None):
    """Report an xcodebuild or build-and-test.sh of a live worker that sat at 0% CPU for 15 minutes (#1970).

    The worker gets one terminal line per process and the coordinator one line per pass. Nothing is stopped or killed.
    This host is always read; a remote host only when the config lists it under sim_stall.hosts."""
    block = config.get('sim_stall') if isinstance(config.get('sim_stall'), dict) else {}
    if block.get('enabled') is False:
        return []
    remote_hosts = {str(h).lower() for h in block.get('hosts') or []}
    by_host = {}
    for row in workers or []:
        if not isinstance(row, dict) or not worker_row_is_live(row):
            continue
        env = row.get('_host') or ''
        if not env and worker_is_remote(row, config):
            env = remote_environment(row)
        if env:
            if env_names is None:
                env_names = environment_name_by_id()
            if host_cap_name(env, config, env_names).lower() not in remote_hosts:
                continue
        by_host.setdefault(env, []).append(row)
    book = state.setdefault('sim_stall', {})
    notices = []
    seen, unread = set(), set()
    for env, rows in by_host.items():
        procs = processes(rpc_call, env)
        if procs is None:
            unread.add(env)
            continue
        for proc in procs:
            owner = _sim_owner(proc, rows)
            if owner is None or proc['cpu'] > 0:
                continue
            key = '%s:%s' % (env, proc['pid'])
            entry = book.get(key)
            # A reused pid is a younger process than the one first seen.
            if not entry or proc['age'] < entry.get('age', 0):
                entry = book[key] = {'since': now}
            entry['age'] = proc['age']
            seen.add(key)
            if proc['age'] < SIM_STALL_SECONDS or now - entry['since'] < SIM_STALL_SECONDS:
                continue
            text = ('PID %d (%s) has been at 0%% CPU for %d minutes, likely stuck on the shared booted simulator. '
                    'Nothing was killed.' % (proc['pid'], proc['command'][:80], int((now - entry['since']) // 60)))
            handle = owner.get('_host_terminal') or worker_terminal_handle(owner)
            if handle and not entry.get('told'):
                try:
                    rpc_call('terminal', 'send', '--terminal', handle, '--text', text, '--enter', *_env_args(env))
                    entry['told'] = True
                except SEND_ERRORS as error:
                    log_send_failed(handle, error)
            notices.append(Urgent('iOS simulator stall, worker %s%s: %s' % (
                owner.get('dispatchId'), ' on %s' % host_cap_name(env, config, env_names) if env else '', text)))
    for key in [k for k in book if k not in seen and k.rsplit(':', 1)[0] not in unread]:
        book.pop(key)
    return notices


MAILBOX_ALERT_TIMEOUT = 60  # a hung mailbox must not push the pass past PASS_HARD_END and the 280 s precheck


def mailbox_alert_pass(config):
    """Run each repo_roots checkout's bin/support-mailbox-alert.py with the escalation send command (#1976).

    The script appends --subject/--body, sends and dedups by mail UID itself, so it is run once and never
    resent here. A checkout without it is skipped. Returns one `mailbox_alert=` log part per script run."""
    runs = config_runs(config)
    run_id = (runs[0].get('id') or '') if runs else ''
    sender = terminal_handle_for_configured_run(config, run_id)
    if not sender:
        return []
    send = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca')) + [
        'orchestration', 'send', '--to', 'run:%s' % run_id, '--run', run_id, '--from', sender, '--type', 'escalation']
    parts = []
    for path in iter_repo_root_paths(config.get('repo_roots')):
        script = Path(path, 'bin', 'support-mailbox-alert.py')
        if not script.is_file():
            continue
        try:
            result = subprocess.run([sys.executable, str(script), '--'] + send, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, errors='replace', timeout=MAILBOX_ALERT_TIMEOUT)
        except (OSError, subprocess.SubprocessError):
            parts.append('mailbox_alert=unknown')
            continue
        for line in result.stdout.splitlines():
            print('fleet-watch: ' + line)
        parts.append('mailbox_alert=0' if result.returncode == 0 else 'mailbox_alert=unknown')
    return parts


def wrap_up_notices(config, state, now, stamp_age=None, act=None, issue_exists=None):
    """Open one issue per host when the last wrap-up round line is older than the stale limit."""
    block = config.get('wrap_up') or {}
    hosts = block.get('hosts') or {}
    repo = block.get('issue_repo')
    if not hosts or not repo:
        return [], []
    if stamp_age is None:
        stamp_age = wrap_up_last_line_age_seconds
    if act is None:
        act = run_gh
    if issue_exists is None:
        issue_exists = open_fixed_title_issue_exists
    limit = block.get('stale_limit_seconds', WRAP_UP_STALE_LIMIT)
    tracked = state.setdefault('wrap_up_issues', {})
    notices = []
    log_bits = []
    for host, path in hosts.items():
        age = stamp_age(path, now)
        if age is not None:
            log_bits.append('wrap_up_age_%s=%d' % (host, int(age)))
            if age > WRAP_UP_STALE_LOG:
                log_bits.append('wrap_up_stale_%s' % host)
        if age is None or age <= limit:
            tracked.pop(host, None)
            continue
        title = WRAP_UP_STALE_TITLE % host
        if tracked.get(host):
            continue
        exists = issue_exists(repo, title)
        if exists is None:
            continue
        if exists:
            tracked[host] = True
            continue
        if act(['gh', 'issue', 'create', '--repo', repo, '--title', title,
                '--body', 'last wrap-up log line on host %s is %ds old; see %s' % (host, int(age), path)]):
            notices.append('%s, issue not opened' % title)
            continue
        tracked[host] = True
        notices.append(title)
    return notices, log_bits


def fetch_failed_runs(repo):
    """Recent failed runs in one gh call, or None when gh fails."""
    command = ['gh', 'run', 'list', '--repo', repo, '--status', 'failure', '--limit', '30',
               '--json', 'databaseId,workflowName,attempt,headSha,url,createdAt']
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def fetch_main_checks_run(repo):
    """Latest finished Checks run on main, {} when there is none, None when gh fails."""
    command = ['gh', 'run', 'list', '--repo', repo, '--workflow', 'Checks', '--branch', 'main',
               '--event', 'push',
               '--status', 'completed', '--limit', '1', '--json', 'databaseId,conclusion,url']
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        return (json.loads(output.stdout) or [{}])[0]
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def run_gh(command):
    try:
        return subprocess.run(command, capture_output=True, timeout=30).returncode
    except (subprocess.SubprocessError, OSError):
        return 1


def fleet_watch_log_path():
    """Return log path; set FLEET_WATCH_LOG_PATH to override the default under HOME."""
    override = (os.environ.get('FLEET_WATCH_LOG_PATH') or '').strip()
    if override:
        return Path(override)
    return Path.home() / '.orca' / 'logs' / 'fleet-watch.log'


def log_fleet_watch(message):
    """Append one line to ~/.orca/logs/fleet-watch.log. Never log terminal screen text."""
    path = fleet_watch_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        line = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + message + '\n'
        with path.open('a', encoding='utf-8') as f:
            f.write(line)
    except OSError:
        pass


METRICS_TAIL_BYTES = 8 * 1024 * 1024
_RECEIPT_FIRST_RE = re.compile(r'^(Review|Verdict): (PASS|FAIL)\b')


def _first_receipts(pr):
    """{'Review': 'PASS'|'FAIL', 'Verdict': ...}: the first receipt of each kind on the PR, in comment order."""
    first = {}
    for comment in pr.get('comments') or []:
        body = (comment.get('body') or '') if isinstance(comment, dict) else ''
        match = _RECEIPT_FIRST_RE.match(body)
        if match and match.group(1) not in first:
            first[match.group(1)] = match.group(2)
    return first


def _rate(passed, total):
    return '%d/%d' % (passed, total) if total else 'n/a'


def hourly_metrics_line(log_lines, merged_prs, hour_start):
    """One `metrics` line for the hour starting at `hour_start` (#1957).

    Pass lines give mean live workers (`live=N`), failed dispatches (`failed=N`) and the dispatch ids that were
    start_unknown or a second live worker on the same `#N|role` title (counted once each per hour). Merged PRs
    in the hour give merged/h, the first Review and first Verdict PASS rates, and the median open to merge hours.
    No dollar usage reading exists, so cost is always n/a."""
    prefix = time.strftime('%Y-%m-%dT%H', time.gmtime(hour_start))
    lives, failed, unknown, dupes = [], 0, set(), set()
    for raw in log_lines:
        if not raw.startswith(prefix) or ' pass ' not in ' ' + raw[21:]:
            continue
        for token in raw[21:].replace(';', ' ').split():
            key, _sep, value = token.partition('=')
            if key == 'live' and value.isdigit():
                lives.append(int(value))
            elif key == 'failed' and value.isdigit():
                failed += int(value)
            elif key == 'start_unknown':
                unknown.update(v for v in value.split(',') if v)
            elif key == 'dup_workers':
                dupes.update(v for v in value.split(',') if v)
    merged, hours, review, verdict = 0, [], [0, 0], [0, 0]
    for pr in merged_prs or []:
        merged_at = _iso_epoch(pr.get('mergedAt'))
        if merged_at is None or not hour_start <= merged_at < hour_start + 3600:
            continue
        merged += 1
        created = _iso_epoch(pr.get('createdAt'))
        if created is not None:
            hours.append((merged_at - created) / 3600.0)
        first = _first_receipts(pr)
        for kind, tally in (('Review', review), ('Verdict', verdict)):
            if kind in first:
                tally[1] += 1
                tally[0] += first[kind] == 'PASS'
    hours.sort()
    if not hours:
        median = 'n/a'
    else:
        mid = len(hours) // 2
        median = '%.1f' % (hours[mid] if len(hours) % 2 else (hours[mid - 1] + hours[mid]) / 2)
    mean_live = '%.1f' % (sum(lives) / float(len(lives))) if lives else 'n/a'
    wasted = len(unknown) + len(dupes) + failed
    return ('metrics hour=%s merged_per_h=%d review_first_pass=%s verdict_first_pass=%s '
            'wasted_starts=%d (start_unknown=%d duplicate=%d failed_dispatch=%d) '
            'median_open_to_merge_h=%s mean_live=%s cost: n/a') % (
        prefix, merged, _rate(*review), _rate(*verdict), wasted, len(unknown), len(dupes), failed, median, mean_live)


def read_log_tail(path=None, limit=METRICS_TAIL_BYTES):
    path = path or fleet_watch_log_path()
    try:
        with open(path, 'rb') as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - limit))
            return handle.read().decode('utf-8', 'replace').splitlines()
    except OSError:
        return []


def fetch_merged_for_metrics(repo, since, run=None):
    """PRs merged since `since` (epoch) with open and merge times and receipts, or [] when gh fails."""
    command = [
        'gh', 'pr', 'list', '--repo', repo, '--state', 'merged', '--limit', '100',
        '--search', 'merged:>=%s' % time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(since)),
        '--json', 'number,createdAt,mergedAt,comments',
    ]
    try:
        out = (run or subprocess.run)(command, capture_output=True, text=True, timeout=30, check=True).stdout
        rows = json.loads(out)
    except (subprocess.SubprocessError, OSError, ValueError):
        return []
    return rows if isinstance(rows, list) else []


def maybe_log_hourly_metrics(config, state, now, fetch=None, log_lines=None):
    """Once per clock hour: log the metrics line for the hour that just ended. Returns the line or None."""
    hour = int(now // 3600) * 3600
    last = state.get('metrics_hour_at')
    if not isinstance(last, (int, float)):
        state['metrics_hour_at'] = hour  # first pass: start counting from this hour
        return None
    if hour <= last:
        return None
    previous = hour - 3600
    rows = []
    for repo in babysit_repos(config):
        rows.extend((fetch or fetch_merged_for_metrics)(repo, previous))
    line = hourly_metrics_line(read_log_tail() if log_lines is None else log_lines, rows, previous)
    log_fleet_watch(line)
    state['metrics_hour_at'] = hour
    return line


def metrics_digest(log_lines, count=12):
    """The last `count` hourly metrics lines, oldest first (wrap-up prints the last 12 hours)."""
    lines = [line for line in log_lines if line[21:].startswith('metrics hour=')]
    return lines[-count:] if count > 0 else []


def pass_waste_parts(workers):
    """`live=N`, plus the dispatch ids that are start_unknown or a second live worker on one `#N|role` title."""
    real = real_live_count()
    parts = ['live=%d' % (active_worker_count(workers) if real is None else real)]
    unknown, seen, dupes = [], set(), []
    for w in workers or []:
        if not isinstance(w, dict):
            continue
        dispatch = str(w.get('dispatchId') or w.get('id') or '')
        if worker_inventory_status(w) == 'start_unknown' and dispatch:
            unknown.append(dispatch)
        if not worker_row_is_live(w):
            continue
        title = next((str(w.get(k) or '') for k in _VERIFIER_TITLE_KEYS if str(w.get(k) or '').startswith('#')), '')
        match = re.match(r'^#\d+\|[a-z][a-z-]*', title)
        if not match:
            continue
        if match.group(0) in seen and dispatch:
            dupes.append(dispatch)
        seen.add(match.group(0))
    if unknown:
        parts.append('start_unknown=%s' % ','.join(sorted(unknown)))
    if dupes:
        parts.append('dup_workers=%s' % ','.join(sorted(dupes)))
    return parts


class PassCounts:
    """One pass: six counters plus a refusal histogram. Zero stays on the line."""

    def __init__(self):
        self.started = 0
        self.refused = 0
        self.parked = 0
        self.failed = 0
        self.sent = 0
        self.send_failed = 0
        self.reasons = {}
        self.phases = []
        self._phase_name = None
        self._phase_started = None
        self.starts = []
        self.worker_starts = 0

    def phase(self, name, now=None):
        """Close the running phase and open `name` (None closes only)."""
        now = time.time() if now is None else now
        if self._phase_name is not None:
            self.phases.append((self._phase_name, now - self._phase_started))
        self._phase_name = name
        self._phase_started = now if name is not None else None

    def phases_line(self, now=None):
        """`phases a=1.2,b=0.3`, with the phase still running last, so a killed pass names where it stopped."""
        rows = list(self.phases)
        if self._phase_name is not None:
            now = time.time() if now is None else now
            rows.append((self._phase_name, now - self._phase_started))
        if not rows:
            return ''
        line = 'phases ' + ','.join('%s=%.1f' % (name, seconds) for name, seconds in rows)
        if self.starts:
            line += ' starts=' + ','.join('%.1f' % seconds for seconds in self.starts)
        return line

    def line(self):
        fields = ' '.join('%s=%d' % (name, getattr(self, name)) for name in (
            'started', 'refused', 'parked', 'failed', 'sent', 'send_failed'))
        reasons = ','.join('%s:%d' % (key, self.reasons[key]) for key in sorted(self.reasons))
        return '%s refused_reasons=%s' % (fields, reasons)


_PASS = None
_ENV_PASS_ID = None
_ENV_NAMES_CACHE = None


def begin_pass_counts():
    """Start a new pass. Counts from the previous pass are dropped."""
    global _PASS, _ENV_PASS_ID, _ENV_NAMES_CACHE
    _PASS = PassCounts()
    _ENV_PASS_ID = id(_PASS)
    _ENV_NAMES_CACHE = None
    return _PASS


def pass_phase(name):
    """Mark the start of a pass phase; the previous phase ends here."""
    if _PASS is not None:
        _PASS.phase(name)


def pass_phases_line():
    return _PASS.phases_line() if _PASS is not None else ''


def log_killed_pass(started, now=None):
    """The wrapper's TERM at its timeout: log the phases so far, so a killed pass names its slow phase."""
    now = time.time() if now is None else now
    phases = pass_phases_line()
    log_fleet_watch('pass killed %.1fs; %s' % (now - started, phases or 'phases none'))


def pass_counts_line():
    counts = _PASS if _PASS is not None else PassCounts()
    return counts.line()


def _pass_note(field):
    if _PASS is not None:
        setattr(_PASS, field, getattr(_PASS, field) + 1)


def count_started():
    _pass_note('started')


def count_worker_started():
    """A start that adds a live worker: counted as started, and against work_order.max_workers this pass (#1957)."""
    count_started()
    if _PASS is not None:
        _PASS.worker_starts += 1


def count_failed():
    _pass_note('failed')


def count_parked():
    _pass_note('parked')


def count_sent():
    _pass_note('sent')


def count_send_failed():
    _pass_note('send_failed')


def reason_token(reason):
    text = re.sub(r'[^a-z0-9]+', '_', str(reason or '').lower()).strip('_')
    return text or 'unknown'


def refusal_token(reason):
    text = str(reason or '').lower()
    if 'usage gate' in text or 'usage_gate' in text:
        return 'usage_gate'
    if 'cap' in text:
        return 'host_cap'
    return reason_token(reason)


ISSUE_CLAIM_LABEL = 'status:進行中'  # worker-startup.sh claim_issue
ISSUE_RESTART_GRACE_SECONDS = 1800  # a started issue restarts only this long after its start (#1811)


def start_delivered_refusal(reason):
    """'delivered by merged PR #n' when worker-startup refused the issue as already delivered, else None (#1811)."""
    match = re.search(r'already delivered by merged PR ((?:#\d+[ ,]*)+)', str(reason or ''))
    if not match:
        return None
    return 'delivered by merged PR %s' % ' '.join(re.findall(r'#\d+', match.group(1)))


def start_gate_refusal(reason):
    """True when worker-startup refused on a gate that says nothing about the brief (#1170 follow-up, #1839)."""
    text = str(reason or '').lower()
    return ('is ready and not started' in text or 'overlaps other work in flight' in text
            or 'already has live ' in text or 'cannot read the live task list' in text)


def count_refused(token):
    if _PASS is None:
        return
    token = reason_token(token)
    _PASS.refused += 1
    _PASS.reasons[token] = _PASS.reasons.get(token, 0) + 1


def one_line_reason(text):
    cleaned = re.sub(r'[\s,;]+', ' ', str(text or '')).strip()
    return cleaned or 'unknown'


def write_automation_summary(text):
    path = (os.environ.get('AUTOMATION_TRACE_SUMMARY_FILE') or '').strip()
    if not path:
        return
    try:
        Path(path).write_text(text + '\n', encoding='utf-8')
    except OSError:
        pass


def finish_pass(message):
    """Append the pass line and give the wrapper the same counts."""
    counts = pass_counts_line()
    line = (message or '').strip()
    if counts not in line:
        line = (line + ' ' + counts).strip() if line else counts
    log_fleet_watch(line)
    write_automation_summary(counts)
    return counts


def _normalize_terminal_time_ms(value):
    """lastOutputAt may be ms since epoch or seconds; return seconds since epoch or None."""
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    if v == 0:
        return None
    if v > 1e12:  # milliseconds
        return v / 1000.0
    if v > 1e10:  # unlikely stray unit
        return v / 1000.0
    return v


GONE_REMOTE_KEY = '_remote_gone'
ASK_REPLY_SECONDS = 5 * 60
ASK_TYPES = ('question', 'escalation')
INBOX_LIMIT = 5000  # one inbox read; a reply this long may have cut older messages, such as an ask


def _remote_ready_record(w):
    """A remote row with a `ready` state and no local terminal: a server record, whether or not it names `server`."""
    host = w.get('host')
    return ((w.get('state') or w.get('workerState')) == 'ready'
            and (_remote_server_row(w) or (isinstance(host, str) and host not in ('', 'local')
                                           and not (w.get('projection') or w.get('agentTerminalHandle')
                                                    or w.get('terminalState') or w.get('resource')))))


def gone_remote_dispatch_notices(workers, state, rpc_call):
    """Mark remote server-record rows whose dispatch has no terminal on its host, and report each once (#1781).

    Remote rows say `ready` whether the worker is working, idle or gone, and `asOf` is not a heartbeat, so the row
    alone proves nothing. The dispatch's terminal (worker-show) must appear in `terminal list --environment <host>`.
    A host whose list or show cannot be read leaves its rows as they were."""
    candidates = {}
    for w in workers or []:
        if (isinstance(w, dict) and _remote_ready_record(w) and worker_row_is_live(w)
                and w.get('dispatchId')):
            candidates.setdefault(projection_host_id(w), []).append(w)
    reported = state.setdefault('gone_remote', [])
    notices = []
    for host, rows in candidates.items():
        try:
            listed = rpc_call('terminal', 'list', '--environment', host)
        except SEND_ERRORS:
            continue
        handles = {t.get('handle') for t in (listed or {}).get('terminals') or [] if isinstance(t, dict)}
        for w in rows:
            dispatch = w['dispatchId']
            try:
                shown = rpc_call('orchestration', 'worker-show', '--dispatch', dispatch, '--environment', host)
            except SEND_ERRORS:
                continue
            if isinstance(shown, dict) and isinstance(shown.get('worker'), dict):
                shown = shown['worker']
            if worker_terminal_handle(shown if isinstance(shown, dict) else {}) in handles - {''}:
                continue
            w[GONE_REMOTE_KEY] = True
            if dispatch not in reported:
                reported.append(dispatch)
                notices.append(Urgent('dead dispatch %s on %s: no terminal on the host; release it with script/release-worker.sh --live %s' % (
                    dispatch, host, dispatch)))
    return notices


def _reply_ids(messages, dispatch, handle):
    targets = {'dispatch:' + dispatch, handle} - {''}
    return {m['id'] for m in messages
            if isinstance(m, dict) and m.get('id') and m.get('to') in targets and m.get('from') != handle
            and m.get('type') not in ASK_TYPES}


def _threaded_reply(messages, ask_id):
    """True when a non-ask message threads to the ask: `orca orchestration reply --id` sends 'Re: Question'
    with its thread id set to the ask id, whatever its recipient handle (#1814)."""
    return any(isinstance(m, dict) and m.get('id') != ask_id and m.get('type') not in ASK_TYPES
               and ask_id in (m.get('threadId'), m.get('thread_id')) for m in messages)


def answered_asks_path():
    """Ask ids that orca-reply.sh found already answered (answer_conflict, #1838)."""
    return Path(os.environ.get('ORCA_REPLY_ANSWERED_FILE')
                or Path.home() / '.local/state/agent-team/answered-asks.txt')


def read_answered_asks(path=None):
    try:
        text = Path(path or answered_asks_path()).read_text(errors='replace')
    except OSError:
        return set()
    return {line.strip() for line in text.splitlines()[-500:] if line.strip()}


def unanswered_ask_notices(state, now, messages, workers, answered=()):
    """Urgent notice, once per message, for a question or escalation from a live worker that nothing answered
    within 5 minutes (#1781, #1947).

    Messages carry no timestamp, so the age runs from the pass that first saw the ask. Inbox `handled` only means
    read, so it is no answer (#1947). An ask has an answer when its id is in `answered` (orca-reply.sh got
    answer_conflict) (#1838), when a later
    non-ask message went to the worker's dispatch or terminal (one not already in the inbox when the ask was first
    seen), or when any non-ask message has the ask id as its thread id (what `orca orchestration reply --id` sends)."""
    live = {w['dispatchId']: w for w in workers or [] if isinstance(w, dict) and w.get('dispatchId') and worker_row_is_live(w)}
    book = state.setdefault('open_asks', {})
    seen = set()
    notices = []
    for m in messages or []:
        if not isinstance(m, dict) or m.get('type') not in ASK_TYPES or not m.get('id'):
            continue
        payload = m.get('payload') if isinstance(m.get('payload'), dict) else {}
        dispatch = payload.get('dispatchId')
        if dispatch not in live:
            continue
        mid = m['id']
        seen.add(mid)
        handle = worker_terminal_handle(live[dispatch]) or m.get('from') or ''
        replies = _reply_ids(messages, dispatch, handle)
        is_new = mid not in book
        row = book.setdefault(mid, {'at': now, 'dispatch': dispatch, 'before': sorted(replies)})
        if is_new:
            row.update(type=m['type'], subject=m.get('subject') or '', asked=m.get('created_at') or utc_stamp(now))
        was_answered = bool(row.get('answered'))
        if mid in answered or replies - set(row['before']) or _threaded_reply(messages, mid):
            row['answered'] = True
        asked = row.get('asked') or utc_stamp(row['at'])
        if is_new:
            log_fleet_watch('ask %s %s from %s asked %s%s' % (
                m['type'], mid, dispatch, asked, ' (already answered)' if row.get('answered') else ''))
        elif row.get('answered') and not was_answered:
            line = 'reply to %s %s from %s: asked %s, answer seen %s, waited %d minutes' % (
                m['type'], mid, dispatch, asked, utc_stamp(now), (now - row['at']) // 60)
            log_fleet_watch(line)
            state.setdefault('ask_reply_lines', []).append(line)
        if row.get('answered') or row.get('notified') or now - row['at'] < ASK_REPLY_SECONDS:
            continue
        row['notified'] = True
        notices.append(Urgent('unanswered %s %s from %s for %d minutes (asked %s): %s; reply to it' % (
            m['type'], mid, dispatch, (now - row['at']) // 60, asked, m.get('subject') or '(no subject)')))
    for mid in list(book):
        if mid not in seen:
            book.pop(mid)
    return notices


def take_ask_reply_lines(state):
    """Stamped reply lines unanswered_ask_notices recorded this pass, for the digest; cleared once taken (#1843)."""
    return state.pop('ask_reply_lines', None) or []


def utc_stamp(epoch):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch))


def open_work_path(state_path):
    """Open asks and live claims, beside the pass state file, printed by elon-startup.sh (#1843).
    Beside the state file, so a test with a temporary state never writes the coordinator's copy."""
    return Path(os.environ.get('ELON_OPEN_WORK_FILE') or Path(state_path).with_name('elon-open-work.md'))


def write_open_work(state, workers, config, now, path, repo_of=None):
    """Rewrite the open work file from unanswered open_asks rows and live workers with an issue, so a compacted
    coordinator still knows them. An answered ask or an ended worker drops out on the next pass."""
    repo_of = repo_of or (lambda w: repo_for_worker(w, config))
    live = [w for w in workers or [] if isinstance(w, dict) and w.get('dispatchId') and worker_row_is_live(w)]
    live_ids = {w['dispatchId'] for w in live}
    asks = ['- %s %s from %s, asked %s: %s' % (row.get('type') or 'ask', mid, row.get('dispatch'),
                                                row.get('asked') or utc_stamp(row.get('at') or now),
                                                row.get('subject') or '(no subject)')
            for mid, row in sorted((state.get('open_asks') or {}).items())
            if isinstance(row, dict) and not row.get('answered') and row.get('dispatch') in live_ids]
    claims = []
    for w in live:
        number = _worker_issue_number(w)
        if not number:
            continue
        try:
            repo = repo_of(w) or '?'
        except (OSError, subprocess.SubprocessError):
            repo = '?'
        claims.append(('- %s#%s %s %s' % (repo, number, w['dispatchId'], w.get('name') or '')).rstrip())
    text = '# Open asks and live claims (fleet-watch, %s)\n\n## Open asks\n%s\n\n## Live claims\n%s\n' % (
        utc_stamp(now), '\n'.join(asks) or 'none', '\n'.join(sorted(claims)) or 'none')
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + '.tmp')
    temporary.write_text(text)
    temporary.replace(target)


def waiting_on_coordinator(state, workers):
    """Dispatch ids of live workers holding an ask nobody answered."""
    live = {w.get('dispatchId') for w in workers or [] if isinstance(w, dict) and worker_row_is_live(w)}
    return {row['dispatch'] for row in (state.get('open_asks') or {}).values()
            if not row.get('answered') and row['dispatch'] in live}


_FINISHED_WORKER_STATES = ('succeeded', 'completed', 'failed', 'cancelled', 'released', 'abandoned', 'stopped')


def worker_row_is_live(w):
    """True when this worker-list row is an in-progress supervised worker (both JSON shapes)."""
    w = w or {}
    if w.get(GONE_REMOTE_KEY):
        return False
    if 'dispatchStatus' in w or 'projection' in w:
        proj = w.get('projection') or {}
        liv = proj.get('liveness') or {}
        ver = liv.get('verdict') if isinstance(liv, dict) else liv
        term_live = w.get('terminalState') in ('active', 'retained') or (
            _remote_server_row(w) and w.get('workerState') in ('ready', 'starting', 'running', 'active')
        )
        return (term_live
                and w.get('dispatchStatus') not in ('completed', 'failed', 'cancelled', 'abandoned')
                and (proj.get('outcome') or 'in_progress') == 'in_progress'
                and ver != 'exited')
    return (w.get('state') not in _FINISHED_WORKER_STATES
            and w.get('stage') != 'released' and w.get('terminalState') != 'released'
            and w.get('liveness') != 'exited')


def holds_pass_terminal(w):
    """True when a fleet_rows row's terminal and worktree stay open this pass. A remote row whose own host says
    it finished (`_state`) does not hold them, though the coordinator's stub can still say ready."""
    if (w or {}).get('_host') and w.get('_state') in _FINISHED_WORKER_STATES:
        return False
    return worker_row_is_live(w)


def _server_as_of_epoch_seconds(w):
    srv = (w or {}).get('server')
    if not isinstance(srv, dict):
        return None
    token = srv.get('asOf')
    if not isinstance(token, str) or not token.strip():
        return None
    age = wait_log_line_age_seconds(token.strip(), 0.0)
    return -age if age is not None else None


def worker_liveness_verdict(w):
    """Orca liveness.verdict when present ('live' means active tool use — not an output stall)."""
    w = w or {}
    proj = w.get('projection') or {}
    liv = proj.get('liveness')
    if isinstance(liv, dict):
        return liv.get('verdict') or liv.get('state')
    if liv:
        return liv
    return w.get('liveness') if isinstance(w.get('liveness'), str) else None


def worker_should_restart_for_terminal_stall(w, now, last_s, stall_limit):
    """True when lastOutputAt staleness should trigger stop/restart for this row (matches local vs remote liveness rule)."""
    if last_s is None:
        return False
    idle = now - last_s
    if idle < stall_limit:
        return False
    if worker_liveness_verdict(w) == 'live':
        return False
    return True


def worker_execution_host_id(w):
    return projection_host_id(w)


def worker_task_id(w):
    w = w or {}
    tid = w.get('taskId')
    if tid:
        return tid
    proj = w.get('projection') or {}
    return proj.get('taskId') or ''


def worker_agent_id(w):
    """Agent id for worker-start, when the row carries one."""
    w = w or {}
    for key in ('agent', 'agentId'):
        a = w.get(key)
        if isinstance(a, str) and a:
            return a
    proj = w.get('projection') or {}
    for key in ('agent', 'agentId'):
        a = proj.get(key)
        if isinstance(a, str) and a:
            return a
    prov = proj.get('provider')
    if isinstance(prov, dict):
        aid = prov.get('id')
        if isinstance(aid, str) and aid:
            return aid
    return ''


def worker_worktree_selector(w):
    """Selector string for --worktree on worker-start (required when using --terminal)."""
    w = w or {}
    resource = w.get('resource') or {}
    ws = w.get('workspace')
    if isinstance(ws, str) and ws:
        return ws
    workspace = (w.get('projection') or {}).get('workspace')
    workspace_id = workspace.get('id') if isinstance(workspace, dict) else None
    wid = resource.get('worktreeId') or w.get('worktreeId') or workspace_id
    if isinstance(wid, str) and wid:
        return wid
    return ''


def worker_branch_name(w):
    """Git branch for gh pr list --head when the row has no PR number."""
    w = w or {}
    for key in ('headRefName', 'branch', 'headBranch'):
        b = w.get(key)
        if isinstance(b, str) and b:
            return b
    proj = w.get('projection') or {}
    for key in ('headRefName', 'branch', 'headBranch'):
        b = proj.get(key)
        if isinstance(b, str) and b:
            return b
    return ''


def terminal_handle_for_configured_run(config, run_id):
    """Sender terminal from config runs[] for this run id, or None when missing or not configured."""
    if not isinstance(run_id, str) or not run_id.strip():
        return None
    needle = run_id.strip()
    for run in config.get('runs') or []:
        if not isinstance(run, dict):
            continue
        rid = run.get('id')
        if not (isinstance(rid, str) and rid.strip() == needle):
            continue
        t = run.get('terminal')
        if isinstance(t, str) and t.strip():
            return t.strip()
        return None
    return None


def worker_stall_restart_start_args(w, old_dispatch_id, run_id, config):
    """Orca worker-start args after a stop; None when the row cannot supply a valid start.

    After worker-stop the previous terminal is closed; do not pass --terminal. Agent and model
    come from the stopped dispatch row or persisted stop record. run_id scopes worker-start to the
    same Run as worker-list (Orca returns task_not_found without --run when the CLI default Run differs).
    Requires a non-empty ``terminal`` on the matching ``runs[]`` row so fleet-watch can pass ``--from``
    when the process has no active sender terminal (cron).
    """
    tid = worker_task_id(w)
    if not tid:
        return None
    wt = worker_worktree_selector(w)
    if not wt:
        return None
    agent = worker_agent_id(w)
    model = worker_model_id(w)
    if not agent or stall_restart_agy_unusable(w, config):
        return None
    rid = run_id_for_stall_restart(w, run_id)
    if not rid:
        return None
    term_from = terminal_handle_for_configured_run(config or {}, rid)
    if term_from is None:
        return None
    args = [
        'bash', _issue_scan_startup_script(config or {}), '--run', rid, '--task', tid,
        '--retry-of', old_dispatch_id, '--worktree', wt, '--agent', agent,
        '--from', term_from,
    ]
    if model:
        args.extend(['--model', model])
    return args


def stall_restart_agy_unusable(w, config):
    """True when an antigravity row's host is signed out of agy, so a restart there would fail (#1966)."""
    host = host_cap_name((w or {}).get('_host') or remote_environment(w), config, None)
    return not _agy_signin().usable(worker_agent_id(w), host, config or {})


def worker_model_id(w):
    w = w or {}
    prov = (w.get('projection') or {}).get('provider')
    if isinstance(prov, dict):
        m = prov.get('model')
        if isinstance(m, str) and m:
            return m
    return ''


def resolve_pr_number_for_worker(w, label_repo, act, branch_hint=''):
    """PR number from the row, or gh pr list --head from the branch.

    Returns (pr_number_or_None, status):
    - ``ok`` — a PR number was found (from the row or from gh).
    - ``lookup_failed`` — gh could not be run or its output was not reliable (retry next pass).
    - ``no_pr`` — lookup succeeded but there is no matching PR for that head (fallback issue).
    """
    n = worker_pr_number(w)
    if n:
        return (n, 'ok')
    branch = worker_branch_name(w) or branch_hint
    if not branch or not label_repo:
        return (None, 'no_pr')
    command = ['gh', 'pr', 'list', '--repo', label_repo, '--head', branch, '--state', 'all', '--limit', '1', '--json', 'number']
    try:
        out = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
    except (subprocess.SubprocessError, OSError):
        return (None, 'lookup_failed')
    try:
        data = json.loads(out.stdout)
    except (ValueError, TypeError):
        return (None, 'lookup_failed')
    if not isinstance(data, list):
        return (None, 'lookup_failed')
    if not data:
        return (None, 'no_pr')
    first = data[0]
    if not isinstance(first, dict):
        return (None, 'lookup_failed')
    num = first.get('number')
    if isinstance(num, int) and num > 0:
        return (num, 'ok')
    return (None, 'no_pr')


def worker_terminal_handle(w):
    w = w or {}
    t = w.get('terminal')
    if isinstance(t, str) and t:
        return t
    return w.get('agentTerminalHandle') or ''


def worker_pr_number(w):
    """Optional GitHub PR number from a worker-list row for labeling."""
    w = w or {}
    for key in ('githubPullRequestNumber', 'pullRequestNumber', 'prNumber'):
        n = w.get(key)
        if isinstance(n, int) and n > 0:
            return n
        if isinstance(n, str) and n.strip().isdigit():
            v = int(n.strip(), 10)
            if v > 0:
                return v
    proj = w.get('projection') or {}
    for key in ('githubPullRequestNumber', 'pullRequestNumber', 'prNumber', 'number'):
        n = proj.get(key)
        if isinstance(n, int) and n > 0:
            return n
        if isinstance(n, str) and n.strip().isdigit():
            v = int(n.strip(), 10)
            if v > 0:
                return v
    return None


def _git_branch_short_from_ref(ref):
    """refs/heads/foo -> foo, or '' when missing or not a local branch ref."""
    if not isinstance(ref, str) or not ref.startswith('refs/heads/'):
        return ''
    return ref[len('refs/heads/'):]


def terminal_last_output_map(result):
    """Map terminal handle -> lastOutputAt from terminal list result dict."""
    terminals = (result or {}).get('terminals') or []
    out = {}
    for t in terminals:
        h = t.get('handle')
        if h:
            out[h] = t.get('lastOutputAt')
    return out


def terminal_branch_map(result):
    """Map terminal handle -> short branch name (from refs/heads/...) for gh pr list --head."""
    terminals = (result or {}).get('terminals') or []
    out = {}
    for t in terminals:
        h = t.get('handle')
        if h:
            b = _git_branch_short_from_ref(t.get('branch') or '')
            if b:
                out[h] = b
    return out


def stall_state_key(w):
    """Persist one restart per task; fall back to dispatch when task id is missing."""
    tid = worker_task_id(w)
    if tid:
        return tid
    did = w.get('dispatchId')
    return 'dispatch:%s' % did if did else ''


def stall_restart_start_blocked_log(old_dispatch_id, config, w, run_id):
    """Log line when worker_stall_restart_start_args would return None; empty string when start is possible."""
    if not worker_task_id(w):
        return 'stall_pending_no_args=%s' % old_dispatch_id
    if not worker_worktree_selector(w):
        return 'stall_pending_no_args=%s' % old_dispatch_id
    if not worker_agent_id(w):
        return 'stall_pending_no_args=%s' % old_dispatch_id
    if stall_restart_agy_unusable(w, config):
        return 'stall_restart_agy_unusable=%s' % old_dispatch_id
    rid = run_id_for_stall_restart(w, run_id) or default_list_run_id(config)
    if not rid:
        return 'stall_pending_no_args=%s' % old_dispatch_id
    if terminal_handle_for_configured_run(config, rid) is None:
        return 'stall_no_sender_terminal=%s' % old_dispatch_id
    return ''


def _dispatch_id_in(data):
    if not isinstance(data, dict):
        return ''
    for key in ('dispatchId', 'dispatch_id'):
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    for key in ('result', 'worker'):
        found = _dispatch_id_in(data.get(key))
        if found:
            return found
    return ''


def dispatch_id_from_text(text):
    """Dispatch id from a worker-start JSON reply, or '' when the text has none."""
    raw = text if isinstance(text, str) else ''
    decoder = json.JSONDecoder()
    idx = 0
    while True:
        start = raw.find('{', idx)
        if start < 0:
            return ''
        try:
            data, end = decoder.raw_decode(raw[start:])
        except json.JSONDecodeError:
            idx = start + 1
            continue
        found = _dispatch_id_in(data)
        if found:
            return found
        idx = start + max(end, 1)


def dispatch_id_from_start(result):
    if isinstance(result, dict):
        return _dispatch_id_in(result)
    did = getattr(result, 'dispatch_id', None)
    if isinstance(did, str) and did.strip():
        return did.strip()
    return ''


def record_own_dispatch(state, dispatch_id, kind, retry_of=None, restart_at=None, restarted=False, repo=None):
    """Remember a dispatch fleet-watch started. Empty ids are ignored. `repo` feeds fleet_rows' `_repo` (#1958)."""
    did = dispatch_id.strip() if isinstance(dispatch_id, str) else ''
    if not did:
        return
    bucket = state.setdefault('own_dispatches', {})
    if not isinstance(bucket, dict):
        bucket = {}
        state['own_dispatches'] = bucket
    row = bucket.get(did)
    if not isinstance(row, dict):
        row = {}
        bucket[did] = row
    row.setdefault('kind', kind)
    if retry_of and not row.get('retry_of'):
        row['retry_of'] = retry_of
    if restarted:
        row['restarted'] = True
    if restart_at is not None and row.get('restart_at') is None:
        row['restart_at'] = restart_at
    if repo:
        row.setdefault('repo', repo)


def remember_started_dispatch(state, result, kind, repo=None):
    """Record a verifier, rework worker, or scanned issue. Other starts are not ours to restart."""
    if kind not in ('verifier', 'rework', 'issue'):
        return
    record_own_dispatch(state, dispatch_id_from_start(result), kind, repo=repo)


def _own_row(state, dispatch_id):
    row = (state.get('own_dispatches') or {}).get(dispatch_id)
    return row if isinstance(row, dict) else None


def _retry_recorded(state, dispatch_id):
    bucket = state.get('own_dispatches') or {}
    if not isinstance(bucket, dict):
        return False
    for row in bucket.values():
        if isinstance(row, dict) and row.get('retry_of') == dispatch_id:
            return True
    return False


def _report_foreign_stall(state, dispatch_id, notices, log_bits):
    reported = state.setdefault('stall_reported', {})
    if not isinstance(reported, dict):
        reported = {}
        state['stall_reported'] = reported
    if reported.get(dispatch_id):
        return
    reported[dispatch_id] = True
    log_bits.append('stall_report=%s' % dispatch_id)
    notices.append(Urgent(
        'stalled worker %s is not one fleet-watch started; fleet-watch nudges it after %d stall windows with '
        'no new commit and stops and releases it after %d, unless it holds unpushed work; recover it by hand with '
        '~/dotfiles/.agents/skills/orca-team/worker-watch.sh' % (dispatch_id, STALL_NUDGE_WINDOWS, STALL_RELEASE_WINDOWS)))


REMOTE_READ_PAGE = 100
REMOTE_READ_MAX_PAGES = 20
_ACTIVITY_BLOCK_TYPES = ('tool-call', 'tool-result')


def remote_worker_activity(rpc_call, dispatch_id, environment, now, stall_limit):
    """'active', 'silent' or 'unknown' for a remote dispatch; see remote_last_activity."""
    return remote_last_activity(rpc_call, dispatch_id, environment, now, stall_limit)[0]


def remote_last_activity(rpc_call, dispatch_id, environment, now, stall_limit):
    """('active' | 'silent' | 'unknown', newest tool activity in epoch seconds or None) for a remote dispatch.

    worker-read pages oldest first, so every page is read until the cursor ends. A transcript longer
    than the page cap, or a read that fails twice, is 'unknown' and the worker is neither flagged nor stopped.
    A failed read is tried once more before that (#1842); the page cap is not, since a retry cannot pass it.
    """
    newest = None
    cursor = ''
    retry_left = 1
    for _ in range(REMOTE_READ_MAX_PAGES):
        args = ['orchestration', 'worker-read', '--dispatch', dispatch_id, '--limit', str(REMOTE_READ_PAGE)]
        if environment:
            args += ['--environment', environment]
        if cursor:
            args += ['--cursor', cursor]
        try:
            result = rpc_call(*args)
        except SEND_ERRORS:
            if not retry_left:
                return 'unknown', None
            retry_left = 0
            try:
                result = rpc_call(*args)
            except SEND_ERRORS:
                return 'unknown', None
        transcript = result.get('transcript') if isinstance(result, dict) else None
        transcript = transcript if isinstance(transcript, dict) else {}
        messages = [m for m in (transcript.get('messages') or []) if isinstance(m, dict)]
        for message in messages:
            blocks = message.get('blocks') or []
            if not any(isinstance(b, dict) and b.get('type') in _ACTIVITY_BLOCK_TYPES for b in blocks):
                continue
            stamp = _normalize_terminal_time_ms(message.get('timestamp'))
            if stamp is not None and (newest is None or stamp > newest):
                newest = stamp
        cursor = transcript.get('nextCursor') or ''
        if not cursor or not messages:
            break
    else:
        return 'unknown', None
    if cursor:
        return 'unknown', None
    if newest is None:
        return 'silent', None
    return ('active' if now - newest < stall_limit else 'silent'), newest


def _stall_notice_reason(reason, code):
    """Recorded message, with the error code kept when the message does not already contain it."""
    text = reason or ''
    if code and code not in text:
        text = '%s (%s)' % (text, code) if text else code
    return text


def _park_own_stall(state, dispatch_id, now, reason, notices, log_bits, config,
                    repo='', pr=None, fail_log=True):
    """Park one own-worker stall once. The notice keeps the recorded message and the error code."""
    record_own_dispatch(state, dispatch_id, 'restart')
    row = _own_row(state, dispatch_id)
    key = park_id('stall', dispatch_id)
    if (row is not None and row.get('parked')) or park_is_active(state, key, config):
        return
    if row is not None:
        row['parked'] = True
        row['parked_at'] = now
        row['park_reason'] = reason
    pr_num = pr if isinstance(pr, int) else None
    park_failure(
        state, key, reason or '', config, dispatch=dispatch_id,
        repo=repo or '', pr=pr_num,
    )
    log_bits.append('stall_parked=%s' % dispatch_id)
    if fail_log:
        log_bits.append('stall_restart_fail=%s:%s' % (dispatch_id, reason or 'parked'))
    notices.append(park_notice('stall', dispatch_id, reason))


def _dispatch_is_pending(pending, dispatch_id):
    for pend in pending.values():
        if (
            isinstance(pend, dict)
            and pend.get('old_dispatch') == dispatch_id
            and not pend.get('started')
            and not pend.get('gave_up')
        ):
            return True
    return False


def _drop_pending_dispatch(pending, dispatch_id):
    for skey, pend in list(pending.items()):
        if isinstance(pend, dict) and pend.get('old_dispatch') == dispatch_id:
            pending.pop(skey, None)


def _remember_stall_stop(state, w, did, label_repo):
    stopped = {'dispatch': did}
    if isinstance(label_repo, str) and label_repo:
        stopped['repo'] = label_repo
    pr_num = worker_pr_number(w)
    if pr_num:
        stopped['pr'] = pr_num
    state.setdefault('stall_stopped', {})[worker_task_id(w) or did] = stopped


def _record_stall_restart(state, old_dispatch, result, now, log_bits, pending):
    record_own_dispatch(state, old_dispatch, 'restart', restarted=True, restart_at=now)
    row = _own_row(state, old_dispatch)
    if row is not None:
        row['restarted'] = True
        row['restart_at'] = now
    new_id = dispatch_id_from_start(result)
    if new_id and new_id != old_dispatch:
        kind = (row or {}).get('kind') or 'restart'
        record_own_dispatch(state, new_id, kind, retry_of=old_dispatch, restart_at=now)
        _own_row(state, new_id).update(
            {name: row[name] for name in ('repo', 'pr', 'head') if row and name in row})
    _drop_pending_dispatch(pending, old_dispatch)
    log_bits.append('stall_restart=%s' % old_dispatch)


def _defer_stall_restart(pending, w, did, run_for_start, reason, repo, pr_num):
    skey = stall_state_key(w) or did
    wt_sel = worker_worktree_selector(w)
    snap = {
        'taskId': worker_task_id(w),
        'resource': {'worktreeId': wt_sel} if wt_sel else {},
        'projection': {
            'provider': {
                'id': worker_agent_id(w),
                'model': worker_model_id(w) or None,
            },
        },
    }
    r_id = run_id_for_stall_restart(w, run_for_start)
    if isinstance(r_id, str) and r_id.strip():
        snap['runId'] = r_id.strip()
    pending[skey] = {
        'old_dispatch': did,
        'stall_restart_run_id': run_for_start,
        'row_snapshot': snap,
        'started': False,
        'failures': 0,
        'reason': reason,
        'repo': repo,
        'pr': pr_num,
    }


STALL_NUDGE_WINDOWS = 2  # nudge once a stall has lasted this many windows with no new commit
STALL_RELEASE_WINDOWS = 3  # stop and release after this many, and at least one window after the nudge
STALL_NUDGE_TEXT = ('fleet-watch: no new commit for %d minutes. Commit and push your progress, or send '
                    'worker_done or an ask. With no new commit in %d minutes this worker is stopped and released.')


def set_board_status(rpc_call, worker, status, environment=''):
    """Move the worker's Orca card. Board trouble never breaks the caller."""
    path = worker_checkout_path(worker)
    if not path.startswith('/'):
        return False
    args = ['worktree', 'set', '--worktree', 'path:%s' % path, '--workspace-status', status]
    if environment:
        args += ['--environment', environment]
    try:
        rpc_call(*args)
    except SEND_ERRORS:
        return False
    return True


# Terminals a release never closes, refreshed each pass: coordinator and lead handles, and
# handle -> dispatch for every live worker the pass saw (#1947).
_PROTECTED_HANDLES = set()
_LIVE_TERMINALS = {}
_UNREAD_WORKER_HOSTS = set()  # hosts whose worker list fleet_rows could not read this pass
# worker-stop answers this for a dispatch that is already gone, so there is nothing left to stop (#1958).
_STOP_SETTLED_CODES = frozenset(('dispatch_not_found',))


def _env_args(environment):
    return ('--environment', environment) if environment else ()


def _shown_terminal(shown):
    if isinstance(shown, dict) and isinstance(shown.get('worker'), dict) and not shown.get('terminal'):
        shown = shown['worker']
    if not isinstance(shown, dict):
        return ''
    term = shown.get('terminal')
    if isinstance(term, dict):
        term = term.get('handle')
    return term if isinstance(term, str) and term else worker_terminal_handle(shown)


def resolve_worker_terminal(rpc_call, dispatch_id, environment='', handle=''):
    """The dispatch's terminal handle, asked of the host that holds it first. A coordinator row for a remote
    worker carries no terminal, so the handle comes from worker-show there (#1947). '' when none is known."""
    if handle:
        return handle
    for where in ((_env_args(environment),) if environment else ()) + ((),):
        try:
            found = _shown_terminal(rpc_call('orchestration', 'worker-show', '--dispatch', dispatch_id, *where))
        except SEND_ERRORS:
            continue
        if found:
            return found
    return ''


def close_guard(handle, dispatch_id=''):
    """Why `handle` must stay open, else ''. The coordinator's and leads' terminals, and a terminal another
    live dispatch uses, are never closed (#1947)."""
    if not handle:
        return 'no_handle'
    if handle in _PROTECTED_HANDLES or handle == (os.environ.get('ORCA_TERMINAL_HANDLE') or '').strip():
        return 'coordinator'
    owner = _LIVE_TERMINALS.get(handle)
    if owner and owner != dispatch_id:
        return 'live:' + owner
    return ''


def close_worker_terminal(rpc_call, handle, environment='', dispatch_id=''):
    """Close a terminal on the host that holds it, through close_guard. worker-stop and worker-release leave a
    remote terminal open (#1947). Returns 'closed', 'kept:<why>' or 'failed'."""
    why = close_guard(handle, dispatch_id)
    if why:
        return 'kept:' + why
    try:
        rpc_call('terminal', 'close', *_env_args(environment), '--terminal', handle)
    except SEND_ERRORS:
        return 'failed'
    log_fleet_watch('closed terminal %s%s%s' % (
        handle, ' on ' + environment if environment else '', ' of ' + dispatch_id if dispatch_id else ''))
    return 'closed'


# ---- heavy jobs and what they leave behind (#2068) ------------------------------------------------------------

HEAVY_RES_RE = re.compile(r'HR\|(\w+)\|(\d*)\|([^|]*)\|(\d*)\|([^|]*)\|([^|]*)\|(.*?)\|EOR')
HEAVY_JOB_KINDS = ('xcodebuild', 'build', 'tsc', 'playwright', 'regression', 'tests')


def classify_process(command):
    """(type, kind) of one process command line: ('dev', 'dev server'), ('emu', 'emulator'),
    ('job', <HEAVY_JOB_KINDS>) or ('', ''). The program name decides, so an agent whose brief
    only mentions `next build` never matches (the way reap-orphan-tests.sh reads a command)."""
    words = command.split()
    if not words:
        return '', ''
    prog = os.path.basename(words[0])
    rest = [os.path.basename(w) if '/' in w and not w.startswith('-') else w for w in words[1:]]
    first = rest[0] if rest else ''
    second = rest[1] if len(rest) > 1 else ''
    if prog == 'xcodebuild':
        return 'job', 'xcodebuild'
    if prog in ('bash', 'sh', 'zsh') and first == 'build-and-test.sh':
        return 'job', 'xcodebuild'
    if prog == 'emulator' or prog.startswith('qemu-system'):
        return 'emu', 'emulator'
    if prog in ('bun', 'bunx', 'npm', 'npx', 'pnpm', 'yarn'):
        joined = ' '.join(rest)
        if re.match(r'(?:run )?build\b', joined):
            return 'job', 'build'
        if re.match(r'(?:run )?dev\b|--hot\b', joined):
            return 'dev', 'dev server'
        if first == 'next' and second in ('build', 'dev'):
            return ('job', 'build') if second == 'build' else ('dev', 'dev server')
        if first == 'test':
            return 'job', 'tests'
        if first == 'playwright' or joined.startswith('run playwright'):
            return 'job', 'playwright'
        if first == 'tsc':
            return 'job', 'tsc'
        if 'regression' in joined:
            return 'job', 'regression'
        return '', ''
    if prog == 'node' or prog.startswith('node'):
        if first == 'next':
            return ('job', 'build') if second == 'build' else ('dev', 'dev server') if second == 'dev' else ('', '')
        if first in ('tsc', 'tsc.js'):
            return 'job', 'tsc'
        if first in ('playwright', 'cli.js') and second == 'test':
            return 'job', 'playwright'
        if first in ('vite', 'nuxt', 'astro'):
            return 'dev', 'dev server'
    if prog.startswith('next-server') or prog == 'vite':
        return 'dev', 'dev server'
    if prog == 'php' and first == 'artisan' and second == 'serve':
        return 'dev', 'dev server'
    if prog == 'tsc':
        return 'job', 'tsc'
    if prog == 'playwright' and first == 'test':
        return 'job', 'playwright'
    return '', ''


def _etime_seconds(text):
    days, _, clock = text.rpartition('-')
    parts = [int(p) for p in clock.split(':') if p.isdigit()]
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds + (int(days) * 86400 if days.isdigit() else 0)


def process_cwd(pid):
    """Working directory of a process: /proc where it exists, else lsof; '' when unknown."""
    try:
        return os.readlink('/proc/%d/cwd' % pid)
    except OSError:
        pass
    try:
        out = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True,
                             timeout=10, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ''
    return next((line[1:] for line in out.splitlines() if line.startswith('n')), '')


def heavy_resources_local(run=subprocess.run):
    """This host's booted simulators and emulators, dev servers and running heavy jobs, as dicts (#2068):
    type (sim, emu, dev, job), id (udid or pid), name, pid, age seconds, cwd, kind, command."""
    found = []
    try:
        listing = run(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'], capture_output=True, text=True, timeout=30)
        devices = json.loads(listing.stdout or '{}').get('devices') or {}
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        devices = {}
    for group in devices.values() if isinstance(devices, dict) else []:
        for device in group if isinstance(group, list) else []:
            if isinstance(device, dict) and device.get('state') == 'Booted' and device.get('udid'):
                found.append({'type': 'sim', 'id': device['udid'], 'name': str(device.get('name') or ''), 'pid': 0,
                              'age': 0, 'cwd': '', 'kind': 'simulator', 'command': ''})
    try:
        ps = run(['ps', '-ww', '-u', str(os.getuid()), '-o', 'pid=,etime=,command='], capture_output=True, text=True,
                 timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        ps = ''
    for line in ps.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit() or int(parts[0]) == os.getpid():
            continue
        kind_type, kind = classify_process(parts[2])
        if not kind_type:
            continue
        pid = int(parts[0])
        name = ''
        if kind_type == 'emu':
            avd = re.search(r'(?:-avd\s+|\s@)(\S+)', parts[2])
            if not avd:
                continue
            name = avd.group(1)
        found.append({'type': kind_type, 'id': str(pid), 'name': name, 'pid': pid, 'age': _etime_seconds(parts[1]),
                      'cwd': process_cwd(pid), 'kind': kind, 'command': parts[2][:120].replace('|', '/')})
    return found


def format_heavy_resources(found):
    return ['HR|%s|%s|%s|%d|%s|%s|%s|EOR' % (r['type'], r['pid'] or '', r['name'], r['age'], r['cwd'], r['kind'],
                                           (r['id'] if r['type'] == 'sim' else r['command']))
            for r in found] + ['HR-END']


def parse_heavy_resources(lines):
    """Resources from the lines format_heavy_resources prints, or None when the read did not end (#2068).
    A terminal read wraps long lines, so the rows are joined and cut on the markers."""
    text = ''.join(str(line) for line in lines)
    if 'HR-END' not in text:
        return None
    found = []
    for kind_type, pid, name, age, cwd, kind, tail in HEAVY_RES_RE.findall(text):
        found.append({'type': kind_type, 'id': tail if kind_type == 'sim' else pid, 'name': name,
                      'pid': int(pid) if pid else 0, 'age': int(age or 0), 'cwd': cwd, 'kind': kind,
                      'command': '' if kind_type == 'sim' else tail})
    return found


HEAVY_RES_REMOTE = 'python3 "$HOME/dotfiles/script/fleet-watch.py" --heavy-resources %s %s'


def heavy_resources_on(rpc_call, host):
    """Resources on one host ('' is this one), or None when they cannot be read."""
    if not host:
        return heavy_resources_local()
    try:
        lines = reap_orphan_remote_lines(rpc_call, host, HEAVY_RES_REMOTE % ('list', ''))
    except (OSError, subprocess.SubprocessError, OrcaReadError, TerminalNotFound) + SEND_ERRORS:
        return None
    return parse_heavy_resources(lines)


def _workspaces_root():
    return os.path.realpath(os.environ.get('FLEET_WATCH_WORKSPACES_ROOT') or os.path.expanduser('~/orca/workspaces'))


def teardown_path_ok(path):
    """True for an absolute worktree path at least two levels below the Orca workspaces folder (<repo>/<name>)."""
    if not isinstance(path, str) or not path.startswith('/') or '..' in path.split('/'):
        return False
    real = os.path.realpath(path)
    root = _workspaces_root()
    return real.startswith(root + '/') and len(real[len(root) + 1:].split('/')) >= 2


def _under(cwd, path):
    return bool(cwd) and (cwd == path or cwd.startswith(path.rstrip('/') + '/'))


def owner_tokens(path):
    """Words that name a worktree in a simulator or emulator name: its folder name and every number in it."""
    base = os.path.basename(path.rstrip('/'))
    return base, re.findall(r'\d{2,}', base)


def name_owned_by(name, path):
    """A booted device belongs to a worktree when its name holds the folder name or a number from it (verify-10779-se)."""
    base, numbers = owner_tokens(path)
    if not name:
        return False
    return (bool(base) and base in name) or any(re.search(r'(?<!\d)%s(?!\d)' % n, name) for n in numbers)


def resource_owned_by(res, path):
    """A simulator is the worktree's by name; an emulator by name or by a working directory under it; a dev server or job by directory."""
    if res['type'] == 'sim':
        return name_owned_by(res['name'], path)
    if res['type'] == 'emu':
        return name_owned_by(res['name'], path) or _under(res['cwd'], path)
    return _under(res['cwd'], path)


def stop_process(pid, grace=None, alive=None, kill=os.kill):
    """TERM, wait up to the grace, then KILL. By pid only. True when it is gone."""
    grace = float(os.environ.get('FLEET_WATCH_TEARDOWN_GRACE', '3')) if grace is None else grace
    alive = alive or (lambda p: _pid_alive(p))
    try:
        kill(pid, signal.SIGTERM)
    except OSError:
        return not alive(pid)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and alive(pid):
        time.sleep(0.1)
    if alive(pid):
        try:
            kill(pid, signal.SIGKILL)
        except OSError:
            pass
        time.sleep(0.1)
    return not alive(pid)


def _pid_alive(pid):
    try:
        done, _status = os.waitpid(pid, os.WNOHANG)  # a child of this process that exited is a zombie until reaped
        if done:
            return False
    except ChildProcessError:
        pass
    except OSError:
        pass
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def teardown_heavy_resources(path, resources=None, run=subprocess.run):
    """Shut down every simulator or emulator and every dev server that belongs to the worktree `path` (#2068).

    A simulator or emulator is the worktree's when its name holds the folder name or the issue number, a dev server
    when its working directory is under the path. Nothing else is touched, so the shared booted simulator that other
    runs use stays up. Returns one line per resource. A path outside the Orca workspaces folder tears down nothing."""
    if not teardown_path_ok(path):
        return []
    real = os.path.realpath(path)
    found = heavy_resources_local() if resources is None else resources
    lines = []
    for res in found:
        if res['type'] not in ('sim', 'emu', 'dev') or not (resource_owned_by(res, path) or resource_owned_by(res, real)):
            continue
        if res['type'] == 'sim':
            try:
                done = run(['xcrun', 'simctl', 'shutdown', res['id']], capture_output=True, text=True, timeout=60)
                gone = done.returncode == 0
            except (OSError, subprocess.SubprocessError):
                gone = False
        else:
            gone = stop_process(res['pid'])
        label = {'sim': 'simulator', 'emu': 'emulator', 'dev': 'dev server'}[res['type']]
        lines.append('%s %s %s' % ('stopped' if gone else 'could not stop', label, res['name'] or res['command'][:60] or res['id']))
    return lines


def teardown_worker_resources(rpc_call, row):
    """On worker end, shut down what the worker left running in its worktree, on its host (#2068).
    Never raises and never changes what release_worker returns. Returns the teardown lines."""
    try:
        host = (row or {}).get('_host') or ''
        path = (worker_checkout_path(row) or str((row or {}).get('_host_workspace') or '').split('::')[-1]).rstrip('/')
        if not path.startswith('/'):
            return []
        if not host:
            lines = teardown_heavy_resources(path)
        else:
            lines = [str(l).strip() for l in reap_orphan_remote_lines(
                rpc_call, host, HEAVY_RES_REMOTE % ('teardown --worktree', shlex.quote(path)))
                if str(l).strip().startswith(('stopped ', 'could not stop '))]
    except Exception as error:  # a teardown failure must never keep a worker from being released
        log_fleet_watch('heavy teardown skipped for %s: %r' % ((row or {}).get('dispatchId'), error))
        return []
    for line in lines:
        log_fleet_watch('heavy teardown %s%s: %s' % ((row or {}).get('dispatchId') or '', ' on ' + host if host else '', line))
    return lines


def heavy_job_report(config, now, workers, rpc_call, lister=None, env_names=None):
    """Per host: running heavy jobs and orphans (#2068), for the fleet-watch state and elon-tick.

    A job is owned by a live worker whose checkout holds its working directory, or by head checks when it runs in a
    `_checks` worktree. An orphan is a booted simulator or emulator no live worker's name matches (and no heavy
    job on the host could be using), or a dev server whose directory no live worker holds. Hosts that cannot be read
    are listed under `unread`."""
    lister = lister or heavy_resources_on
    env_names = environment_name_by_id() if env_names is None else env_names
    rows_by_host = {}
    for row in workers or []:
        if isinstance(row, dict) and worker_row_is_live(row):
            env = row.get('_host') or ''
            if not env and worker_is_remote(row, config):
                env = remote_environment(row)
            key = host_cap_name(env, config, env_names).lower() if env else ''
            rows_by_host.setdefault(key, []).append(row)
    report = {'at': now, 'hosts': {}, 'unread': []}
    local = (config.get('local_host') or '').strip() or 'local'
    for env in sweep_hosts(config):
        found = lister(rpc_call, env)
        name = local if not env else host_cap_name(env, config, env_names)
        if found is None:
            report['unread'].append(name)
            continue
        rows = rows_by_host.get(name.lower() if env else '', [])
        paths = [(row, (worker_checkout_path(row) or str(row.get('_host_workspace') or '').split('::')[-1]).rstrip('/'))
                 for row in rows]
        busy = any(r['type'] == 'job' and r['kind'] == 'xcodebuild' for r in found)
        jobs, orphans = [], []
        for res in found:
            owner = next((row.get('dispatchId') for row, path in paths if path.startswith('/') and (
                resource_owned_by(res, path))), None)
            if res['type'] == 'job' or (owner is not None and res['type'] in ('sim', 'emu')):
                if owner is None and re.search(r'/_checks(?:-\d+)?(?:/|$)', res['cwd'] or ''):
                    owner = 'head-checks'
                jobs.append({'worker': owner or 'no live worker', 'kind': res['kind'], 'minutes': res['age'] // 60})
            elif owner is None and res['type'] != 'job':
                if res['type'] == 'sim' and busy:
                    continue  # the shared booted simulator while a test run uses it
                orphans.append({'type': res['type'], 'name': res['name'] or res['command'][:60], 'id': res['id'],
                                'minutes': res['age'] // 60})
        if jobs or orphans:
            report['hosts'][name] = {'env': env, 'jobs': jobs, 'orphans': orphans}
    return report


def heavy_jobs_pass(config, state, now, workers, rpc_call, lister=None, env_names=None):
    """Write the heavy job report into the fleet-watch state for elon-tick to read (#2068)."""
    state['heavy_jobs'] = heavy_job_report(config, now, workers, rpc_call, lister, env_names)
    return state['heavy_jobs']


def release_worker(rpc_call, row):
    """The one retire path (#1958): stop, release, close the terminal, mark the row released.

    worker-stop and worker-release go to the row's host (`_host`, '' for this one) and, for a remote row, here
    too. A stop error other than an already gone dispatch returns 'stop_failed:<code>' and does nothing else.
    Returns 'closed', 'kept:<why>', 'failed' or 'stop_failed:<code>'."""
    did = (row or {}).get('dispatchId') or ''
    if not did:
        return 'kept:no_dispatch'
    host = row.get('_host') or ''
    wheres = ((_env_args(host),) if host else ()) + ((),)
    handle = '' if row.get('_terminal_gone') else resolve_worker_terminal(
        rpc_call, did, host, row.get('_host_terminal') or worker_terminal_handle(row))
    for where in wheres:
        try:
            rpc_call('orchestration', 'worker-stop', '--dispatch', did, *where)
        except SEND_ERRORS as exc:
            code = orchestration_failure_log_code(exc) or 'error'
            if code not in _STOP_SETTLED_CODES:
                return 'stop_failed:' + code
    teardown_worker_resources(rpc_call, row)  # #2068: a simulator or dev server the worker left running dies with it
    for where in wheres:
        try:
            rpc_call('orchestration', 'worker-release', '--dispatch', did, *where)
        except SEND_ERRORS:
            pass
    closed = close_worker_terminal(rpc_call, handle, host, did)
    _mark_worker_released(row)
    return closed


def _release_row(row):
    """The default release callback: one row in, release_worker's result out."""
    return release_worker(rpc, row)


def row_for_dispatch(rows, dispatch_id, host=''):
    """The pass row for `dispatch_id`, else a minimal row that release_worker can still act on."""
    for row in rows or []:
        if isinstance(row, dict) and row.get('dispatchId') == dispatch_id:
            return row
    return {'dispatchId': dispatch_id, '_host': host or ''}


def protect_pass_terminals(config, workers):
    """Refresh the handles a release never closes, from the pass config and worker rows."""
    _PROTECTED_HANDLES.clear()
    _LIVE_TERMINALS.clear()
    for row in list((config or {}).get('runs') or []) + list((config or {}).get('leads') or []):
        if isinstance(row, dict):
            for key in ('terminal', 'coordinator_handle', 'handle'):
                if isinstance(row.get(key), str) and row[key].strip():
                    _PROTECTED_HANDLES.add(row[key].strip())
    for w in workers or []:
        if isinstance(w, dict) and w.get('dispatchId') and holds_pass_terminal(w):
            handle = w.get('_host_terminal') or worker_terminal_handle(w)
            if handle:
                _LIVE_TERMINALS[handle] = w['dispatchId']


def _worker_state(w):
    """Worker state in either worker-list shape: workerState (--full), state, or projection.stage.worker."""
    stage = (w.get('projection') or {}).get('stage') if isinstance(w.get('projection'), dict) else None
    return w.get('workerState') or w.get('state') or (stage.get('worker') if isinstance(stage, dict) else None)


START_UNKNOWN_RESEND_SECONDS = 10 * 60
START_UNKNOWN_REAP_SECONDS = 20 * 60  # from first seen; the reap waits for a real resend too


def resend_brief(rpc_call, row):
    """Send the dispatch's brief into its terminal again, on the row's host. True when it was sent (#1962)."""
    did = (row or {}).get('dispatchId') or ''
    task = row.get('taskId')
    host = row.get('_host') or ''
    handle = resolve_worker_terminal(rpc_call, did, host, row.get('_host_terminal') or worker_terminal_handle(row))
    if not task or not handle or close_guard(handle, did):
        return False
    try:
        shown = rpc_call('orchestration', 'dispatch-show', '--task', task, '--preamble', *_env_args(host))
        brief = shown.get('preamble') if isinstance(shown, dict) else None
        if not isinstance(brief, str) or not brief.strip():
            return False
        rpc_call('terminal', 'send', *_env_args(host), '--terminal', handle, '--text', brief, '--enter')
    except SEND_ERRORS:
        return False
    return True


def _start_unknown_relabel(w, act):
    """Put the row's issue back to ready-for-agent. Returns the log suffix."""
    number = _worker_issue_number(w)
    repo = w.get('_repo') or ''
    if not number or worker_pr_number(w):
        return ''
    if repo and (act or run_gh)(['gh', 'issue', 'edit', str(number), '--repo', repo, '--add-label',
                                 'ready-for-agent', '--remove-label', ISSUE_CLAIM_LABEL]) == 0:
        return '; %s#%d back to ready-for-agent' % (repo, number)
    return '; put issue #%d back to ready-for-agent by hand (%s)' % (
        number, 'gh edit failed' if repo else 'repo unknown here')


def _start_unknown_agent(w):
    """The row's agent family; a row with none takes it from its launch record (#1967)."""
    agent = worker_agent_id(w).split('/')[0]
    if agent:
        return agent
    pair = _launch_record_pair(w.get('dispatchId'))
    return pair[0] if pair else ''


def start_unknown_agy_host(config, w, rpc_call, now):
    """The host name when the row's screen is agy's sign-in screen and the host is now marked, else None (#1967).

    The mark is keyed by host name, the key placement reads. A failed read or mark returns None, so the
    row waits for a later pass and nothing is booked."""
    env = w.get('_host') or ''
    handle = w.get('_host_terminal') or worker_terminal_handle(w)
    if not handle:
        return None
    try:
        screen = json.dumps(rpc_call('terminal', 'read', '--terminal', handle, '--screen', *_env_args(env)))
    except SEND_ERRORS:
        return None
    agy = _agy_signin()
    if not agy.is_sign_in_screen(screen):
        return None
    host = host_cap_name(env, config, environment_name_by_id()) if env else ((config or {}).get('local_host') or 'local')
    try:
        agy.mark(host, now=now, config=config or {})
    except OSError as error:
        print('fleet-watch: agy-unavailable record failed: %s' % (repr(error),), file=sys.stderr)
        return None
    return host


AGY_PROBE_EVERY = 30 * 60
AGY_PROBE_TITLE = 'agy-signin-probe'  # not '#N|role' or '<job> run N', so the orphan terminal sweep (#1963) leaves it
AGY_PROBE_COMMAND = '"$HOME/dotfiles/bin/agy" models; exit'  # without the exit the shell stays open and wait --for exit never ends
AGY_PROBE_WAIT_MS = 12000  # under the 15 s orca CLI timeout in rpc()


def _probe_worktree(rpc_call, env):
    """An existing worktree on the host, since a remote refuses a terminal without one (start-remote-worker.sh)."""
    listed = rpc_call('worktree', 'list', *env)
    rows = (listed.get('result', listed) if isinstance(listed, dict) else {}).get('worktrees') or []
    rows = [r for r in rows if isinstance(r, dict) and not r.get('isArchived') and r.get('path')]
    rows.sort(key=lambda r: not r.get('isMainWorktree'))
    return 'path:' + rows[0]['path'] if rows else ''


def agy_probe(host, rpc_call=None, local=False):
    """Run `agy models` in an Orca terminal on the host, read it, and always close it, on a timeout too (#1968).

    An Orca terminal runs in the host's own session like a real worker. Over ssh agy cannot reach the
    keychain and says signed out on a signed in host. Returns 'in', 'out' or '' (no answer)."""
    rpc_call = rpc_call or rpc
    env = () if local else ('--environment', host)
    try:
        worktree = _probe_worktree(rpc_call, env)
        if not worktree:
            return ''
        made = rpc_call('terminal', 'create', *env, '--worktree', worktree,
                        '--title', AGY_PROBE_TITLE, '--command', AGY_PROBE_COMMAND)
    except SEND_ERRORS:
        return ''
    made = made.get('result', made) if isinstance(made, dict) else {}
    terminal = (made.get('terminal') or {}).get('handle') if isinstance(made.get('terminal'), dict) else ''
    if not terminal:
        return ''
    try:
        rpc_call('terminal', 'wait', *env, '--terminal', terminal, '--for', 'exit',
                 '--timeout-ms', str(AGY_PROBE_WAIT_MS))
        return _agy_signin().probe_result(json.dumps(rpc_call('terminal', 'read', *env, '--terminal', terminal,
                                                               '--screen')))
    except SEND_ERRORS:
        return ''
    finally:
        try:
            rpc_call('terminal', 'close', *env, '--terminal', terminal)
        except SEND_ERRORS:
            pass


def agy_probe_notices(config, state, now, probe=None):
    """Probe one host_caps host per pass, the one probed longest ago, each at most every 30 minutes (#1968).

    `out` marks the host, so placement skips it for antigravity (#1966). Only `in`, or `out` after the mark
    was written, is cached: no answer, an error or a failed mark leaves the host due next pass."""
    agy = _agy_signin()
    probe = probe or (lambda host: agy_probe(host, local=_is_local_coordinator_host(host, config)))
    cache = state.setdefault('agy_probe', {})
    due_hosts = []
    for host in sorted(h for h in (config.get('host_caps') or {}) if isinstance(h, str) and h):
        last = cache.get(host) if isinstance(cache.get(host), dict) else {}
        at = last.get('at') if isinstance(last.get('at'), (int, float)) else None
        if (at is not None and now - at < AGY_PROBE_EVERY) or not agy.usable('antigravity', host, config, now=now):
            continue
        due_hosts.append((at if at is not None else float('-inf'), host))
    notices = []
    for _at, host in sorted(due_hosts)[:1]:
        result = probe(host)
        if result == 'out':
            try:
                due = agy.mark(host, now=now, config=config)
            except OSError as error:
                print('fleet-watch: agy-unavailable record failed: %s' % (repr(error),), file=sys.stderr)
                continue
            if due:
                notices.append(_agy_signin_line(host))
        if result in ('in', 'out'):
            cache[host] = {'at': now, 'result': result}
    return notices


def start_unknown_reaper(config, state, now, rows, rpc_call, release, act=None):
    """A worker still start_unknown after 10 minutes gets its brief once more; at 20 minutes, with the resend
    done, it is released and its issue put back to ready-for-agent, with one Urgent (#1962). The book is
    state['start_unknown']; a row whose host could not be read is left for a later pass. An antigravity row on
    agy's sign-in screen is released at once instead: its host is marked, its issue put back, and one
    coordinator line per host names script/agy-signin-host.sh (#1967). Returns the notices."""
    book = state.setdefault('start_unknown', {})
    seen, notices, agy_hosts = set(), [], set()
    for w in rows or []:
        if not isinstance(w, dict) or not w.get('dispatchId'):
            continue
        if w.get('_host_read') is False:
            if w['dispatchId'] in book:
                seen.add(w['dispatchId'])
            continue
        if (w.get('_state') or _worker_state(w)) != 'start_unknown':
            continue
        did = w['dispatchId']
        if release_held(state, did):
            continue
        seen.add(did)
        entry = book.setdefault(did, {'at': now})
        if entry.get('reaped'):
            continue
        if _start_unknown_agent(w) in ('antigravity', 'agy'):
            host = start_unknown_agy_host(config, w, rpc_call, now)
            if host is not None:
                closed = release(w)
                if closed not in ('closed', 'kept:no_handle'):
                    log_fleet_watch('start_unknown %s: agy sign-in screen, release %s, retry next pass' % (did, closed))
                    continue
                entry['reaped'] = True
                log_fleet_watch('start_unknown %s: agy sign-in screen on %s: released, terminal %s%s' % (
                    did, host, closed, _start_unknown_relabel(w, act)))
                if host not in agy_hosts:
                    agy_hosts.add(host)
                    notices.append(_agy_signin_line(host))
                continue
        if not entry.get('resent_at'):
            if now - entry['at'] >= START_UNKNOWN_RESEND_SECONDS:
                sent = resend_brief(rpc_call, w)
                if sent:
                    entry['resent_at'] = now
                log_fleet_watch('start_unknown %s: brief resent%s' % (did, '' if sent else ' failed, retry next pass'))
            continue
        if (now - entry['at'] < START_UNKNOWN_REAP_SECONDS
                or now - entry['resent_at'] < START_UNKNOWN_REAP_SECONDS - START_UNKNOWN_RESEND_SECONDS):
            continue
        closed = release(w)
        if closed not in ('closed', 'kept:no_handle'):
            log_fleet_watch('start_unknown %s: release %s, retry next pass' % (did, closed))
            continue
        entry['reaped'] = True
        line = 'start_unknown %s did not start in %d minutes after a resent brief: released, terminal %s%s' % (
            did, (now - entry['at']) // 60, closed, _start_unknown_relabel(w, act))
        log_fleet_watch(line)
        notices.append(Urgent(line))
    for did in list(book):
        if did not in seen:
            book.pop(did)
    return notices


def reaper_owned(state):
    """Dispatches the start_unknown reaper is handling, which the stall ladder leaves alone."""
    return set(state.get('start_unknown') or {})


ACTIVE_WORKER_PAGES = 10


def host_workers(rpc_call, on):
    """One host's worker rows: the newest page of the list plus every page of the active list (#1947).

    The list runs to thousands of rows, so only its newest page is read; every running worker holds an
    active terminal, so the active pages cover the rest. Returns None when the active list runs past
    ACTIVE_WORKER_PAGES pages or a page is not a list. Raises the read error."""
    first = rpc_call('orchestration', 'worker-list', *on) or {}
    rows = first.get('workers') if isinstance(first, dict) else None
    if not isinstance(rows, list):
        return None
    rows = [w for w in rows if isinstance(w, dict)]
    cursor = None
    for _page in range(ACTIVE_WORKER_PAGES):
        args = ['orchestration', 'worker-list', '--terminal-state', 'active', *on]
        if cursor:
            args += ['--cursor', cursor]
        page = rpc_call(*args) or {}
        more = page.get('workers') if isinstance(page, dict) else None
        if not isinstance(more, list):
            return None
        rows += [w for w in more if isinstance(w, dict)]
        cursor = page.get('nextCursor') or None
        if not cursor:
            return rows
    return None


ORPHAN_IDLE_SECONDS = 15 * 60
_WORKER_TITLE_RE = re.compile(r'^#\d+\|[\w-]+')
_RUN_TITLE_RE = re.compile(r'^([\w.-]+) run \d+\b')
_RUN_WORKTREE_RE = re.compile(r'^auto-([\w.-]+)-run-\d+')
RUN_ENDED_STATUSES = frozenset({'completed'})  # automation run records; other statuses are not known to end a run


def run_terminal_job(title, path):
    """The job of an automation run terminal (`<job> run N` title or `auto-<job>-run-<n>` worktree), else ''."""
    m = _RUN_TITLE_RE.match(title) or _RUN_WORKTREE_RE.match(path.split('/')[-1])
    return m.group(1) if m else ''


def run_records_ended(rpc_call, env):
    """Worktree paths of the automation runs that the Orca record on `env` says completed (#2002). A failed read is none."""
    try:
        runs = (rpc_call('automations', 'runs', '--limit', '100', *_env_args(env)) or {}).get('runs')
    except SEND_ERRORS:
        return set()
    out = set()
    for r in runs if isinstance(runs, list) else ():
        ws = str(r.get('workspaceId') or '') if isinstance(r, dict) else ''
        if isinstance(r, dict) and r.get('status') in RUN_ENDED_STATUSES and '::' in ws:
            out.add(ws.split('::', 1)[1].rstrip('/'))
    return out


def run_tail_finished(rpc_call, handle, env, job):
    """True when the terminal's tail holds the wrapper's `ok <job>` or `FAILED <job>` reply line (#2002)."""
    try:
        read = rpc_call('terminal', 'read', '--terminal', handle, '--limit', '200', *_env_args(env))
    except SEND_ERRORS:
        return False
    tail = ((read or {}).get('terminal') or {}).get('tail') or []
    reply = re.compile(r'\s*(?:ok|FAILED) %s(?=[:\s])' % re.escape(job))
    return any(reply.match(str(line)) for line in tail)


def orphan_terminal_sweep(config, now, rpc_call, hosts, rows, dry_run=None):
    """Close a worker (`#N|role`), automation run (`<job> run N`) or `auto-<job>-run-<n>` worktree terminal that no
    live row holds on each fleet host (#1963). It closes when idle 15 minutes or more. A run terminal whose job has
    finished closes without that wait (#2002): its Orca run record is `completed`, or its tail has the job's
    `ok <job>` or `FAILED <job>` reply line. Workers never use the finished test. `hosts` are environment names,
    '' for this host; `rows` are the pass's fleet_rows. A host whose terminal list cannot be read, whose rows carry
    `_host_read: False`, or whose worker list fleet_rows could not read, is skipped. A terminal with no
    lastOutputAt counts as not idle. Closing goes through close_worker_terminal, so close_guard keeps the
    coordinator's and live terminals. With `dry_run`, each terminal it would close is passed to dry_run as one line
    and nothing is closed. Returns the handles closed."""
    names = environment_name_by_id() if any(hosts or ()) else {}
    ended_by_env = {}
    unread, live_handles, live_paths = set(_UNREAD_WORKER_HOSTS), set(), set()
    for row in rows or ():
        if not isinstance(row, dict):
            continue
        host = row.get('_host') or ''
        if row.get('_host_read') is False:
            unread.add(names.get(host) or host)
        if not holds_pass_terminal(row):
            continue
        live_handles.add(row.get('_host_terminal') or worker_terminal_handle(row))
        ws = row.get('_host_workspace') or worker_checkout_path(row)
        live_paths.add(ws.split('::', 1)[1] if '::' in ws else ws)
    live_handles.discard('')
    live_paths.discard('')
    closed = []
    for env in hosts or ():
        if env in unread:
            continue
        try:
            terms = (rpc_call('terminal', 'list', *_env_args(env)) or {}).get('terminals')
        except SEND_ERRORS:
            continue
        if not isinstance(terms, list):
            continue
        for t in terms:
            if not isinstance(t, dict) or not t.get('handle'):
                continue
            handle, title = t['handle'], str(t.get('title') or '')
            path = str(t.get('worktreePath') or '').rstrip('/')
            if not (_WORKER_TITLE_RE.match(title) or _RUN_TITLE_RE.match(title)
                    or _RUN_WORKTREE_RE.match(path.split('/')[-1])):
                continue
            if handle in live_handles or (path and path in live_paths) or close_guard(handle):
                continue
            last = t.get('lastOutputAt')  # ms; 0 or a bool is no known output time
            idle = (not isinstance(last, bool) and isinstance(last, (int, float)) and last > 0
                    and now - last / 1000.0 >= ORPHAN_IDLE_SECONDS)
            job = '' if _WORKER_TITLE_RE.match(title) else run_terminal_job(title, path)
            if not idle and not (job and _run_job_finished(rpc_call, env, handle, path, job, ended_by_env)):
                continue
            if dry_run is not None:
                how = 'idle %dm' % ((now - last / 1000.0) // 60) if idle else 'run finished'
                dry_run('orphan sweep: would close %s (%s) on %s, %s' % (handle, title, env or 'this host', how))
            elif close_worker_terminal(rpc_call, handle, env) == 'closed':
                closed.append(handle)
    return closed


def _run_job_finished(rpc_call, env, handle, path, job, ended_by_env):
    """True when the run record on `env` says this run's worktree completed, or the tail shows its reply line. The
    record is read once per host per pass (#2002)."""
    if env not in ended_by_env:
        ended_by_env[env] = run_records_ended(rpc_call, env)
    return (bool(path) and path.rstrip('/') in ended_by_env[env]) or run_tail_finished(rpc_call, handle, env, job)


def sweep_hosts(config):
    """'' for this host plus every Orca environment name except the coordinator's own."""
    local = (config or {}).get('local_host')
    return [''] + sorted(n for n in set(environment_name_by_id().values()) if n and n != local)


def _set_row_host(row, config, state=None):
    """Tag a coordinator row with `_host`, `_state` and `_repo`, the fields every release reads (#1958)."""
    row['_host'] = remote_environment(row) if worker_is_remote(row, config) else ''
    row['_state'] = _worker_state(row)
    own = (state or {}).get('own_dispatches') or {}
    rec = own.get(row.get('dispatchId')) if isinstance(own, dict) else None
    row['_repo'] = repo_for_worker(row, config) or (rec.get('repo') if isinstance(rec, dict) else '') or ''
    row.setdefault('_host_read', True)
    return row


def fleet_rows(config, coordinator_rows, hosts, rpc_call, state=None):
    """The pass's worker rows, one per dispatchId (#1958). The coordinator row is the base; for a remote
    dispatch the host's own row adds `_state` and the terminal handle (`_host_terminal`). The host fields stay
    in underscore keys, so the passes that read `terminal` or `projection` see the row as before.
    A host that cannot be read sets `_host_read: False` on its rows and is kept in _UNREAD_WORKER_HOSTS, even with
    no coordinator row on it. Host rows the coordinator lacks are dropped."""
    names = environment_name_by_id() if any(hosts or ()) else {}
    on_host, unread = {}, set()
    _UNREAD_WORKER_HOSTS.clear()
    for env in hosts or ():
        if not env:
            continue
        try:
            listed = host_workers(rpc_call, _env_args(env))
        except SEND_ERRORS:
            listed = None
        if listed is None:
            unread.add(env)
            _UNREAD_WORKER_HOSTS.add(env)
            continue
        for w in listed:
            if w.get('dispatchId'):
                on_host.setdefault(w['dispatchId'], w)
    rows, index = [], {}
    for raw in coordinator_rows or []:
        if not isinstance(raw, dict):
            continue
        did = raw.get('dispatchId')
        row = dict(raw)
        if did in index:
            rows[index[did]].update({k: v for k, v in row.items() if v is not None})
            continue
        _set_row_host(row, config, state)
        host = row['_host']
        if host:
            mine = on_host.get(did)
            if mine is not None:
                row['_state'] = _worker_state(mine) or row['_state']
                handle = worker_terminal_handle(mine)
                if handle:
                    row['_host_terminal'] = handle
                workspace = worker_worktree_selector(mine)
                if workspace:
                    row['_host_workspace'] = workspace
            row['_host_read'] = (names.get(host) or host) not in unread
        if did:
            index[did] = len(rows)
        rows.append(row)
    return rows


def release_worker_by_fragment(fragment, config, rpc_call, hosts, allow_live=False):
    """release-worker.sh: release the one dispatch, or close the one terminal, whose id contains `fragment` (#1947).

    Every host's worker list and terminal list is read. More than one match, or none, closes nothing. The
    coordinator's terminal, the caller's and a terminal another live dispatch uses are never closed; a live
    target needs allow_live. A dispatch goes through release_worker (#1958). Returns (exit code, message)."""
    fragment = (fragment or '').strip()
    if len(fragment) < 4:
        return 2, 'give at least 4 characters of a dispatch, task or terminal id'
    rows, terminals = [], []
    for env in hosts:
        on = _env_args(env)
        try:
            listed = host_workers(rpc_call, on)
            if listed is None:
                return 1, 'cannot read the worker list on %s; nothing closed' % (env or 'this host')
            rows += [_set_row_host(dict(w), config) if not env else dict(w, _host=env) for w in listed]
            for t in (rpc_call('terminal', 'list', *on) or {}).get('terminals') or []:
                if isinstance(t, dict) and t.get('handle'):
                    terminals.append((env, t))
        except SEND_ERRORS as error:
            return 1, 'cannot read %s: %r; nothing closed' % (env or 'this host', error)
    protect_pass_terminals(config, rows)
    try:
        for run in (rpc_call('orchestration', 'run-list', '--full') or {}).get('runs') or []:
            if isinstance(run, dict) and isinstance(run.get('coordinator_handle'), str):
                _PROTECTED_HANDLES.add(run['coordinator_handle'].strip())
    except SEND_ERRORS:
        return 1, 'cannot read the run list to find the coordinator; nothing closed'
    # A remote worker shows here without a terminal and on its host with one: the host's row comes first.
    rows.sort(key=lambda w: not w.get('_host'))
    found = {}
    for w in rows:
        did = w.get('dispatchId') or ''
        if did and did not in found and any(fragment in i for i in (did, w.get('taskId') or '', worker_terminal_handle(w)) if i):
            found[did] = w
    matched_handles = {worker_terminal_handle(w) for w in found.values()}
    bare = [(env, t) for env, t in terminals if fragment in t['handle'] and t['handle'] not in matched_handles]
    if len(found) + len(bare) != 1:
        names = sorted(found) + [t['handle'] for _e, t in bare]
        return 1, ('no worker or terminal matches %s' % fragment if not names
                   else '%s matches %d: %s; give more of the id' % (fragment, len(names), ' '.join(names)))
    if bare:
        env, t = bare[0]
        handle, did, row = t['handle'], '', None
    else:
        did = next(iter(found))
        row = row_for_dispatch(rows, did)
        env = row.get('_host') or ''
        handle = resolve_worker_terminal(rpc_call, did, env, worker_terminal_handle(row))
        row['_host_terminal'] = handle
    why = close_guard(handle, did)
    if why and why != 'no_handle':
        return 1, 'refused: %s is %s; nothing closed' % (handle, why)
    if row is not None and worker_row_is_live(row) and not allow_live:
        return 1, 'refused: %s is still live; pass --live to stop it; nothing closed' % did
    if row is not None and handle not in {t['handle'] for e, t in terminals if e == env}:
        # The terminal is already gone from the host's list: release without closing it (#1999). The flag stops
        # release_worker from asking worker-show again, which can still name the gone handle.
        row.update(_host_terminal='', _terminal_gone=True)
        handle = ''
    result = release_worker(rpc_call, row) if row is not None else close_worker_terminal(rpc_call, handle, env)
    if result == 'kept:no_handle' and row is not None:
        return 0, '%s released; terminal already gone on %s' % (did, env or 'this host')
    if result != 'closed':
        return 1, '%s released, terminal %s' % (did or handle, result)
    try:
        still = any(t.get('handle') == handle
                    for t in (rpc_call('terminal', 'list', *_env_args(env)) or {}).get('terminals') or [])
    except SEND_ERRORS:
        return 1, '%s closed on %s, but the terminal list could not be read to confirm' % (handle, env or 'this host')
    if still:
        return 1, '%s still listed on %s after close' % (handle, env or 'this host')
    return 0, '%s released; terminal %s closed on %s and gone from its terminal list' % (
        did or '(no dispatch)', handle, env or 'this host')


def stop_and_release_stalled(rpc_call, worker, dispatch_id, environment=''):
    """The one place the stall ladder stops and releases a worker and archives its card (#1842).

    Returns '' on success, else the stop failure code; nothing is released when the stop fails.
    The release goes through release_worker on the row's host (#1958); a row with no `_host` takes `environment`.
    """
    worker.setdefault('dispatchId', dispatch_id)
    worker.setdefault('_host', environment or '')
    result = release_worker(rpc_call, worker)
    if result.startswith('stop_failed:'):
        return result[len('stop_failed:'):]
    set_board_status(rpc_call, worker, 'archived', worker['_host'])
    return ''


def worktree_head(worker):
    """HEAD sha of a worker checkout on this machine, or '' when it cannot be read."""
    path = safe_workspace_path(worker_checkout_path(worker))
    if not path or not os.path.isdir(path):
        return ''
    try:
        proc = subprocess.run(['git', '-C', path, 'rev-parse', 'HEAD'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ''
    return proc.stdout.strip() if proc.returncode == 0 else ''


def stall_holds_work(worker):
    """False only for a checkout on this machine with no unpushed commits and no changed files.
    A remote or unreadable checkout counts as holding work, so it is never stopped."""
    if _unpushed_resource(worker):
        return True
    path = safe_workspace_path(worker_checkout_path(worker))
    if not path or not os.path.isdir(path):
        return True
    return worktree_has_unpushed_commits(path) or worktree_disposition(path) != 'clean'


def worker_stall_pass(config, state, now, workers, term_times, rpc_call, act=None, terminal_list_ok=True,
                     terminal_branches=None, inventory_ok=True, head_of=None, holds_work=None, pr_list=None,
                     waiting=(), reaper=()):
    """Restart our own silent workers once; report every other stalled worker once and do not stop it.

    `waiting` keeps a worker off the nudge ladder; `reaper` (the start_unknown reaper's dispatches) is left alone.

    A failed restart is parked with the recorded message. A usage-gate or host-cap refusal is retried.
    """
    cfg = config.get('worker_stall') or {}
    fixed_repo = cfg.get('label_repo')
    if not isinstance(fixed_repo, str) or not fixed_repo.strip():
        fixed_repo = ''
    else:
        fixed_repo = fixed_repo.strip()
    from_system = bool(cfg.get('from_system'))
    if not fixed_repo and not from_system:
        return [], []

    def label_target(worker):
        if fixed_repo:
            return fixed_repo
        return repo_for_worker(worker, config) or ''

    def fault_target():
        # A configured label_repo is the old single-repo behavior. System passes
        # open faults in the private fleet repo; the PR label uses the worker's repo.
        if fixed_repo and not from_system:
            return fixed_repo
        return FAULT_REPO

    stall_limit = stall_idle_limit_seconds(config)
    try:
        record_ttl = int(cfg.get('stall_restart_record_ttl_seconds', STALL_RESTART_RECORD_TTL_DEFAULT))
    except (TypeError, ValueError):
        record_ttl = STALL_RESTART_RECORD_TTL_DEFAULT
    notices = []
    log_bits = []
    if not inventory_ok:
        log_bits.append('orca_inventory_failed_stall_skipped')
        return notices, log_bits
    if not terminal_list_ok:
        log_bits.append('terminal_list_failed')
        return notices, log_bits

    bucket = state.setdefault('worker_stall', {})
    pending = state.setdefault('stall_pending_start', {})
    # Legacy one-restart records expire by age. New restarts live on own_dispatches.
    for skey in list(bucket.keys()):
        st_entry = bucket.get(skey)
        if not isinstance(st_entry, dict):
            continue
        ra = st_entry.get('restart_at')
        try:
            ra_f = float(ra) if ra is not None else None
        except (TypeError, ValueError):
            ra_f = None
        if ra_f is not None and now - ra_f >= record_ttl:
            bucket.pop(skey, None)
            pending.pop(skey, None)

    if not workers and not pending:
        log_bits.append('stall_skipped_empty_workers')
        return notices, log_bits

    for skey, pend in list(pending.items()):
        if not isinstance(pend, dict) or pend.get('started') or pend.get('gave_up'):
            continue
        row_snapshot = pend.get('row_snapshot')
        old_dispatch = pend.get('old_dispatch')
        if not row_snapshot or not old_dispatch:
            pending.pop(skey, None)
            continue
        if park_is_active(state, park_id('stall', old_dispatch), config):
            pending.pop(skey, None)
            continue
        pr_num = pend.get('pr') if isinstance(pend.get('pr'), int) else None
        repo = pend.get('repo') or ''
        if int(pend.get('failures') or 0) >= STALL_RESTART_ATTEMPTS:
            _park_own_stall(
                state, old_dispatch, now, pend.get('reason') or '', notices, log_bits, config,
                repo=repo, pr=pr_num,
            )
            pending.pop(skey, None)
            continue
        run_for_start = run_id_for_stall_restart(
            row_snapshot, pend.get('stall_restart_run_id') or '') or default_list_run_id(config)
        start_args = worker_stall_restart_start_args(row_snapshot, old_dispatch, run_for_start, config)
        if not start_args:
            line = stall_restart_start_blocked_log(old_dispatch, config, row_snapshot, run_for_start)
            if line:
                log_bits.append(line)
            continue
        try:
            result = rpc_call(*start_args)
        except SEND_ERRORS as exc:
            reason, exit_code = exception_start_failure(exc)
            if exit_code in BABYSIT_DEFERRED_EXITS:
                log_bits.append('stall_restart_deferred=%s:%s' % (old_dispatch, reason or exit_code))
                continue
            _park_own_stall(
                state, old_dispatch, now, _stall_notice_reason(reason, orchestration_failure_log_code(exc)),
                notices, log_bits, config, repo=repo, pr=pr_num,
            )
            pending.pop(skey, None)
            continue
        _record_stall_restart(state, old_dispatch, result, now, log_bits, pending)

    def grok_verifier_row(did):
        row = _own_row(state, did) or {}
        return row.get('kind') == 'verifier' and row.get('agent') == 'grok'

    def restart_own(w, did):
        if grok_verifier_row(did):
            # A stalled Grok verifier is not restarted on Grok: release it, and babysit starts the next family.
            outcome = release_worker(rpc_call, w)
            log_bits.append('grok_stall_release=%s:%s' % (did, outcome))
            return
        row = _own_row(state, did)
        key = park_id('stall', did)
        if row is not None and row.get('parked'):
            if park_is_active(state, key, config):
                return
            for name in ('parked', 'parked_at', 'park_reason', 'restarted', 'restart_at'):
                row.pop(name, None)
        elif park_is_active(state, key, config):
            return
        if _dispatch_is_pending(pending, did):
            return
        if row is not None and (row.get('retry_of') or row.get('restarted')):
            if row.get('restarted') and not row.get('retry_of') and _retry_recorded(state, did):
                return
            try:
                restarted_at = float(row.get('restart_at'))
            except (TypeError, ValueError):
                restarted_at = None
            if restarted_at is not None and now - restarted_at >= stall_limit:
                _park_own_stall(
                    state, did, now, 'still silent after restart', notices, log_bits, config,
                    repo=label_target(w) or fault_target(),
                    pr=worker_pr_number(w), fail_log=False,
                )
            return
        run_for_start = run_id_for_stall_restart(w, '') or default_list_run_id(config)
        start_args = worker_stall_restart_start_args(w, did, run_for_start, config)
        repo = label_target(w) or fault_target()
        pr_num = worker_pr_number(w)
        if not start_args:
            line = stall_restart_start_blocked_log(did, config, w, run_for_start)
            if line:
                log_bits.append(line)
            if not str(line).startswith('stall_no_sender_terminal='):
                _park_own_stall(
                    state, did, now, 'restart failed (no start args)', notices, log_bits, config,
                    repo=repo, pr=pr_num,
                )
            return
        try:
            # A restart, not a retire: stop only, on the row's host, then start again (#1958).
            rpc_call('orchestration', 'worker-stop', '--dispatch', did, *_env_args(w.get('_host') or ''))
            _remember_stall_stop(state, w, did, repo)
        except SEND_ERRORS as exc:
            reason, exit_code = exception_start_failure(exc)
            if exit_code in BABYSIT_DEFERRED_EXITS:
                log_bits.append('stall_restart_deferred=%s:%s' % (did, reason or exit_code))
                return
            _park_own_stall(
                state, did, now, _stall_notice_reason(reason, orchestration_failure_log_code(exc)),
                notices, log_bits, config, repo=repo, pr=pr_num,
            )
            return
        try:
            try:
                result = rpc_call(*start_args)
            except SEND_ERRORS as first:
                first_reason, first_code = exception_start_failure(first)
                if (first_code in BABYSIT_DEFERRED_EXITS or not startup_failure_text(first_reason)
                        or not startup_retry_taken(state, key)):
                    raise
                log_bits.append('startup_retry=%s' % did)
                result = rpc_call(*start_args)
        except SEND_ERRORS as exc:
            reason, exit_code = exception_start_failure(exc)
            if exit_code in BABYSIT_DEFERRED_EXITS:
                _defer_stall_restart(pending, w, did, run_for_start, reason, repo, pr_num)
                log_bits.append('stall_restart_deferred=%s:%s' % (did, reason or exit_code))
                return
            _park_own_stall(
                state, did, now, _stall_notice_reason(reason, orchestration_failure_log_code(exc)),
                notices, log_bits, config, repo=repo, pr=pr_num,
            )
            return
        _record_stall_restart(state, did, result, now, log_bits, pending)

    def retry_startup_failed(w, did):
        """An own worker that died at startup is released and started once more, then parked (#1221).
        Needs a startup stage or error on the row (worker-list rows carry no lastError); without one nothing fires."""
        row = _own_row(state, did)
        if row is None or row.get('startup_handled') or _retry_recorded(state, did) or grok_verifier_row(did):
            return  # babysit replaces a dead Grok verifier with the next family (ADR 0003)
        row['startup_handled'] = True
        repo = label_target(w) or fault_target()
        pr_num = worker_pr_number(w)
        if row.get('retry_of'):
            _park_own_stall(state, did, now, 'failed at startup after a retry', notices, log_bits, config,
                            repo=repo, pr=pr_num)
            return
        run_for_start = run_id_for_stall_restart(w, '') or default_list_run_id(config)
        start_args = worker_stall_restart_start_args(w, did, run_for_start, config)
        if not start_args:
            _park_own_stall(state, did, now, 'startup retry failed (no start args)', notices, log_bits, config,
                            repo=repo, pr=pr_num)
            return
        try:
            # A restart, not a retire: release only, on the row's host, then start again (#1958).
            rpc_call('orchestration', 'worker-release', '--dispatch', did, *_env_args(w.get('_host') or ''))
        except SEND_ERRORS:
            pass
        try:
            result = rpc_call(*start_args)
        except SEND_ERRORS as exc:
            reason, _exit_code = exception_start_failure(exc)
            _park_own_stall(state, did, now, _stall_notice_reason(reason, orchestration_failure_log_code(exc)),
                            notices, log_bits, config, repo=repo, pr=pr_num)
            return
        _record_stall_restart(state, did, result, now, log_bits, pending)
        log_bits.append('startup_retry=%s' % did)

    head_of = head_of or worktree_head
    holds_work = holds_work or stall_holds_work
    ladder = state.setdefault('stall_ladder', {})
    laddered = set()

    def release_issue(w, repo):
        """Put the issue back in the queue. Only an issue builder with no open PR has one to give back."""
        number = _worker_issue_number(w)
        if not number or not repo or worker_pr_number(w):
            return None
        if pr_list is not None:
            rows = pr_list(repo)
            if rows is None:
                log_bits.append('stall_issue_skipped=%d:pr_list' % number)
                return None
            if open_pr_for_issue(rows, number):
                return None
        edit = act or run_gh
        if edit(['gh', 'issue', 'edit', str(number), '--repo', repo,
                 '--add-label', 'ready-for-agent', '--remove-label', ISSUE_CLAIM_LABEL]) != 0:
            log_bits.append('stall_issue_label_failed=%d' % number)
            return None
        return number

    def climb_ladder(w, did, last_s, is_stalled):
        """Nudge once after 2 stall windows with no new commit; stop and release after 3 (owner Q6, #1842).

        Terminal output after the nudge does not reset the count, since the nudge itself makes output.
        Only a new commit does. A worker that holds unpushed commits or changed files is never stopped.
        """
        laddered.add(did)
        if did in waiting or worker_settled_kind(w) or worker_terminal_released(w):
            ladder.pop(did, None)
            return
        # A remote checkout is not on this disk; a local path with the same name proves nothing.
        remote = worker_execution_host_id(w) != 'local'
        head = '' if remote else head_of(w) or ''
        rec = ladder.get(did)
        if isinstance(rec, dict) and head and rec.get('head') and head != rec['head']:
            ladder.pop(did, None)
            rec = None
        if not isinstance(rec, dict):
            if not is_stalled or last_s is None:
                return
            # The first pass only records the stall, so a lost state file never nudges on sight.
            ladder[did] = {'since': last_s, 'head': head}
            return
        if not rec.get('nudged_at') and not is_stalled:
            ladder.pop(did, None)
            return
        if head and not rec.get('head'):
            rec['head'] = head
        if rec.get('done') or stall_limit <= 0:
            return
        windows = (now - float(rec['since'])) / stall_limit
        environment = remote_environment(w) if worker_is_remote(w, config) else ''
        if not rec.get('nudged_at'):
            if windows < STALL_NUDGE_WINDOWS:
                return
            # Only a nudge that reached the worker starts the last window, so no worker is stopped unwarned.
            term = worker_terminal_handle(w)
            if not term:
                return
            text = STALL_NUDGE_TEXT % (int(now - float(rec['since'])) // 60, stall_limit // 60)
            try:
                rpc_call('terminal', 'send', '--terminal', term, '--text', text, '--enter',
                         *(('--environment', environment) if environment else ()))
            except SEND_ERRORS as error:
                log_send_failed(term, error)
                return
            rec['nudged_at'] = now
            log_bits.append('stall_nudge=%s' % did)
            return
        if windows < STALL_RELEASE_WINDOWS or now - float(rec['nudged_at']) < stall_limit:
            return
        rec['done'] = True
        if remote or holds_work(w):
            log_bits.append('stall_hold=%s' % did)
            notices.append(Urgent(
                'stalled worker %s: no new commit for %d windows after a nudge, but it holds unpushed commits '
                'or changed files (or its checkout is on another host), so fleet-watch did not stop it'
                % (did, STALL_RELEASE_WINDOWS)))
            return
        failed = stop_and_release_stalled(rpc_call, w, did, environment)
        if failed:
            log_bits.append('stall_stop_failed=%s:%s' % (did, failed))
            rec.pop('done', None)
            return
        number = release_issue(w, label_target(w))
        log_bits.append('stall_release=%s' % did)
        notices.append(Urgent(
            'stalled worker %s stopped and released: no new commit for %d windows after a nudge%s'
            % (did, STALL_RELEASE_WINDOWS, '; issue #%d is back in ready-for-agent' % number if number else '')))

    local_handles = set(term_times.keys())
    for w in workers:
        did = w.get('dispatchId')
        if not isinstance(did, str) or not did:
            continue
        if not worker_row_is_live(w):
            if worker_startup_failed(w):
                retry_startup_failed(w, did)
            continue
        # A held dispatch is never nudged, stopped or restarted; the hold notice reports it instead (#1849).
        # Nor is one the start_unknown reaper owns: it resends and releases it (#1962).
        if release_held(state, did) or did in reaper:
            continue
        term = worker_terminal_handle(w)
        host_id = worker_execution_host_id(w)
        if not term:
            if host_id == 'local':
                continue
            last_s = _server_as_of_epoch_seconds(w)
        else:
            last_s = _normalize_terminal_time_ms(term_times.get(term))
        is_stalled = worker_should_restart_for_terminal_stall(w, now, last_s, stall_limit)
        own = _own_row(state, did)
        # Verifier and rework workers are restarted on the same worktree; issue builders and
        # foreign workers climb the nudge, stop and release ladder.
        use_ladder = own is None or own.get('kind') == 'issue'
        if host_id != 'local':
            # The terminal clock is not visible for a remote worker, so its transcript decides on every
            # pass, and the ladder counts from its last tool activity.
            on_ladder = use_ladder and did in ladder
            if not is_stalled and not on_ladder:
                continue
            activity, newest = remote_last_activity(rpc_call, did, remote_environment(w), now, stall_limit)
            log_bits.append('remote_stall_check=%s:%s' % (did, activity))
            if activity == 'unknown' and on_ladder:
                laddered.add(did)
            if activity != 'silent':
                continue
            is_stalled = True
            if newest is not None:
                last_s = newest
        elif term not in local_handles:
            continue
        if not use_ladder:
            if is_stalled:
                restart_own(w, did)
            continue
        if is_stalled and own is None:
            _report_foreign_stall(state, did, notices, log_bits)
        climb_ladder(w, did, last_s, is_stalled)

    for did in list(ladder):
        if did not in laddered:
            ladder.pop(did, None)
    return notices, log_bits


SIGNAL_LIMIT_DEFAULT = 15 * 60


def signal_limit_seconds(config):
    """Seconds a CI run may be in progress, or a worker may sit with no push and no output, before it is flagged."""
    cfg = (config or {}).get('worker_signals') or {}
    try:
        return max(60, int(cfg.get('limit_seconds', SIGNAL_LIMIT_DEFAULT)))
    except (TypeError, ValueError):
        return SIGNAL_LIMIT_DEFAULT


def fetch_branch_runs(repo, branch):
    """Newest runs on one branch (any status), or None when gh fails."""
    command = ['gh', 'run', 'list', '--repo', repo, '--branch', branch, '--limit', '10',
               '--json', 'databaseId,workflowName,status,createdAt,startedAt,headSha']
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def _iso_epoch(token):
    try:
        return calendar.timegm(time.strptime(token, '%Y-%m-%dT%H:%M:%SZ'))
    except (TypeError, ValueError):
        return None


def worker_signal_pass(config, state, now, workers, term_times, terminal_branches=None, runs_fn=None,
                       repo_of=None, inventory_ok=True, terminal_list_ok=True):
    """One escalation per worker and signal (#1741). The signal fires again only after it has cleared.

    ci: a run on the worker's branch has been in progress longer than the limit (check it, it may be slow or hung).
    idle: no new push (newest run head) and no new terminal output for the limit.
    """
    notices, log_bits = [], []
    if not inventory_ok or not terminal_list_ok:
        return notices, log_bits
    limit = signal_limit_seconds(config)
    runs_fn = runs_fn or fetch_branch_runs
    bucket = state.setdefault('worker_signals', {})
    live = set()
    for w in workers:
        did = w.get('dispatchId')
        if not isinstance(did, str) or not did or not worker_row_is_live(w):
            continue
        term = worker_terminal_handle(w)
        last_out = _normalize_terminal_time_ms(term_times.get(term)) if term else None
        branch = worker_branch_name(w) or (terminal_branches or {}).get(term) or ''
        repo = repo_of(w) if repo_of else repo_for_worker(w, config)
        if not (last_out is not None or (branch and repo)):
            continue
        live.add(did)
        rec = bucket.setdefault(did, {'fired': {}})
        fired = rec.setdefault('fired', {})
        runs = runs_fn(repo, branch) if (branch and repo) else None
        if runs is not None:
            head = (runs[0].get('headSha') or '') if runs else ''
            if head != rec.get('head', ''):
                if 'head' in rec:
                    rec['head_at'] = now  # a changed head is a push; the first read is only a baseline
                rec['head'] = head
            rec.setdefault('head', head)
        rec.setdefault('head_at', now)
        label = 'worker %s' % did
        pr = worker_pr_number(w)
        if pr:
            label += ' (PR #%d)' % pr
        slow = None
        for run in runs or ():
            if run.get('status') != 'in_progress':
                continue
            began = _iso_epoch(run.get('startedAt') or run.get('createdAt'))
            if began is not None and now - began > limit and (slow is None or began < slow[0]):
                slow = (began, run)
        if slow:
            if not fired.get('ci'):
                fired['ci'] = True
                age = int((now - slow[0]) // 60)
                notices.append(Urgent(
                    '%s: signal ci. Run %s (%s) has been in_progress for %d min, more than %d min. '
                    'Check it: read the job step log. Steps still advancing means slow, wait up to 45 min. '
                    'No step for 15 min or past 45 min means a hang. '
                    'A PR check job over 20 min is cancelled and rerun by fleet-watch.'
                    % (label, slow[1].get('databaseId'), slow[1].get('workflowName') or 'checks', age, limit // 60)))
                log_bits.append('signal_ci=%s' % did)
        elif runs is not None:
            fired.pop('ci', None)  # a failed gh read leaves the flag alone
        newest = max(last_out, rec['head_at']) if last_out is not None else None
        if newest is None:
            pass  # output time unknown: never claim silence
        elif now - newest > limit:
            if not fired.get('idle'):
                fired['idle'] = True
                notices.append(Urgent(
                    '%s: signal idle. No new push and no new terminal output for %d min, more than %d min.'
                    % (label, int((now - newest) // 60), limit // 60)))
                log_bits.append('signal_idle=%s' % did)
        else:
            fired.pop('idle', None)
    for did in list(bucket):
        if did not in live:
            bucket.pop(did, None)
    return notices, log_bits


WORKER_SOFT_MINUTES = 60
WORKER_HARD_MINUTES = 90
EXEMPT_WORKER_ROLES = ('elon', 'coordinator', 'support-csm', 'release-manager')
CI_JOB_LIMIT_SECONDS = 30 * 60  # with fewer than CI_JOB_MIN_SAMPLES recent successful runs of the check
CI_JOB_MIN_SAMPLES = 10
CI_JOB_RECENT_SAMPLES = 30


def worker_durations():
    return _sibling('worker_durations', 'worker-durations.py')


def worker_size(repo, number, labels_of=None):
    """S or L from the issue's size label, else M. '' when there is no issue or its labels cannot be read."""
    if not repo or not number:
        return ''
    names = (labels_of or issue_label_names)(repo, number)
    if not names:
        return ''
    return next((size for size in ('S', 'L') if 'size:' + size in names), 'M')


def worker_limit_minutes(config, role, size):
    """(soft, hard) for one job type: worker_limits.types['role/size'], else worker_limits, else 60 and 90."""
    cfg = (config or {}).get('worker_limits') or {}
    row = (cfg.get('types') or {}).get('%s/%s' % (role, size or 'M')) or {}
    return tuple(
        row.get(key) or cfg.get(key) or default
        for key, default in (('soft_minutes', WORKER_SOFT_MINUTES), ('hard_minutes', WORKER_HARD_MINUTES)))


def worker_duration_pass(config, state, now, workers, messages, repo_of=None, labels_of=None, log_path=None):
    """Log each worker's start and end, and flag a live one past its soft or hard limit once each (#1978)."""
    durations = worker_durations()
    logged = durations.read(log_path)
    done = {
        _message_payload(m).get('dispatchId')
        for m in messages or () if isinstance(m, dict) and m.get('type') == 'worker_done'
    }
    flagged = state.setdefault('worker_limits', {})
    notices, log_bits, live = [], [], set()
    for w in workers:
        did = w.get('dispatchId')
        if not isinstance(did, str) or not did:
            continue
        row = logged.get(did) or {}
        running = worker_row_is_live(w) and did not in done
        if 'ended' in row or (not running and 'started' not in row):
            continue
        title = str(w.get('_task_title') or w.get('title') or row.get('title') or '').strip()
        role = _builder_role(dict(w, _task_title=title)) or 'unknown'
        size = row.get('size')
        if not size:
            match = _NEW_TITLE_RE.match(title)
            repo = repo_of(w) if repo_of else repo_for_worker(w, config)
            size = worker_size(repo, int(match.group(1)) if match else None, labels_of)
        facts = {'dispatch': did, 'role': role, 'size': size, 'title': title,
                 'agent': row.get('agent') or worker_agent_id(w)}
        if not running:
            if did in done:
                outcome = 'done'
            else:
                outcome = 'failed' if worker_inventory_status(w) == 'failed' else 'released'
            durations.append(dict(facts, event='end', at=now, outcome=outcome), log_path)
            continue
        live.add(did)
        if 'started' not in row or (size and not row.get('size')):
            durations.append(dict(facts, event='start', at=row.get('started', now)), log_path)
        if role in EXEMPT_WORKER_ROLES or 'regression' in title.lower():
            continue
        soft, hard = worker_limit_minutes(config, role, size)
        age = (now - row.get('started', now)) / 60
        level = 'hard' if age >= hard else 'soft' if age >= soft else ''
        if not level or level in flagged.get(did, ()):
            continue
        flagged.setdefault(did, []).append(level)
        label = 'worker %s (%s)' % (did, title or role)
        if level == 'hard':
            text = ('%s: past the hard limit, %d of %d min. Tell it to push and report what is left, then release it. '
                    'File the rest as a new issue.' % (label, age, hard))
        else:
            text = '%s: past the soft limit, %d of %d min. Hard limit at %d min.' % (label, age, soft, hard)
        notices.append(Urgent(text))
        log_bits.append('limit_%s=%s' % (level, did))
    for did in list(flagged):
        if did not in live:
            flagged.pop(did)
    return notices, log_bits


def ci_job_limit_seconds(prs, check_name):
    """1.5x the p90 duration of the check's recent successful runs when there are 10 or more, else 30 minutes.

    A fixed 20 minutes cancelled healthy full script-tests runs of 19 to 21 minutes (#1978)."""
    runs = []
    for pr in prs or ():
        for c in (pr.get('statusCheckRollup') or []) if isinstance(pr, dict) else ():
            if not isinstance(c, dict) or c.get('name') != check_name or c.get('status') != 'COMPLETED' \
                    or c.get('conclusion') != 'SUCCESS':
                continue
            start, end = _iso_epoch(c.get('startedAt')), _iso_epoch(c.get('completedAt'))
            if start is not None and end is not None and end > start:
                runs.append((end, end - start))
    durations = sorted(d for _end, d in sorted(runs)[-CI_JOB_RECENT_SAMPLES:])
    if len(durations) < CI_JOB_MIN_SAMPLES:
        return CI_JOB_LIMIT_SECONDS
    return 1.5 * durations[max(0, -(-9 * len(durations) // 10) - 1)]


def ci_hang_pass(config, state, now, fetch=None, act=None):
    """A PR check job running past its limit (ci_job_limit_seconds): cancel its run, rerun it once, flag a second
    hang (#1978)."""
    fetch = fetch or fetch_prs
    act = act or run_gh
    notices, log_bits = [], []
    seen = state.setdefault('ci_hangs', {})
    for repo in babysit_repos(config):
        prs = fetch(repo)
        if not isinstance(prs, list):
            continue
        runs, limits = {}, {}

        def limit(name):
            if name not in limits:
                limits[name] = ci_job_limit_seconds(prs, name)
            return limits[name]
        for pr in prs:
            if pr.get('state') != 'OPEN':
                continue
            for check in pr.get('statusCheckRollup') or []:
                run_id = _workflow_run_id_from_check(check)
                if run_id:
                    runs.setdefault(run_id, (pr.get('number'), []))[1].append(check)
        old = seen.get(repo) or {}
        kept = {}
        for run_id, (number, checks) in runs.items():
            step = old.get(run_id)
            hung = [
                c for c in checks
                if c.get('status') == 'IN_PROGRESS' and _iso_epoch(c.get('startedAt')) is not None
                and now - _iso_epoch(c.get('startedAt')) > limit(c.get('name'))
            ]
            where = '%s #%s run %s' % (repo, number, run_id)
            if step is None and hung:
                if act(['gh', 'run', 'cancel', run_id, '--repo', repo]) == 0:
                    step = 'cancelled'
                    log_bits.append('ci_cancel=%s' % run_id)
            elif step == 'cancelled' and all(c.get('status') == 'COMPLETED' for c in checks):
                # gh refuses a rerun until the cancel has finished, so this waits for a later pass.
                if act(['gh', 'run', 'rerun', run_id, '--repo', repo]) == 0:
                    step = 'rerun'
                    log_bits.append('ci_rerun=%s' % run_id)
            elif step == 'rerun' and hung:
                step = 'flagged'
                notices.append(Urgent(
                    '%s: check %s hung again, over %d min after one cancel and rerun. Read the job step log.'
                    % (where, hung[0].get('name') or 'job', limit(hung[0].get('name')) // 60)))
                log_bits.append('ci_hung=%s' % run_id)
            if step:
                kept[run_id] = step
        seen[repo] = kept
    return notices, log_bits


_ISSUE_ACCEPTANCE_RE = re.compile(
    r'^(?:## (?:[0-9]+[.)] +)?(?:Acceptance(?: criteria)?|Done check)\b|\*\*Acceptance(?: criteria)?:\*\*)',
    re.I | re.M)


def issue_scan_has_acceptance(text):
    return bool(_ISSUE_ACCEPTANCE_RE.search(text or ''))


def issue_scan_brief_text(issue):
    """The newest comment with acceptance criteria (the triage Agent Brief), else the body.
    A `Setup: none` line in the issue body is kept when the chosen comment lacks it."""
    body = issue.get('body') or ''
    comments = [entry.get('body') or '' for entry in (issue.get('comments') or []) if isinstance(entry, dict)]
    for text in reversed(comments):
        if issue_scan_has_acceptance(text):
            if re.search(r'^Setup: none', body, re.M) and not re.search(r'^Setup: none', text, re.M):
                return text.rstrip() + '\n\nSetup: none'
            return text
    return body


def issue_scan_blocked(issue):
    blocked = issue.get('blockedBy')
    if isinstance(blocked, dict):
        for node in blocked.get('nodes') or []:
            if not isinstance(node, dict):
                continue
            state = (node.get('state') or '').upper()
            if state in ('', 'OPEN'):
                return True
    return False


# `Blocked by #n` or `Blocked by owner/repo#n` on its own line (bullets allowed), or under a `## Blocked by` heading (#1788).
# `Blocked by red gate #n` is the red-gate hold, handled elsewhere.
_BLOCKED_BY_LINE_RE = re.compile(r'^\s*(?:[-*]\s+)?blocked by\b:?(?!\s+red gate\b)(.*)$', re.I)
_BLOCKED_BY_HEADING_RE = re.compile(r'^#{1,6}\s*blocked by\b:?(.*)$', re.I)
_ANY_HEADING_RE = re.compile(r'^#{1,6}\s')
_ISSUE_REF_RE = re.compile(r'(?:([\w.-]+/[\w.-]+))?#(\d+)\b')


def issue_blocker_refs(issue, repo):
    """(repo, number) for each issue the body says this one is blocked by, in body order, without repeats."""
    refs = []
    in_section = False
    for line in (issue.get('body') or '').splitlines():
        if _ANY_HEADING_RE.match(line.strip()):
            heading = _BLOCKED_BY_HEADING_RE.match(line.strip())
            in_section = heading is not None
            if not heading:
                continue
            text = heading.group(1)
        else:
            line_match = _BLOCKED_BY_LINE_RE.match(line)
            if line_match:
                text = line_match.group(1)
            elif in_section:
                text = line
            else:
                continue
        for match in _ISSUE_REF_RE.finditer(text):
            ref = (match.group(1) or repo, int(match.group(2)))
            if ref != (repo, int(issue.get('number') or 0)) and ref not in refs:
                refs.append(ref)
    return refs


def _blocker_label(ref, repo):
    ref_repo, number = ref
    return '#%d' % number if ref_repo == repo else '%s#%d' % (ref_repo, number)


def issue_open_blockers(issue, repo, issue_state, cache):
    """(open, unknown) blockers of an issue. unknown are refs whose state gh could not read (None). Cache is per pass."""
    open_refs, unknown = [], []
    for ref in issue_blocker_refs(issue, repo):
        if ref not in cache:
            cache[ref] = issue_state(*ref)
        if cache[ref] is None:
            unknown.append(ref)
        elif cache[ref] == 'OPEN':
            open_refs.append(ref)
    return open_refs, unknown


def fetch_issue_state(repo, number, run=subprocess.run):
    """OPEN or CLOSED for an issue, or None when gh fails or answers something else."""
    try:
        proc = run(['gh', 'issue', 'view', str(number), '--repo', repo, '--json', 'state', '--jq', '.state'],
                   capture_output=True, text=True, timeout=30, check=False)
    except (subprocess.SubprocessError, OSError):
        return None
    state = proc.stdout.strip().upper() if proc.returncode == 0 else ''
    return state if state in ('OPEN', 'CLOSED') else None


ISSUE_HOLD_LABELS = frozenset((
    'blocked', 'owner', 'deferred', 'tracking', 'needs-triage', 'needs-elon', 'needs-redesign',
))


def _issue_label_names(issue):
    return {entry.get('name') for entry in (issue.get('labels') or []) if isinstance(entry, dict)}


def issue_scan_eligible(issue):
    labels = _issue_label_names(issue)
    if 'ready-for-agent' not in labels or labels & ISSUE_HOLD_LABELS:
        return False
    if issue_scan_blocked(issue):
        return False
    texts = [issue.get('body') or '']
    texts += [entry.get('body') or '' for entry in (issue.get('comments') or []) if isinstance(entry, dict)]
    return any(issue_scan_has_acceptance(text) for text in texts)


def open_pr_for_issue(prs, number):
    """The open PR that closes or refs issue ``number`` or has the number in its branch name, else None."""
    ref = re.compile(r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\s*:?\s+(?:[\w.-]+/[\w.-]+)?#%d(?!\d)' % number, re.I)
    branch = re.compile(r'(?<!\d)%d(?!\d)' % number)
    for pr in prs or ():
        if not pr_open_for_dispatch(pr):
            continue
        if ref.search(pr.get('body') or '') or branch.search(pr.get('headRefName') or ''):
            return pr
    return None


def issue_scan_priority(issue):
    """P0 to P3 as 0 to 3. A `bug` label ranks as P0 (owner 2026-11-25, #1791). No P label ranks as P2."""
    labels = _issue_label_names(issue)
    if 'bug' in labels:
        return 0
    for rank, name in enumerate(('P0', 'P1', 'P2', 'P3')):
        if name in labels:
            return rank
    return 2


def issue_scan_size(issue):
    """size:S 0, no size label (M) 1, size:L 2."""
    labels = _issue_label_names(issue)
    if 'size:L' in labels:
        return 2
    return 0 if 'size:S' in labels else 1


def issue_scan_sort_key(issue):
    return (issue_scan_priority(issue), issue_scan_size(issue),
            issue.get('createdAt') or '', int(issue.get('number') or 0))


def issue_scan_queue_key(repo, issue):
    """Queue order: red main or red gate fix, then P0 or `bug` in any repo, then the rest, dotfiles first in each group, then the sort key.

    Owner rules 2026-11-20 (dotfiles first) and 2026-11-25 (P0 and bug first, #1791)."""
    dotfiles_first = 0 if str(repo).rsplit('/', 1)[-1] == 'dotfiles' else 1
    # A red main fix and a red gate fix go before everything else, in any repo (#1677, #1746).
    main_red_first = 0 if str(issue.get('title') or '').startswith((MAIN_RED_TITLE_PREFIX, RED_GATE_TITLE_PREFIX)) else 1
    urgent_first = 0 if issue_scan_priority(issue) == 0 else 1
    return (main_red_first, urgent_first, dotfiles_first) + issue_scan_sort_key(issue)


def next_ready_issue(repos, list_issues):
    """(repo, issue) an eligible ready issue first in queue order across ``repos``, or None. Same key as the issue scan."""
    pairs = [(repo, row) for repo in repos for row in (list_issues(repo) or []) if issue_scan_eligible(row)]
    return min(pairs, key=lambda pair: issue_scan_queue_key(*pair)) if pairs else None


# role label -> (worker title role, usage-gate preset role). No role label means fullstack-dev.
ISSUE_ROLE_ROUTES = (
    ('role:pm', 'architect-pm', 'architect-pm'),
    ('role:qa', 'qa-sdet', 'qa-sdet'),
    ('role:ops', 'release-manager', 'release-manager'),
    ('role:secops', 'secops-finops', 'secops-finops'),
    ('role:growth', 'sales-marketing', 'sales-marketing'),
    ('role:support', 'support-csm', 'support-csm'),
)


STRONG_TIER_ROLES = ('fullstack-dev', 'release-manager')  # size:L raises these to --tier strong (#1396)


def issue_scan_route(issue):
    """(title_role, pick_role, tier) for an issue, or None for the default fullstack-dev route."""
    labels = _issue_label_names(issue)
    large = 'size:L' in labels
    for label, title_role, pick in ISSUE_ROLE_ROUTES:
        if label in labels:
            return title_role, pick, 'strong' if large and pick in STRONG_TIER_ROLES else None
    if large:
        return 'fullstack-dev', 'fullstack-dev', 'strong'
    if 'size:S' in labels:
        return 'fullstack-dev-small', 'fullstack-dev-small', None
    return None


def issue_label_names(repo, number, run=subprocess.run):
    """An issue's label names, or [] when gh fails."""
    try:
        proc = run(['gh', 'issue', 'view', str(number), '--repo', repo, '--json', 'labels',
                    '--jq', '.labels[].name'], capture_output=True, text=True, timeout=30, check=False)
    except (subprocess.SubprocessError, OSError):
        return []
    return proc.stdout.split() if proc.returncode == 0 else []


_CLOSING_REF = re.compile(r'(?i)\b(?:closes|fixes|resolves)\s+#(\d+)\b')


def rework_needs_strong(repo, pr, rounds_done):
    """Owner #1396 Q3: Strong from the second rework round, or from round 1 when the PR or its closing issue is size:L."""
    if rounds_done >= 1 or pr_has_label(pr, 'size:L'):
        return True
    return any('size:L' in issue_label_names(repo, number)
               for number in _CLOSING_REF.findall(pr.get('body') or ''))


def issue_scan_sorted_eligible(issues):
    rows = [row for row in issues if issue_scan_eligible(row)]
    return sorted(rows, key=issue_scan_sort_key)


def checks_pass_at_head(pr):
    head = pr.get('headRefOid') or ''
    kind = newest_checks_kind(pr.get('comments'), head)
    if kind == 'PASS':
        return True
    if kind == 'FAIL':
        return False
    rollup = [
        check for check in (pr.get('statusCheckRollup') or [])
        if isinstance(check, dict)
        and (
            'head-checks' in (check.get('context') or check.get('name') or '').lower()
            or (check.get('context') or check.get('name') or '').lower() in (
                'checks', 'script-tests', 'script tests', 'shellcheck',
            )
        )
    ]
    return bool(rollup) and all(check.get('conclusion') == 'SUCCESS' for check in rollup)


def checks_fail_at_head(pr):
    return newest_checks_kind(pr.get('comments'), pr.get('headRefOid') or '') == 'FAIL'


def checks_receipt_at_head(pr):
    return newest_checks_kind(pr.get('comments'), pr.get('headRefOid') or '') in ('PASS', 'FAIL')


HEAD_CHECKS_INFRA_RERUNS = 2


def checks_infra_runs(pr):
    """How many Checks: INFRA receipts sit at this PR's head. Each is one finished run.

    A receipt that names a red gate does not count: the wait on the gate must not use up the reruns (#1746)."""
    head = pr.get('headRefOid') or ''
    count = 0
    for comment in pr.get('comments') or []:
        match = rs.HEAD_RECEIPT_RE.match(_receipt_first_line(comment.get('body')))
        if match and match.group('label') == 'Checks' and match.group('status') == 'INFRA' and match.group('head') == head:
            if not _RED_GATE_HOLD_RE.search(comment.get('body') or ''):
                count += 1
    return count


_RED_GATE_HOLD_RE = re.compile(r'^blocked by red gate #(\d+)\b', re.M)


def red_gate_hold(pr, open_gates):
    """Number of the red gate issue the newest Checks INFRA receipt at this head names, while it is open.

    open_gates(repo-less) is called only when a receipt names one. None means run head checks as usual (#1746)."""
    head = pr.get('headRefOid') or ''
    comment = newest_checks_comment(pr.get('comments'), head)
    if not comment:
        return None
    match = rs.HEAD_RECEIPT_RE.match(_receipt_first_line(comment.get('body')))
    if not match or match.group('status') != 'INFRA':
        return None
    named = _RED_GATE_HOLD_RE.search(comment.get('body') or '')
    if not named:
        return None
    number = int(named.group(1))
    gates = open_gates()
    # gh failed (None): keep waiting, the next pass asks again. A rerun would hit the broken gate.
    if gates is None:
        return number
    return number if number in gates else None


def fetch_red_gate_numbers(repo, run=subprocess.run):
    """Open red gate issue numbers of a repo, or None when gh fails."""
    gates = _sibling('red_gate', 'red-gate.py').open_gates(repo, run)
    return None if gates is None else set(gates)


def head_checks_infra_cap(config):
    value = (config.get('head_checks') or {}).get('infra_reruns', HEAD_CHECKS_INFRA_RERUNS)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return HEAD_CHECKS_INFRA_RERUNS
    return value


def review_verdict_at_head(pr):
    head = pr.get('headRefOid') or ''
    comments = pr.get('comments') or []
    return (
        newest_comment_receipt(comments, 'Review', head) is not None
        or newest_comment_receipt(comments, 'Verdict', head) is not None
    )


def pr_has_label(pr, label_name):
    for item in pr.get('labels') or []:
        if isinstance(item, dict) and item.get('name') == label_name:
            return True
        if item == label_name:
            return True
    return False


def _workflow_run_id_from_check(check):
    url = (check.get('detailsUrl') or '') if isinstance(check, dict) else ''
    match = re.search(r'/actions/runs/(\d+)', url)
    return match.group(1) if match else None


def status_rollup_failure_after_rerun(pr, workflow_watch_state, repo):
    watched = (workflow_watch_state or {}).get(repo, {})
    for check in pr.get('statusCheckRollup') or []:
        if not isinstance(check, dict) or check.get('conclusion') != 'FAILURE':
            continue
        attempt = check.get('attempt')
        if attempt is not None and attempt >= 2:
            return True
        run_id = _workflow_run_id_from_check(check)
        if run_id and watched.get(run_id) in ('rerun', 'issue'):
            return True
    return False


_VERDICT_LINE_RE = re.compile(
    r'^Verdict: (?P<status>PASS\+NOTES|PASS|FAIL) head=(?P<head>[0-9a-f]{40})'
    r'(?: verifier=(?P<verifier>[A-Za-z0-9_-]+) author=(?P<author>[A-Za-z0-9_-]+)'
    r'(?: agent=[A-Za-z0-9._-]+ model=[A-Za-z0-9._:-]+)?)?$'
)


def pr_checks_all_success(pr_row):
    if checks_fail_at_head(pr_row):
        return False
    required = [
        c for c in (pr_row.get('statusCheckRollup') or [])
        if isinstance(c, dict) and c.get('isRequired', True) is not False
    ]
    return bool(required) and all(
        (c.get('status') or 'COMPLETED') == 'COMPLETED'
        and (c.get('conclusion') or c.get('state') or '') == 'SUCCESS'
        for c in required
    )


def _git_base_ref(repo_root):
    rc = subprocess.run(
        ['git', '-C', repo_root, 'rev-parse', '--verify', '-q', 'origin/main'],
        capture_output=True, timeout=10,
    ).returncode
    return 'origin/main' if rc == 0 else 'main'


def _git_patch_id(repo_root, sha):
    if not repo_root or not os.path.isdir(repo_root):
        return None
    try:
        if subprocess.run(['git', '-C', repo_root, 'cat-file', '-e', '%s^{commit}' % sha],
                          capture_output=True, timeout=15).returncode != 0:
            subprocess.run(['git', '-C', repo_root, 'fetch', 'origin', sha],
                           capture_output=True, timeout=30, check=True)
        base = subprocess.run(
            ['git', '-C', repo_root, 'merge-base', _git_base_ref(repo_root), sha],
            capture_output=True, text=True, timeout=15, check=True,
        ).stdout.strip()
        if not base:
            return None
        diff = subprocess.run(
            ['git', '-C', repo_root, 'diff', '%s..%s' % (base, sha)],
            capture_output=True, timeout=30, check=True,
        ).stdout
        pid = subprocess.run(
            ['git', '-C', repo_root, 'patch-id', '--stable'],
            input=diff, capture_output=True, timeout=15, check=True,
        ).stdout.decode('utf-8', errors='replace').split()
        return pid[0] if pid else None
    except (subprocess.SubprocessError, OSError):
        return None


def pr_verdict_valid_for_head(pr_row, repo_root=None):
    head = pr_row.get('headRefOid') or ''
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        return False
    comments = sorted(
        [(idx, c) for idx, c in enumerate(pr_row.get('comments') or []) if isinstance(c, dict)],
        key=lambda pair: (pair[1].get('createdAt') or '', pair[0]), reverse=True,
    )
    for _, comment in comments:
        match = _VERDICT_LINE_RE.match(_receipt_first_line(comment.get('body')))
        if not match:
            continue
        status = match.group('status')
        if (comment.get('includesCreatedEdit') or comment.get('isMinimized')
                or comment.get('edited') or comment.get('minimized')) and status != 'FAIL':
            continue
        if match.group('verifier') and match.group('verifier') == match.group('author'):
            return False
        if status not in ('PASS', 'PASS+NOTES'):
            return False
        verdict_head = match.group('head')
        if verdict_head == head:
            return True
        pid_v = _git_patch_id(repo_root, verdict_head)
        return bool(pid_v and pid_v == _git_patch_id(repo_root, head))
    return False


SHIP_FALLBACK_AFTER = 15 * 60


def verdict_age_seconds(pr_row, now):
    """Seconds since the newest Verdict comment was posted. An unreadable time reads as old, so it never blocks."""
    newest = ''
    for comment in pr_row.get('comments') or []:
        if isinstance(comment, dict) and _VERDICT_LINE_RE.match(_receipt_first_line(comment.get('body'))):
            newest = max(newest, comment.get('createdAt') or '')
    try:
        return now - calendar.timegm(time.strptime(newest, '%Y-%m-%dT%H:%M:%SZ'))
    except ValueError:
        return SHIP_FALLBACK_AFTER


def pr_has_conflict(pr_row, repo_root=None):
    if (pr_row.get('conflict') is True or pr_row.get('behindMainConflict') is True
            or pr_row.get('mergeable') == 'CONFLICTING'
            or pr_row.get('mergeStateStatus') in ('DIRTY', 'CONFLICTING')):
        return True
    head = pr_row.get('headRefOid') or ''
    if repo_root and head and os.path.isdir(repo_root):
        try:
            base_ref = _git_base_ref(repo_root)
            if (subprocess.run(['git', '-C', repo_root, 'cat-file', '-e', '%s^{commit}' % head],
                               capture_output=True, timeout=10).returncode == 0
                    and subprocess.run(['git', '-C', repo_root, 'merge-base', '--is-ancestor', base_ref, head],
                                       capture_output=True, timeout=10).returncode != 0):
                return subprocess.run(
                    ['git', '-C', repo_root, 'merge-tree', '--write-tree', base_ref, head],
                    capture_output=True, timeout=15,
                ).returncode != 0
        except (subprocess.SubprocessError, OSError):
            pass
    return False


def pr_has_unresolved_threads(pr_row):
    if pr_row.get('reviewDecision') == 'CHANGES_REQUESTED':
        return True
    unresolved = pr_row.get('unresolvedReviewThreads', pr_row.get('unresolved_threads'))
    if (isinstance(unresolved, int) and unresolved > 0) or (isinstance(unresolved, list) and unresolved):
        return True
    threads = pr_row.get('reviewThreads')
    if isinstance(threads, dict):
        threads = threads.get('nodes')
    return isinstance(threads, list) and any(
        isinstance(t, dict) and not t.get('isResolved', t.get('resolved', False)) for t in threads
    )


def _file_set(items):
    out = set()
    for item in items or ():
        path = item if isinstance(item, str) else ((item.get('path') or item.get('filename')) if isinstance(item, dict) else '')
        if isinstance(path, str) and path:
            out.add(path)
    return out


def pr_red_check_in_diff(pr_row, workflow_watch_state=None, repo=''):
    diff_files = _file_set(pr_row['files']) if 'files' in pr_row and pr_row['files'] is not None else None
    if checks_fail_at_head(pr_row):
        if diff_files is None:
            return True
        comment = newest_comment_receipt(pr_row.get('comments') or [], 'Checks', pr_row.get('headRefOid') or '')
        rest = '\n'.join(((comment or {}).get('body') or '').splitlines()[1:]).strip()
        return any(f in rest for f in diff_files) if rest else bool(diff_files)
    for check in pr_row.get('statusCheckRollup') or []:
        if not isinstance(check, dict):
            continue
        if (check.get('conclusion') or check.get('state') or '') not in ('FAILURE', 'ERROR'):
            continue
        if (check.get('context') or check.get('name') or '').lower() == 'review':
            continue
        explicit = _file_set([check.get('file'), check.get('path')] + (check.get('failingFiles') or []) + (check.get('files') or []))
        text = '\n'.join(str(check.get(k)) for k in ('summary', 'title', 'description', 'text', 'output') if check.get(k))
        if diff_files is not None:
            if explicit and (explicit & diff_files):
                return True
            if not explicit and text and any(f in text for f in diff_files):
                return True
        elif not explicit and status_rollup_failure_after_rerun({'statusCheckRollup': [check]}, workflow_watch_state, repo):
            return True
    return False


def rework_needed_at_head(pr, workflow_watch_state=None, repo='', repo_root=None):
    return (
        pr_has_conflict(pr, repo_root=repo_root)
        or pr_has_unresolved_threads(pr)
        or review_failed_at_head(pr)
        or pr_red_check_in_diff(pr, workflow_watch_state, repo)
    )


def pr_tier(pr_row):
    """0, 1 or 2 from the PR's changed files and line counts (script/pr-tier.py, #1730)."""
    try:
        files = pr_row.get('files')
        return _sibling('pr_tier', 'pr-tier.py').classify(files if isinstance(files, list) else None)[0]
    except Exception:
        return 2


def classify_open_pr(pr_row, workflow_watch_state=None, repo='', repo_root=None):
    if pr_row.get('state') != 'OPEN' or pr_row.get('isDraft'):
        return 'waiting'
    if rework_needed_at_head(pr_row, workflow_watch_state, repo, repo_root=repo_root):
        return 'needs_fix'
    # UNKNOWN means GitHub has not calculated the merge yet. ship.sh rereads it.
    # CONFLICTING is already needs_fix via rework_needed_at_head.
    if (pr_row.get('mergeable') != 'CONFLICTING'
            and pr_row.get('mergeStateStatus') not in ('DIRTY', 'CONFLICTING')
            and pr_checks_all_success(pr_row)
            and (pr_verdict_valid_for_head(pr_row, repo_root=repo_root)
                 # Tier 0 (tests and docs only, #1730) ships on Review PASS at the head, with no Verdict.
                 or (pr_tier(pr_row) == 0 and cold_review_passed_at_head(pr_row)))):
        return 'ready'
    return 'waiting'


def pr_has_live_fix_worker(workers, pr_row):
    number = pr_row.get('number')
    branch = pr_row.get('headRefName') or ''
    names = {'rework-%s' % number, 'fix-%s' % number, 'rework #%s' % number, 'fix #%s' % number} if number is not None else set()
    for w in workers or ():
        if not isinstance(w, dict) or worker_terminal_released(w) or worker_freed_by_terminal_exit(w):
            continue
        if worker_inventory_status(w) in ('completed', 'succeeded', 'failed', 'released', 'cancelled', 'abandoned', 'stopped'):
            continue
        proj = w.get('projection') or {}
        if (proj.get('role') or w.get('role') or '').lower() in ('qa', 'qa-sdet', 'reviewer', 'verifier'):
            continue
        if (number is not None and worker_pr_number(w) == number) or (branch and worker_branch_name(w) == branch):
            return True
        if any((w.get(k) or proj.get(k)) in names for k in ('name', 'title')):
            return True
    return False


REWORK_EXCERPT_CAP = 20000  # head-checks.sh posts at most 20000 characters, so a receipt always fits whole
REWORK_STEP_TAIL_LINES = 40


def _rework_comment_text(comment):
    """The comment link and its full body, capped at REWORK_EXCERPT_CAP."""
    body = comment.get('body') or ''
    if len(body) > REWORK_EXCERPT_CAP:
        body = body[:REWORK_EXCERPT_CAP] + '\n[... comment cut at %d characters, see the link]' % REWORK_EXCERPT_CAP
    url = comment.get('url')
    return ('Comment: %s\n' % url if url else '') + body


def checks_failing_step(body):
    """(step name, last 40 output lines) of the failing step in a head-checks receipt, or None.

    A retried step (``retrying once``) is not the failure. A receipt cut to fit its cap lists the
    failing Result lines before any Command line; the failing step is then the last Command."""
    lines = (body or '').splitlines()

    def failing(line):
        return (line.startswith('Result: ') and not line.startswith('Result: exit 0')
                and 'retrying once' not in line)

    def tail(start, stop):
        kept = [l for l in lines[start:stop] if l.strip() and not l.startswith(('Result: ', 'Duration: ', 'Total: '))]
        return kept[-REWORK_STEP_TAIL_LINES:]

    command = ''
    start = 0
    for idx, line in enumerate(lines):
        if line.startswith('Command: '):
            command, start = line[len('Command: '):].strip(), idx + 1
        elif failing(line):
            if command:
                return command, '\n'.join(tail(start, idx) + [line])
            commands = [i for i, l in enumerate(lines) if l.startswith('Command: ')]
            if not commands:
                return None
            last = commands[-1]
            return lines[last][len('Command: '):].strip(), '\n'.join(tail(last + 1, len(lines)) + [line])
    return None


def rework_failure_excerpt(pr_row):
    head = pr_row.get('headRefOid') or ''
    comments = pr_row.get('comments') or []
    comment = newest_comment_receipt(comments, 'Checks', head)
    if comment:
        first = _receipt_first_line(comment.get('body'))
        if first.startswith('Checks: FAIL'):
            text = _rework_comment_text(comment)
            step = checks_failing_step(comment.get('body'))
            if step:
                text = 'Failing step: %s\nLast %d lines of that step:\n%s\n\n%s' % (
                    step[0], REWORK_STEP_TAIL_LINES, step[1], text)
            return text
    for label in ('Review', 'Verdict'):
        comment = newest_comment_receipt(comments, label, head)
        if comment and rs.newest_receipt_kind(comments, label, head) == 'FAIL':
            return _rework_comment_text(comment)
    for check in pr_row.get('statusCheckRollup') or []:
        if not isinstance(check, dict) or _check_conclusion(check) not in ('FAILURE', 'ERROR'):
            continue
        name = check.get('context') or check.get('name') or 'check'
        parts = ['statusCheckRollup FAILURE: %s' % name]
        summary = check.get('summary') or check.get('title') or check.get('description')
        if summary:
            parts.append(summary)
        return '\n'.join(parts)
    return 'Rework after failure on head %s' % head


_HOST_FAULT_RE = re.compile(r'host fault|^Tests executed: 0\s*$', re.IGNORECASE | re.MULTILINE)


def checks_fail_is_host_fault(pr_row):
    """True when the newest Checks FAIL at this head says host fault, or its database step ran no tests."""
    comment = newest_comment_receipt(pr_row.get('comments') or [], 'Checks', pr_row.get('headRefOid') or '')
    if not comment or not _receipt_first_line(comment.get('body')).startswith('Checks: FAIL'):
        return False
    return bool(_HOST_FAULT_RE.search(comment.get('body') or ''))


def _repo_checks_lock_path(repo_root):
    try:
        output = subprocess.run(
            ['git', '-C', repo_root, 'config', '--get', 'remote.origin.url'],
            capture_output=True, text=True, timeout=10, check=False,
        )
        remote = (output.stdout or '').strip()
    except (subprocess.SubprocessError, OSError):
        remote = ''
    name = os.path.basename(remote.rstrip('/')) if remote else os.path.basename(repo_root)
    if name.endswith('.git'):
        name = name[:-4]
    return os.path.expanduser(os.path.join('~', 'orca', 'workspaces', name, '_checks.lock'))


def head_checks_lock_live(repo_root, lock_live=None):
    if lock_live is not None:
        return lock_live(repo_root)
    return _lock_holder_live(_repo_checks_lock_path(repo_root))


def head_checks_gate_lock(host):
    """The lock path when a head checks run on this host holds the database step on `host`, else None (#1844).

    head-checks.sh takes ~/orca/workspaces/<repo>/_db-<host>_<dir>.lock for the whole database step, from before
    the remote heavy-gate wait to the end of the step, and that gate samples `host`'s own free memory.
    """
    # The lock key is <host>_<remote dir> with every other character turned into _, and the dir is absolute,
    # so <host>__ starts it: host-a never matches the lock of host-a-2 (host_a_2__...).
    key = re.sub(r'[^A-Za-z0-9._]', '_', host or '') + '__'
    if key == '__':
        return None
    for lock in sorted(Path.home().glob('orca/workspaces/*/_db-*.lock')):
        if lock.name[len('_db-'):].startswith(key) and _lock_holder_live(str(lock)):
            return str(lock)
    return None


def head_checks_running():
    """The lock path of a live head-checks run on this host (any repo's _checks.lock), else None (#2068).

    The runner counts as a heavy job: it builds and type checks in the shared checks worktree."""
    for lock in sorted(Path.home().glob('orca/workspaces/*/_checks.lock')):
        if _lock_holder_live(str(lock)):
            return str(lock)
    return None


def heavy_gate_slots_held():
    """How many heavy-gate slots on this host a live job holds (#2068)."""
    held = 0
    for slot in Path.home().glob('.cache/heavy-gate/slot-*'):
        try:
            pid = int((slot / 'pid').read_text().strip())
            os.kill(pid, 0)
        except (OSError, ValueError):
            continue
        held += 1
    return held


def _lock_holder_live(lock):
    if not os.path.isdir(lock):
        return False
    pid_path = os.path.join(lock, 'pid')
    try:
        with open(pid_path, encoding='utf-8') as stream:
            holder = stream.read().strip()
    except OSError:
        return False
    if not holder.isdigit():
        return False
    try:
        os.kill(int(holder), 0)
    except OSError:
        return False
    return True


def build_head_checks_command(config, repo, pr_row):
    if (repo or '').split('/')[-1] == 'dotfiles':
        return None
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    head = pr_row.get('headRefOid') or ''
    if not head:
        return None
    script = str(Path(__file__).with_name('head-checks.sh'))
    return ['bash', script, '--repo', root, '--pr', str(pr_row['number'])]


def build_ship_command(repo, pr_row, root=None):
    script = str(Path(__file__).with_name('ship.sh'))
    command = ['bash', script, '--repo', repo, '--pr', str(pr_row['number'])]
    if root:
        # ship.sh refuses a cwd that is not the repo checkout (#1326), so start it from there.
        return ['bash', '-c', 'cd "$1" || exit 1; shift; exec "$@"', 'ship-in-checkout', root] + command
    return command


def default_detached_start(command, extra_env=None, popen=subprocess.Popen):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    try:
        popen(command, start_new_session=True, env=env)
        return BabysitStartResult(0)
    except OSError as exc:
        return BabysitStartResult(1, _start_reason(str(exc)))


def review_failed_at_head(pr):
    if rs.review_failed_at_head(pr):
        return True
    saw_failure = False
    for check in pr.get('statusCheckRollup') or []:
        if not isinstance(check, dict):
            continue
        if (check.get('context') or check.get('name') or '').lower() != 'review':
            continue
        conclusion = _check_conclusion(check)
        if conclusion == 'SUCCESS':
            return False
        if conclusion in ('FAILURE', 'ERROR'):
            saw_failure = True
    return saw_failure


def fetch_ready_issues(repo, run=subprocess.run):
    command = [
        'gh', 'issue', 'list', '--repo', repo, '--label', 'ready-for-agent', '--state', 'open',
        '--limit', '100', '--json', 'number,title,body,labels,comments,createdAt,updatedAt,blockedBy',
    ]
    try:
        output = run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        return None


def fetch_claimed_issues(repo, run=subprocess.run):
    """Open issues that carry the in-progress status label worker-startup's claim sets (#1811)."""
    command = [
        'gh', 'issue', 'list', '--repo', repo, '--label', ISSUE_CLAIM_LABEL, '--state', 'open',
        '--limit', '100', '--json', 'number,labels',
    ]
    try:
        output = run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        return None


def _issue_scan_startup_script(config):
    scan = config.get('issue_scan') or {}
    configured = (scan.get('startup') or '').strip()
    if configured:
        return configured
    return str(Path(__file__).with_name('worker-startup.sh'))


def _write_issue_scan_spec(text):
    handle, path = tempfile.mkstemp(prefix='fleet-watch-spec-', suffix='.md')
    os.close(handle)
    Path(path).write_text(text, encoding='utf-8')
    return path


def _issue_scan_repo_root(config, repo):
    roots = (config.get('issue_scan') or {}).get('repo_roots') or {}
    root = roots.get(repo)
    if isinstance(root, str) and root:
        return root
    return None


def _brief_lint_script():
    return str(Path(__file__).with_name('brief-lint.sh'))


def brief_lint_missing(spec_path, run=subprocess.run):
    try:
        proc = run(
            ['bash', _brief_lint_script(), spec_path],
            capture_output=True, text=True, errors='replace', timeout=30, check=False,
        )
    except (subprocess.SubprocessError, OSError, UnicodeDecodeError):
        return ['brief-lint failed']
    if proc.returncode == 0:
        return []
    out = (proc.stdout or proc.stderr or '').strip()
    missing = [
        line.split('brief-lint: missing ', 1)[1].strip()
        for line in out.splitlines()
        if line.startswith('brief-lint: missing ')
    ]
    return missing or [out or 'brief-lint failed']


def _repo_id_in_list(result, repo):
    key = 'github.com/%s' % str(repo or '').lower()
    for row in (result.get('repos') if isinstance(result, dict) else None) or []:
        if not isinstance(row, dict) or not row.get('id'):
            continue
        identity = row.get('gitRemoteIdentity') or {}
        if str(identity.get('canonicalKey') or '').lower() == key:
            return row['id']
    return None


def default_repo_id_lookup(host, repo):
    """Orca repo id of owner/name on an environment, matched by git remote since paths differ per host."""
    try:
        result = rpc('repo', 'list', '--environment', host)
    except Exception:
        return None
    return _repo_id_in_list(result, repo)


def default_local_repo_id(repo):
    """Orca repo id of owner/name on this machine."""
    try:
        result = rpc('repo', 'list')
    except Exception:
        return None
    return _repo_id_in_list(result, repo)


def pr_base_ref(root, branch, run=subprocess.run):
    """Fetch the PR head branch from origin and name it as a remote ref, since a PR opened on another host has no local ref."""
    try:
        run(['git', '-C', root, 'fetch', '-q', 'origin', branch], capture_output=True, timeout=60)
    except (subprocess.SubprocessError, OSError):
        pass
    return 'origin/' + branch


def checks_local_applies(root):
    """True when this checkout has script/checks-local.sh."""
    if not isinstance(root, str) or not root:
        return False
    return (Path(root) / 'script' / 'checks-local.sh').is_file()


def checks_local_verify_text(root, present):
    """Verify text. A repo without the script gets one sentence and no other command."""
    if checks_local_applies(root):
        return present
    return 'checks-local.sh does not apply to this repo'


def local_repo_selector(root):
    """--repo id:<id> for the Orca repo at root (#1204), else path:<root> when Orca cannot name it."""
    try:
        repos = rpc('repo', 'list').get('repos') or []
    except Exception:
        repos = []
    for repo in repos:
        if isinstance(repo, dict) and repo.get('id') and repo.get('path') == root:
            return 'id:' + repo['id']
    return 'path:' + root


def live_start_title(command, workers):
    """True when a live worker already carries this start's #<issue or PR>| prefix, whatever its role or suffix."""
    title = command[command.index('--title') + 1] if '--title' in command else ''
    prefix = title.split('|', 1)[0] + '|' if '|' in title else title
    return bool(prefix) and any(
        isinstance(w, dict) and str(w.get('_task_title') or '').startswith(prefix) and worker_row_is_live(w)
        for w in workers or []
    )


_SPEC_REFS_LINE_RE = re.compile(r'^(?:Issues|Refs):?\s.*$', re.M)
_BRANCH_ISSUE_RE = re.compile(r'(?:^|/)[bw]([0-9]+)$')


def _live_row_names_issue(w, number):
    """True when the row's task title starts with '#<number>|', its task spec has #<number> on a Refs or Issues
    line, or its branch (or worktree folder) is <user>/b<number> or w<number> (#1692, #1960)."""
    if str(w.get('_task_title') or '').startswith('#%d|' % number):
        return True
    refs = ' '.join(_SPEC_REFS_LINE_RE.findall(str(w.get('_task_spec') or '')))
    if re.search(r'#%d(?![0-9])' % number, refs):
        return True
    for name in (worker_branch_name(w), worker_checkout_path(w), w.get('_host_workspace')):
        match = _BRANCH_ISSUE_RE.search(str(name or '').rstrip('/'))
        if match and int(match.group(1)) == number:
            return True
    return False


def issue_has_live_dispatch(workers, number):
    """True when a live worker holds issue <number> by task title, task spec or branch, whatever the issue's labels
    say (#1692). A hand start whose title never set still blocks a second builder (#1960)."""
    return any(isinstance(w, dict) and worker_row_is_live(w) and _live_row_names_issue(w, number)
               for w in workers or [])


def issue_brief_refs(row):
    """Same repo issue numbers on the Issues or Refs lines of the issue's brief: worker-startup holds every one of them (#1839)."""
    lines = ' '.join(_SPEC_REFS_LINE_RE.findall(issue_scan_brief_text(row)))
    return {int(n) for n in re.findall(r'(?<![\w/.-])#(\d+)', lines)}


def issue_live_ref(workers, row):
    """The issue number a live worker holds for this start (its own, or one its brief bundles), else None (#2062)."""
    for number in [row['number']] + sorted(issue_brief_refs(row) - {row['number']}):
        if issue_has_live_dispatch(workers, number):
            return number
    return None


OVERLAP_HOLD_PASSES = 6  # an overlap refusal is not retried for this many passes unless the issue or the open PRs change (#2062)


def overlap_fingerprint(row, pr_rows):
    """Brief text plus the open PR heads: the two things check-issue-overlap.sh reads (#2062)."""
    prs = sorted('%s@%s' % (p.get('number'), p.get('headRefOid') or '') for p in pr_rows or [] if isinstance(p, dict))
    return hashlib.sha256((issue_scan_brief_text(row) + '\0' + ','.join(prs)).encode('utf-8')).hexdigest()


def overlap_hold(state, repo, row, pr_rows):
    """True while an overlap refusal still stands: same fingerprint and fewer than OVERLAP_HOLD_PASSES passes (#2062)."""
    book = state.get('issue_scan_overlap', {}).get(repo, {})
    entry = book.get(str(row['number']))
    if not entry:
        return False
    if entry.get('fp') != overlap_fingerprint(row, pr_rows) or entry.get('passes', 0) >= OVERLAP_HOLD_PASSES:
        book.pop(str(row['number']), None)
        return False
    entry['passes'] = entry.get('passes', 0) + 1
    return True


def build_issue_start_command(config, repo, issue_row, placement=None, route=None):
    """placement is (host, repo_id) to start on a remote host instead of the local checkout.

    route is (title_role, agent, model) from a role or size label; None keeps the scan's builder pick."""
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    verify = checks_local_verify_text(
        root, 'Run bash script/checks-local.sh and show the Done condition.')
    role = route[0] if route else scan.get('role') or 'builder'
    agent, model = (route[1], route[2]) if route else (scan.get('agent') or 'claude', scan.get('model') or '')
    spec_path = _write_issue_scan_spec(_with_preamble(
        'Refs %s#%d\n\n%s\n\n'
        '## Verify\n'
        '%s\n\n'
        '## Finish\n'
        'Self-review, push, open the PR, wait until gh pr checks <n> --watch --fail-fast (or gh run list --branch <branch> --limit 3) passes at the final head, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        % (repo, issue_row['number'], issue_scan_brief_text(issue_row).rstrip()
           + (TIER0_SAME_FAMILY_NOTE if route and len(route) > 3 and route[3] else ''), verify),
        role))
    title = '#%d|%s' % (issue_row['number'], role)
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', title,
        '--agent', agent,
        '--model', model,
        '--name', 'issue-%d' % issue_row['number'],
        '--repo', local_repo_selector(root),
    ]
    if placement:
        command[command.index('--repo') + 1] = 'id:' + placement[1]
        command += ['--on', placement[0]]
    return [part for part in command if part]


def build_rework_start_command(config, repo, pr_row, route=None):
    """route is a Strong (agent, model, tag) pick from rework_needs_strong, or None for the Workhorse rework."""
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    head = pr_row.get('headRefOid') or ''
    excerpt = rework_failure_excerpt(pr_row)
    if checks_local_applies(root):
        verify = 'bash script/checks-local.sh, then the failing check:\n' + excerpt
    else:
        verify = 'checks-local.sh does not apply to this repo'
    spec_path = _write_issue_scan_spec(_with_preamble(
        'Refs %s#%d\n'
        'Rework %s PR #%d head %s\n\n'
        '## Acceptance\n'
        '- [ ] the failing check passes\n\n'
        '%s\n\n'
        '## Out of scope\n'
        'files outside this PR\n\n'
        '## Verify\n'
        '%s\n\n'
        '## Finish\n'
        'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        % (repo, pr_row['number'], repo, pr_row['number'], head, excerpt, verify),
        'fullstack-dev'))
    title = '#%d|fullstack-dev' % pr_row['number']
    agent = route[0] if route else scan.get('rework_agent') or scan.get('agent') or 'claude'
    model = route[1] if route else scan.get('rework_model') or scan.get('model') or ''
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', title,
        '--agent', agent,
        '--model', model,
        '--name', 'rework-%d' % pr_row['number'],
        '--repo', local_repo_selector(root),
    ]
    branch = pr_row.get('headRefName')
    if branch:
        command += ['--base-branch', pr_base_ref(root, branch)]
    if route:
        command += ['--route-override', 'Strong rework (#1396)']
    return [part for part in command if part]


_BACKLOG_SWEEP_ROLES = ('architect-pm', 'sales-marketing')
_NO_GROK_CURSOR_ROLES = ('elon', 'architect-pm', 'secops-finops')  # usage-gate.py STRONG_NO_CURSOR
_BACKLOG_SWEEP_INTERVAL = 7200
_BACKLOG_SWEEP_QUEUE_MAX = 3


def issue_scan_ready_queue_count(repos, list_issues):
    total = 0
    for repo in repos:
        rows = list_issues(repo)
        if rows is None:
            return None
        total += len(rows)
    return total


def issue_scan_backlog_sweep_due(state, now, interval):
    last = state.get('issue_scan_backlog_sweep_at')
    if last is None:
        return True
    try:
        return now - float(last) >= interval
    except (TypeError, ValueError):
        return True


def build_backlog_sweep_command(config, repo, role):
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    spec = (
        'Role: %s. Read-only backlog sweep of open issues not ready-for-agent; no code.\n'
        % role
    )
    spec_path = _write_issue_scan_spec(_with_preamble(spec, role))
    agent = scan.get('sweep_agent') or scan.get('agent') or 'claude'
    if role in _NO_GROK_CURSOR_ROLES and agent in ('grok', 'cursor') and not scan.get('sweep_agent'):
        agent = 'claude'  # these roles never run on Grok or Cursor; the builder's pick must not leak in
    model = scan.get('sweep_model') or scan.get('model') or ''
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', '#0|%s' % role,  # a sweep has no issue, so it uses #0
        '--agent', agent,
        '--model', model,
        '--name', 'backlog-%s' % role,
        '--repo', local_repo_selector(root),
    ]
    return [part for part in command if part]


def issue_scan_backlog_sweep_roles_remaining(state):
    done = set(state.get('issue_scan_backlog_sweep_roles') or ())
    return [role for role in _BACKLOG_SWEEP_ROLES if role not in done]


def issue_scan_try_backlog_sweep(
    config, state, now, repos, ready_queue_count, host, admission, extra_starts, workers,
    start_worker, persist_state,
):
    log_bits = []
    scan = config.get('issue_scan') or {}
    if any((state.get('issue_scan_pending') or {}).values()):
        log_bits.append('backlog_sweep_skip_issue_pending')
        return log_bits
    if ready_queue_count is None:
        log_bits.append('backlog_sweep_list_failed')
        return log_bits
    count = ready_queue_count
    if count >= _BACKLOG_SWEEP_QUEUE_MAX:
        log_bits.append('backlog_sweep_skip_queue')
        return log_bits
    interval = scan.get('backlog_sweep_interval_seconds', _BACKLOG_SWEEP_INTERVAL)
    sweep_due = issue_scan_backlog_sweep_due(state, now, interval)
    if sweep_due:
        state.pop('issue_scan_backlog_sweep_roles', None)
        roles = list(_BACKLOG_SWEEP_ROLES)
    elif state.get('issue_scan_backlog_sweep_roles'):
        roles = issue_scan_backlog_sweep_roles_remaining(state)
        if not roles:
            log_bits.append('backlog_sweep_skip_recent')
            return log_bits
    else:
        log_bits.append('backlog_sweep_skip_recent')
        return log_bits
    if state.get('issue_scan_backlog_sweep_pending'):
        log_bits.append('backlog_sweep_skip_pending')
        return log_bits
    cap = config.get('host_caps', {}).get(host, 4)
    occupied = admission.get('occupied') or 0
    if extra_starts + occupied + len(roles) > cap:
        log_bits.append('backlog_sweep_skip_load')
        return log_bits
    repo = None
    for candidate in repos:
        if _issue_scan_repo_root(config, candidate):
            repo = candidate
            break
    if not repo:
        log_bits.append('backlog_sweep_skip_root')
        return log_bits
    if not start_allowed(agent_start_cost(scan.get('sweep_agent') or scan.get('agent') or 'claude')):
        log_bits.append('backlog_sweep_budget=%s' % repo)
        return log_bits
    state['issue_scan_backlog_sweep_pending'] = True
    if persist_state:
        persist_state()
    started = 0
    for role in roles:
        command = build_backlog_sweep_command(config, repo, role)
        if command is None:
            log_bits.append('backlog_sweep_skip=%s' % role)
            continue
        if at_max_workers(config, workers):
            # Each role is a live worker: the ceiling holds for the next one too (#2016). It stays due for a later pass.
            log_bits.append('backlog_sweep_max_workers')
            break
        if not start_allowed(start_cost(command)):
            log_bits.append('backlog_sweep_budget=%s' % role)
            break
        if start_worker(command) == 0:
            started += 1
            log_bits.append('backlog_sweep_start=%s' % role)
            count_worker_started()
        else:
            log_bits.append('backlog_sweep_fail=%s' % role)
            count_failed()
            continue
        started_list = state.setdefault('issue_scan_backlog_sweep_roles', [])
        if role not in started_list:
            started_list.append(role)
    state.pop('issue_scan_backlog_sweep_pending', None)
    if started > 0:
        state['issue_scan_backlog_sweep_at'] = now
    if not issue_scan_backlog_sweep_roles_remaining(state):
        state.pop('issue_scan_backlog_sweep_roles', None)
    if persist_state:
        persist_state()
    return log_bits


_TRIAGE_INTERVAL_HOURS = 2
_TRIAGE_LABELS = ('needs-triage', 'ready-for-human')
_TRIAGE_BRIEF = Path(__file__).resolve().parent.parent / 'templates/agent-team/docs/agents/triage-worker-brief.md'


def fetch_triage_backlog(repo, run=subprocess.run):
    """Open needs-triage and ready-for-human issues as {number: updatedAt}, or None when gh fails."""
    seen = {}
    for label in _TRIAGE_LABELS:
        command = [
            'gh', 'issue', 'list', '--repo', repo, '--label', label, '--state', 'open',
            '--limit', '100', '--json', 'number,updatedAt',
        ]
        try:
            output = run(command, capture_output=True, text=True, timeout=30, check=True)
            seen.update((row['number'], row.get('updatedAt') or '') for row in json.loads(output.stdout))
        except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
            return None
    return seen


def triage_backlog_unchanged(backlog, last):
    """True when the backlog is the one the last triage start saw: same numbers, none updated since (#1723).

    A bare count (no per issue times) or no earlier snapshot cannot prove it, so triage may start."""
    if not isinstance(backlog, dict) or not isinstance(last, dict):
        return False
    try:
        started = float(last['at'])
        seen = {int(n) for n in last['issues']}
        if seen != {int(n) for n in backlog}:
            return False
        for stamp in backlog.values():
            when = datetime.datetime.fromisoformat(str(stamp).replace('Z', '+00:00')).timestamp()
            if when > started:
                return False
    except (KeyError, TypeError, ValueError):
        return False
    return True


def build_triage_command(config, repo, agent, model):
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    spec_path = _write_issue_scan_spec(_with_preamble(_TRIAGE_BRIEF.read_text(encoding='utf-8'), 'architect-pm'))
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', '#0|architect-pm',
        '--agent', agent,
        '--model', model,
        '--name', 'triage-architect-pm',
        '--repo', local_repo_selector(root),
    ]
    return [part for part in command if part]


_SUPPLY_BRIEF = Path(__file__).resolve().parent.parent / 'docs/agents/supply-worker-brief.md'
_SUPPLY_TITLE = '#0|architect-pm|supply'


def build_supply_command(config, repos, agent, model, claimed=(), free=0):
    """One supply worker for all watched repos, started in the first repo that has a local root (#1689).

    `claimed` is (repo, number) for open issues labeled ISSUE_CLAIM_LABEL with no live worker (#1876).
    `free` is the free seats: the brief asks for that many ready issues (#1904)."""
    scan = config['issue_scan']
    root = next((r for r in (_issue_scan_repo_root(config, repo) for repo in repos) if r), None)
    if not root:
        return None
    text = _SUPPLY_BRIEF.read_text(encoding='utf-8') + ''.join('- %s\n' % repo for repo in repos)
    text += '\nFree seats: %d\n' % free
    if claimed:
        text += '\n## Claimed with no live worker\n\n' + ''.join('- %s#%d\n' % pair for pair in claimed)
    spec_path = _write_issue_scan_spec(_with_preamble(text, 'architect-pm'))
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', _SUPPLY_TITLE,
        '--agent', agent,
        '--model', model,
        '--name', 'supply-architect-pm',
        '--repo', local_repo_selector(root),
    ]
    return [part for part in command if part]


_SUPPLY_DONE_RE = re.compile(r'\bsupply ready=(\d+) reasons=(\d+)\b')


def supply_done_notices(messages, workers, state):
    """A supply worker_done that made no ready issue and gave no reason is a failure in the digest (#1904).

    The brief asks for the subject `supply ready=<n> reasons=<k>`. A missing line counts as nothing made.
    Each message is reported once; the first pass only records the messages already in the inbox."""
    titles = {w.get('dispatchId'): str(w.get('_task_title') or w.get('title') or '')
              for w in workers or [] if isinstance(w, dict)}
    first = 'supply_done_seen' not in state
    seen = state.setdefault('supply_done_seen', [])
    notices = []
    for m in messages or []:
        if not isinstance(m, dict) or m.get('type') != 'worker_done' or not m.get('id') or m['id'] in seen:
            continue
        if worker_done_rejected(m):
            continue
        payload = _message_payload(m)
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        if not titles.get(dispatch, '').startswith(_SUPPLY_TITLE):
            continue
        seen.append(m['id'])
        match = _SUPPLY_DONE_RE.search(str(m.get('subject') or ''))
        if first or (match and (int(match.group(1)) or int(match.group(2)))):
            continue
        notices.append('supply run failed: %s made no ready issue and gave no reason (subject: %s)'
                       % (dispatch, str(m.get('subject') or '')[:80]))
    del seen[:-200]
    return notices


def work_order_supply_line(config, now, workers, supply, host=None, admission=None, waiting=()):
    """`work order: N live, supply S[, host load L cap C]`, S the ready-for-agent issues this pass could start, or None without a work_order block.

    There is no fleet-wide count limit (#1757): starts follow each host's load and cap, so the line shows those, not N of T."""
    if work_order_settings(config, now) is None:
        return None
    real = real_live_count()
    asking = len({w.get('dispatchId') for w in workers or [] if isinstance(w, dict) and worker_row_is_live(w)} & set(waiting))
    if real is None:
        live = active_worker_count(workers)
        shown = worker_count.label(*worker_count_split(workers))
    else:
        live, shown, asking = real, str(real), min(asking, real)
    line = 'work order: %s live (%d working, %d waiting on coordinator), supply %d' % (shown, live - asking, asking, supply)
    if host and isinstance(admission, dict):
        load = admission.get('load_per_core')
        if load is None and _is_local_coordinator_host(host, config):
            load = coordinator_load_per_core()  # admit() reports it only on a breach
        cap = (config.get('host_caps') or {}).get(host, 4)
        line += ', %s load %s cap %s' % (host, '%.2f' % load if isinstance(load, (int, float)) else 'n/a', cap)
    return line


def _architect_pm_making_work(workers):
    """A live supply, triage or backlog sweep architect-pm: all of them carry the #0|architect-pm title."""
    return any(
        isinstance(w, dict) and str(w.get('_task_title') or '').startswith('#0|architect-pm') and worker_row_is_live(w)
        for w in workers or []
    )


SUPPLY_FORCE_PASSES = 3


def work_order_try_supply(
    config, state, now, repos, supply, host, admission, extra_starts, reserved, workers,
    start_worker, pick_fn=None, persist_state=None, count_open=None, clear_blocked=None, stale_claimed=None,
):
    """Free capacity under target_workers above the ready-for-agent supply: start one architect-pm to make work (#1689).

    At most one runs: a live #0|architect-pm worker blocks it, and it starts at most once per
    triage_interval_hours. `reserved` local seats stay free for the ready issues of this pass.
    From the SUPPLY_FORCE_PASSES-th short pass in a row, while the repos still have an open issue, the interval
    is skipped and `clear_blocked(repos)` runs. supply_enough or a supply start resets the count (#1876)."""
    order = work_order_settings(config, now)
    if order is None:
        return [], 0
    if at_max_workers(config, workers):
        return ['supply_max_workers'], 0
    free = order[1] - working_worker_count(workers, state) - extra_starts
    if free <= supply:
        state['work_order_short_passes'] = 0
        return ['supply_enough=%d:%d' % (free, supply)], 0
    try:
        short = int(state.get('work_order_short_passes') or 0) + 1
    except (TypeError, ValueError):
        short = 1
    state['work_order_short_passes'] = short
    if _architect_pm_making_work(workers):
        # Checked before the forced pass, so its gh reads wait until the live supply worker ends.
        return ['supply_skip_live'], 0
    bits = []
    forced = False
    if short >= SUPPLY_FORCE_PASSES:
        opened = sum_open_issues(repos, count_open or fetch_open_issue_count)
        if opened is None:
            bits.append('supply_force_unknown')
        elif opened == 0:
            bits.append('supply_force_no_issues')
        else:
            forced = True
            bits.append('supply_force=%d' % short)
            swept = (clear_blocked or clear_stale_blocked)(repos)
            bits.extend(swept)
            # How many stale blocked labels the sweep cleared, also when none (#1904).
            bits.append('unblock_cleared=%d' % sum(1 for b in swept if b.startswith('unblock=')))
    scan = config.get('issue_scan') or {}
    interval = float(scan.get('triage_interval_hours', _TRIAGE_INTERVAL_HOURS)) * 3600
    try:
        if not forced and now - float(state.get('work_order_supply_at')) < interval:
            return bits + ['supply_skip_recent'], 0
    except (TypeError, ValueError):
        pass
    if not admission.get('admitted') or not _issue_scan_has_slot(host, config, admission, extra_starts + reserved):
        return bits + ['supply_skip_no_seat'], 0
    builder = (scan.get('agent') or 'claude', scan.get('model') or '')
    chosen = choose_pick((pick_fn or pick_role)('architect-pm', avoid_family=_avoid_family(builder)), builder)
    if not chosen:
        return bits + ['supply_pick_blocked'], 0
    claimed = list(stale_claimed(repos)) if stale_claimed else []
    command = build_supply_command(config, repos, chosen[0], chosen[1], claimed, free)
    if command is None:
        return bits + ['supply_skip_root'], 0
    # PASS_HARD_END, not START_FINISH_BY: supply runs late in the pass, so an agy pick never fit 140 s (#1889).
    if not start_fits_pass(start_cost(command)):
        return bits + ['supply_budget=%d:%d' % (free, supply)], 0
    if start_worker(command) != 0:
        count_failed()
        return bits + ['supply_fail'], 0
    state['work_order_supply_at'] = now
    state['work_order_short_passes'] = 0
    if persist_state:
        persist_state()
    count_worker_started()
    if claimed:
        bits.append('supply_claimed=%s' % ','.join(_blocker_label(pair, repos[0]) for pair in claimed))
    return bits + ['supply_start=%d:%d' % (free, supply)], 1


def working_worker_count(workers, state):
    """Live workers minus the ones the idle seat pass flagged as finished or idle: only these fill a seat (#1904)."""
    idle = idle_seat_dispatches(state)
    return sum(1 for w in workers or [] if isinstance(w, dict) and worker_row_is_live(w) and w.get('dispatchId') not in idle)


STALE_CLAIM_HOLD_LABELS = frozenset(('blocked', 'deferred', 'tracking', 'owner'))


def stale_claimed_issues(state, now, workers, list_claimed, repos, pr_fetch=None):
    """(repo, number) of claimed issues with no live worker, past the start grace: the supply worker gets them (#1876).

    A claim with an open PR is not stale (its PR is in review or ship), and neither is one under a hold label (#1915).
    Without a readable PR list (``pr_fetch`` returns None) the claim is left out, as the restart loop does."""
    issue_pending = state.get('issue_scan_pending') or {}
    started_at = state.get('issue_scan_started_at') or {}
    out = []
    prs_by_repo = {}
    for repo in repos:
        for claimed in list_claimed(repo) or []:
            number = claimed.get('number')
            if not isinstance(number, int) or issue_has_live_dispatch(workers, number):
                continue
            if _claim_hold_labels(claimed):
                continue
            # A start this recent may not show in the inventory or the label yet (#1216); no time counts as stale (#1811).
            at = (started_at.get(repo) or {}).get(str(number))
            if number in issue_pending.get(repo, []) or (at is not None and now - float(at) < ISSUE_RESTART_GRACE_SECONDS):
                continue
            if pr_fetch is not None:
                if repo not in prs_by_repo:
                    prs_by_repo[repo] = pr_fetch(repo)
                prs = prs_by_repo[repo]
                if prs is None or open_pr_for_issue(prs, number):
                    continue
            out.append((repo, number))
    return out


def _claim_hold_labels(claimed):
    names = set()
    for entry in claimed.get('labels') or []:
        names.add(entry.get('name') if isinstance(entry, dict) else entry)
    return names & STALE_CLAIM_HOLD_LABELS


def forced_supply_due(state):
    """True when this pass, if it is short, is the forced supply pass (#1876)."""
    try:
        return int(state.get('work_order_short_passes') or 0) + 1 >= SUPPLY_FORCE_PASSES
    except (TypeError, ValueError):
        return False


def issue_scan_supply_first(
    config, state, now, workers, gate_check=None, admit_fn=None, start_worker=None, act=None, pick_fn=None,
    persist_state=None, count_open=None, list_blocked=None, ref_state=None, list_claimed=None, pr_fetch=None,
):
    """A due forced supply runs at the start of the pass, before babysit and the per issue work (#1904).

    Run late in a slow pass the start never fit PASS_HARD_END (supply_budget). The ready count is the last
    pass's. Once this ran, the issue scan of the same pass does not try supply again."""
    scan = config.get('issue_scan') or {}
    if not scan.get('enabled') or work_order_settings(config, now) is None or not forced_supply_due(state):
        return []
    if not (gate_check or default_issue_scan_gate)(config):
        return ['supply_first_gate']
    host = scan.get('host') or 'local'
    admission = (admit_fn or admit)(host, config, workers)
    if not admission.get('admitted'):
        return ['supply_first_refused']
    act = act or run_gh
    try:
        supply = int(state.get('work_order_last_supply') or 0)
    except (TypeError, ValueError):
        supply = 0
    bits, _used = work_order_try_supply(
        config, state, now, scan.get('repos') or [], supply, host, admission, 0, supply, workers,
        with_coordinator_handle(config, start_worker or default_issue_scan_start), pick_fn, persist_state, count_open,
        lambda rs: clear_stale_blocked(rs, list_blocked, ref_state, act),
        lambda rs: stale_claimed_issues(state, now, workers, list_claimed or fetch_claimed_issues, rs, pr_fetch or fetch_prs),
    )
    state['work_order_supply_first_at'] = now
    return ['supply_first'] + bits


def fetch_open_issue_count(repo, run=subprocess.run):
    """Open issues in the repo, read up to 1 since the gate only needs zero or not (#1876), or None when gh fails."""
    try:
        proc = run(['gh', 'issue', 'list', '--repo', repo, '--state', 'open', '--limit', '1', '--json', 'number'],
                   capture_output=True, text=True, timeout=30, check=True)
        return len(json.loads(proc.stdout))
    except (subprocess.SubprocessError, OSError, ValueError, TypeError):
        return None


def sum_open_issues(repos, count_open):
    """Open issues across the repos, or None when any count failed (a failure never reads as zero)."""
    total = 0
    for repo in repos:
        count = count_open(repo)
        if count is None:
            return None
        total += count
    return total


def fetch_blocked_issues(repo, run=subprocess.run):
    """Open issues labeled blocked, with the body and the native blockedBy, or None when gh fails."""
    try:
        proc = run(['gh', 'issue', 'list', '--repo', repo, '--label', 'blocked', '--state', 'open', '--limit', '100',
                    '--json', 'number,body,blockedBy'], capture_output=True, text=True, timeout=30, check=True)
        return json.loads(proc.stdout)
    except (subprocess.SubprocessError, OSError, ValueError, TypeError):
        return None


def fetch_ref_state(repo, number, run=subprocess.run):
    """OPEN or CLOSED for an issue or a PR (merged reads CLOSED), or None when gh fails. The REST issues route serves both."""
    try:
        proc = run(['gh', 'api', 'repos/%s/issues/%d' % (repo, number), '--jq', '.state'],
                   capture_output=True, text=True, timeout=30, check=False)
    except (subprocess.SubprocessError, OSError):
        return None
    state = proc.stdout.strip().upper() if proc.returncode == 0 else ''
    return state if state in ('OPEN', 'CLOSED') else None


def _blocked_by_line_unparseable(issue):
    """True when a Blocked by line has text but names no issue or PR."""
    for line in (issue.get('body') or '').splitlines():
        match = _BLOCKED_BY_LINE_RE.match(line) or _BLOCKED_BY_HEADING_RE.match(line.strip())
        if match and match.group(1).strip(' :') and not _ISSUE_REF_RE.search(match.group(1)):
            return True
    return False


def clear_stale_blocked(repos, list_blocked=None, ref_state=None, act=None):
    """Take blocked off each open issue whose Blocked by refs are all closed or merged, and comment which (#1876).

    Left alone: no Blocked by ref, a Blocked by line with no ref, an open or unreadable blocker, an open native blocker."""
    list_blocked = list_blocked or fetch_blocked_issues
    ref_state = ref_state or fetch_ref_state
    act = act or run_gh
    bits = []
    cache = {}
    for repo in repos:
        rows = list_blocked(repo)
        if rows is None:
            bits.append('unblock_list_failed')
            continue
        for row in rows:
            number = row.get('number')
            refs = issue_blocker_refs(row, repo)
            if not refs or _blocked_by_line_unparseable(row) or issue_scan_blocked(row):
                continue
            open_refs, unknown = issue_open_blockers(row, repo, ref_state, cache)
            if open_refs or unknown:
                continue
            # Comment only after the label came off, so a failing edit does not comment every pass.
            if act(['gh', 'issue', 'edit', str(number), '--repo', repo, '--remove-label', 'blocked']) != 0:
                bits.append('unblock_fail=%s' % number)
                continue
            names = ', '.join(_blocker_label(ref, repo) for ref in refs)
            act(['gh', 'issue', 'comment', str(number), '--repo', repo, '--body',
                 'fleet-watch removed the blocked label: every blocker is closed or merged (%s) (#1876).' % names])
            bits.append('unblock=%s' % number)
    return bits


def work_order_settings(config, now=None):
    """(min_active, target_workers) from the work_order block, or None when it is not configured (#1281).

    Given `now`, keep_target_until_go_live raises min_active to target_workers before go_live_date (#1655)."""
    block = config.get('work_order') if isinstance(config, dict) else None
    if not isinstance(block, dict):
        return None
    out = []
    for key, default in (('min_active', 3), ('target_workers', 8)):
        try:
            out.append(int(block.get(key, default)))
        except (TypeError, ValueError):
            out.append(default)
    if now is not None and work_order_keeps_target(config, now):
        out[0] = out[1]
    return tuple(out)


MAX_WORKERS_REASON = 'max_workers'


def work_order_max_workers(config):
    """work_order.max_workers, the fleet wide ceiling on live workers, or None when unset (#1957, owner 2026-11-26)."""
    block = config.get('work_order') if isinstance(config, dict) else None
    raw = block.get('max_workers') if isinstance(block, dict) else None
    if raw is None or isinstance(raw, bool):
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def fleet_live_count(workers):
    """Live workers in the inventory plus the workers this pass started, which the inventory snapshot cannot show."""
    return active_worker_count(workers) + (_PASS.worker_starts if _PASS is not None else 0)


def at_max_workers(config, workers, slack=0):
    """True when work_order.max_workers is set and the fleet holds that many live workers (plus `slack`)."""
    cap = work_order_max_workers(config)
    return cap is not None and fleet_live_count(workers) >= cap + slack


def work_order_keeps_target(config, now):
    """True when work_order.keep_target_until_go_live is on and today (Asia/Taipei) is before go_live_date (#1655).

    A missing or malformed go_live_date turns the switch off."""
    block = config.get('work_order') if isinstance(config, dict) else None
    if not isinstance(block, dict) or block.get('keep_target_until_go_live') is not True:
        return False
    go_live = str(config.get('go_live_date') or '')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', go_live):
        return False
    today = datetime.datetime.fromtimestamp(now, datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y-%m-%d')
    return today < go_live


WORK_ORDER_STATUS_INTERVAL = 3600


def work_order_status_notice(config, state, now, workers, started):
    """At most one line an hour while the switch holds the fleet at target: `work order: N of T live, started X` (#1655)."""
    if not started or not work_order_keeps_target(config, now):
        return None
    target = work_order_settings(config)[1]
    real = real_live_count()
    live = active_worker_count(workers) if real is None else real
    if live >= target:
        return None
    try:
        recent = now - float(state.get('work_order_status_at')) < WORK_ORDER_STATUS_INTERVAL
    except (TypeError, ValueError):
        recent = False
    if recent:
        return None
    state['work_order_status_at'] = now
    return 'work order: %d of %d live, started %d' % (live, target, started)


def worker_count_split(workers):
    """(live, unconfirmed) in progress dispatches, by the rule script/fleet-workers.py shares (#1942)."""
    return worker_count.tally(
        worker_count.bucket(worker_row_is_live(w), worker_liveness_verdict(w))
        for w in workers or [] if isinstance(w, dict)
    )


REAL_COUNT_TTL_SECONDS = 60
_REAL_COUNT_CACHE = {}


def real_live_count():
    """Workers really working, from `check-fleet-status.py --count` (a live agent with a recent screen change), or None
    when it cannot be read. Orca's own rows count a worker that sits idle or whose agent is gone (#2022), so every
    printed count uses this one. Admission and caps keep reading Orca's rows. FLEET_WATCH_REAL_COUNT_COMMAND replaces the command."""
    cached = _REAL_COUNT_CACHE.get('v')
    if cached and time.monotonic() - cached[0] < REAL_COUNT_TTL_SECONDS:
        return cached[1]
    command = shlex.split(os.environ.get('FLEET_WATCH_REAL_COUNT_COMMAND') or '') or [
        sys.executable, str(Path(__file__).with_name('check-fleet-status.py')), '--count']
    value = None
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=110, check=False)
        text = proc.stdout.strip() if isinstance(proc.stdout, str) else ''
        if proc.returncode == 0 and text.isdigit():
            value = int(text)
    except (subprocess.SubprocessError, OSError):
        pass
    _REAL_COUNT_CACHE['v'] = (time.monotonic(), value)
    return value


def active_worker_count(workers):
    return sum(1 for w in workers or [] if isinstance(w, dict) and worker_row_is_live(w))


def _is_building(worker):
    title = str(worker.get('_task_title') or worker.get('title') or '')
    return worker_row_is_live(worker) and not _worker_titled_verifier(worker) and 'triage' not in title


def work_order_no_work_notice(config, state, now, workers, ready_count):
    """One line a day, before 19:00 Asia/Taipei, when nothing is building and no ready issue is left (#1281)."""
    if work_order_settings(config) is None or ready_count:
        return None
    if any(isinstance(w, dict) and _is_building(w) for w in workers or []):
        return None
    local = datetime.datetime.fromtimestamp(now, datetime.timezone(datetime.timedelta(hours=8)))
    day = local.strftime('%Y-%m-%d')
    if local.hour >= 19 or state.get('work_order_no_work_day') == day:
        return None
    state['work_order_no_work_day'] = day
    return 'work order: no work left, start the staging deploy and regression now'


def issue_scan_try_triage(
    config, state, now, repos, host, admission, extra_starts, workers,
    start_worker, list_backlog=None, pick_fn=None, persist_state=None, notices=None,
):
    """Idle seats and no ready issue: start one architect-pm triage worker per repo, at most once per interval.

    With work_order.min_active set and fewer workers active than that, the interval is skipped and the
    coordinator gets one status line (#1281)."""
    log_bits = []
    scan = config.get('issue_scan') or {}
    order = work_order_settings(config, now)
    active = active_worker_count(workers)
    urgent = order is not None and active < order[0]
    keeping = work_order_keeps_target(config, now)
    interval = float(scan.get('triage_interval_hours', _TRIAGE_INTERVAL_HOURS)) * 3600
    last_starts = state.setdefault('issue_scan_triage_at', {})
    last_seen = state.setdefault('issue_scan_triage_seen', {})
    used = 0
    for repo in repos:
        if not _issue_scan_has_slot(host, config, admission, extra_starts + used):
            log_bits.append('triage_skip_no_seat')
            break
        if at_max_workers(config, workers):
            log_bits.append('triage_max_workers')
            break
        try:
            recent = now - float(last_starts.get(repo)) < interval
        except (TypeError, ValueError):
            recent = False
        if recent and not urgent:
            log_bits.append('triage_skip_recent')
            continue
        backlog = (list_backlog or fetch_triage_backlog)(repo)
        if backlog is None:
            log_bits.append('triage_list_failed')
            continue
        if not backlog:
            log_bits.append('triage_skip_no_backlog')
            continue
        if triage_backlog_unchanged(backlog, last_seen.get(repo)):
            log_bits.append('triage_skip_unchanged')
            continue
        builder = (scan.get('agent') or 'claude', scan.get('model') or '')
        chosen = choose_pick((pick_fn or pick_role)('architect-pm', avoid_family=_avoid_family(builder)), builder)
        if not chosen:
            log_bits.append('triage_pick_blocked')
            continue
        command = build_triage_command(config, repo, chosen[0], chosen[1])
        if command is None:
            log_bits.append('triage_skip_root')
            continue
        if live_start_title(command, workers):
            log_bits.append('triage_skip_live')
            continue
        if not start_allowed(start_cost(command)):
            log_bits.append('triage_budget=%s' % repo)
            continue
        if start_worker(command) == 0:
            last_starts[repo] = now
            if isinstance(backlog, dict):
                last_seen[repo] = {'at': now, 'issues': sorted(backlog)}
            used += 1
            log_bits.append('triage_start=%d' % (len(backlog) if isinstance(backlog, dict) else backlog))
            if urgent and not keeping and notices is not None:
                notices.append('work order: %d active, grill backlog' % active)
            count_worker_started()
        else:
            log_bits.append('triage_fail')
            count_failed()
        if persist_state:
            persist_state()
    return log_bits, used


USAGE_GATE_REFUSALS = []  # refusals seen this pass, drained by usage_gate_notices
USAGE_GATE_CALLS = [0]  # gate calls this pass


def usage_gate_settings():
    """(minutes of refusals, headroom points) before the coordinator hears of it, from usage-gate.config.json."""
    path = os.environ.get('USAGE_GATE_CONFIG') or str(Path(__file__).with_name('usage-gate.config.json'))
    try:
        data = json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        data = {}
    return float(data.get('notice_after_min', 30)), float(data.get('notice_headroom_points', 20))


def record_gate_refusal(provider, verdict, reason, age, headroom):
    """One fleet-watch.log line per refused provider per pass, and a record for the notice."""
    reason = re.sub(r'\s+', ' ', str(reason or 'unknown')).strip()
    entry = {'provider': provider, 'verdict': verdict, 'reason': reason, 'age': age, 'headroom': headroom}
    if any(all(seen[k] == entry[k] for k in ('provider', 'verdict', 'reason')) for seen in USAGE_GATE_REFUSALS):
        return
    USAGE_GATE_REFUSALS.append(entry)
    log_fleet_watch('usage_gate_refused provider=%s verdict=%s reason="%s" reading_age_min=%s' % (
        provider, verdict, reason, '-' if age is None else age))


def usage_gate_notices(state, now):
    """One notice when refusals last the configured minutes while headroom is over the configured points."""
    after_min, over = usage_gate_settings()
    refusals, calls = list(USAGE_GATE_REFUSALS), USAGE_GATE_CALLS[0]
    USAGE_GATE_REFUSALS.clear()
    USAGE_GATE_CALLS[0] = 0
    active = [r for r in refusals if isinstance(r['headroom'], (int, float)) and r['headroom'] > over]
    if not active:
        if calls:
            state.pop('usage_gate_refusal', None)
        return []
    entry = state.setdefault('usage_gate_refusal', {'since': now, 'notified': False})
    if entry['notified'] or now - entry['since'] < after_min * 60:
        return []
    entry['notified'] = True
    first = active[0]
    return [Urgent('usage gate has refused starts for %d minutes with %.0f points of headroom: %s %s, %s' % (
        (now - entry['since']) / 60, first['headroom'], first['provider'], first['verdict'], first['reason']))]


def default_issue_scan_gate(config, run=subprocess.run):
    scan = config.get('issue_scan') or {}
    agent = scan.get('agent') or 'claude'
    command = [sys.executable, str(Path(__file__).with_name('usage-gate.py')), 'check', '--provider', agent, '--auto']
    model = scan.get('model')
    if model:
        command += ['--model', model]
    USAGE_GATE_CALLS[0] += 1
    try:
        proc = run(command, capture_output=True, text=True, timeout=60)
    except (subprocess.SubprocessError, OSError):
        return False
    if proc.returncode == 0:
        return True
    try:
        detail = json.loads(proc.stdout or '{}')
    except (ValueError, TypeError):
        detail = {}
    detail = detail if isinstance(detail, dict) else {}
    record_gate_refusal(detail.get('provider') or agent, detail.get('verdict') or 'error',
                        detail.get('reason') or 'gate exit %s' % proc.returncode,
                        detail.get('reading_age_min'), detail.get('headroom'))
    return False


def default_issue_scan_start(command, run=subprocess.run):
    try:
        done = run(command, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return BabysitStartResult(1, 'timed out after 180s')
    except (subprocess.SubprocessError, OSError) as exc:
        return BabysitStartResult(1, _start_reason(str(exc)))
    return BabysitStartResult(
        done.returncode,
        _start_reason(done.stderr, getattr(done, 'stdout', '') or ''),
        dispatch_id_from_text(getattr(done, 'stdout', None) or ''),
        terminal_from_text(getattr(done, 'stdout', None) or ''),
    )


def _issue_scan_has_slot(host, config, admission, extra_starts):
    cap = config.get('host_caps', {}).get(host, 4)
    occupied = admission.get('occupied')
    if occupied is None:
        occupied = 0
    return extra_starts + occupied < cap


_HEAD_CHECK_NAMES = ('checks', 'script-tests', 'script tests', 'shellcheck')
_BUILDER_LINE_RE = re.compile(
    r'^Builder: agent=([A-Za-z0-9._-]+) model=([A-Za-z0-9._:-]+)\s*$'
)
# "Builder: claude/sonnet (host)", the form some builders write instead (#1201).
_BUILDER_SLASH_RE = re.compile(r'^Builder:\s*([A-Za-z0-9._-]+)/([A-Za-z0-9._:-]+)(?:\s.*)?$')
_AGENT_ALIASES = {'agy': 'antigravity'}
BABYSIT_PASS_CAP = 2


def _is_head_check(check):
    name = (check.get('context') or check.get('name') or '').lower()
    if not name or name == 'review':
        return False
    if 'head-checks' in name:
        return True
    return name in _HEAD_CHECK_NAMES


def _check_conclusion(check):
    return (check.get('conclusion') or check.get('state') or '').upper()


def _check_status(check):
    return (check.get('status') or '').upper()


def head_checks_status(pr):
    """SUCCESS, FAILURE, or None when head-checks has not settled for this head."""
    head = pr.get('headRefOid') or ''
    kind = newest_checks_kind(pr.get('comments'), head)
    if kind == 'FAIL':
        return 'FAILURE'
    if kind == 'PASS':
        return 'SUCCESS'
    relevant = [
        check for check in (pr.get('statusCheckRollup') or [])
        if isinstance(check, dict) and _is_head_check(check)
    ]
    if not relevant:
        return None
    pending = False
    for check in relevant:
        conclusion = _check_conclusion(check)
        status = _check_status(check)
        if conclusion in ('FAILURE', 'ERROR', 'TIMED_OUT'):
            return 'FAILURE'
        if conclusion == 'SUCCESS' and status in ('', 'COMPLETED'):
            continue
        pending = True
    if pending:
        return None
    return 'SUCCESS'


_VERDICT_FOR_HEAD_RE = re.compile(
    r'^Verdict: (?:PASS\+NOTES|PASS|FAIL) head=(?P<head>[0-9a-f]{40})\b'
)


def verdict_posted_for_head(pr):
    """True when a Verdict line names this head, including an agent= model= suffix."""
    head = pr.get('headRefOid') or ''
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        return False
    for comment in pr.get('comments') or []:
        if not isinstance(comment, dict):
            continue
        match = _VERDICT_FOR_HEAD_RE.match(_receipt_first_line(comment.get('body')))
        if match and match.group('head') == head:
            return True
    return False


def review_passed_at_head(pr):
    """True when the newest unedited Review receipt for this head is PASS and Review has not failed."""
    head = pr.get('headRefOid') or ''
    if not re.fullmatch(r'[0-9a-f]{40}', head) or review_failed_at_head(pr):
        return False
    valid_comments = [
        c for c in (pr.get('comments') or [])
        if isinstance(c, dict)
        and not (c.get('includesCreatedEdit') or c.get('isMinimized') or c.get('edited') or c.get('minimized'))
    ]
    return rs.newest_receipt_kind(valid_comments, 'Review', head) == 'PASS'


def cold_review_passed_at_head(pr):
    """True when review_passed_at_head holds and the PASS names a real model. Review: PASS model=none is not a cold review (#1730 follow-up)."""
    return review_passed_at_head(pr) and rs.cold_review_passed(pr.get('comments'), pr.get('headRefOid') or '')


def _pr_has_review_lane(pr):
    """True when this PR already carries a Review receipt comment or a review status check."""
    for comment in pr.get('comments') or []:
        if not isinstance(comment, dict):
            continue
        match = rs.HEAD_RECEIPT_RE.match(_receipt_first_line(comment.get('body')))
        if match and match.group('label') == 'Review':
            return True
    for check in pr.get('statusCheckRollup') or []:
        if isinstance(check, dict) and (check.get('context') or check.get('name') or '').lower() == 'review':
            return True
    return False


def fetch_actions_runners(repo):
    """Runner list for a repo from the Actions API, or None when the call fails."""
    try:
        proc = subprocess.run(
            ['gh', 'api', 'repos/%s/actions/runners' % repo],
            capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def has_online_review_runner(data):
    """True when the runner list holds an online runner carrying the review label."""
    runners = data.get('runners') if isinstance(data, dict) else None
    if not isinstance(runners, list):
        raise ValueError('no runner list')
    return any(
        isinstance(r, dict) and r.get('status') == 'online'
        and any(isinstance(l, dict) and l.get('name') == 'review' for l in r.get('labels') or [])
        for r in runners
    )


def prior_verdict_fail(pr):
    """(verified_head, findings_body) from the newest prior Verdict: FAIL on an earlier head, or None."""
    head = pr.get('headRefOid') or ''
    comments = sorted(
        [(idx, c) for idx, c in enumerate(pr.get('comments') or []) if isinstance(c, dict)],
        key=lambda pair: (pair[1].get('createdAt') or '', pair[0]), reverse=True,
    )
    for _, comment in comments:
        body = comment.get('body') or ''
        first = _receipt_first_line(body)
        match = _VERDICT_FOR_HEAD_RE.match(first)
        if not match:
            continue
        verdict_head = match.group('head')
        if verdict_head == head:
            continue
        if first.startswith('Verdict: FAIL '):
            rest = '\n'.join(body.splitlines()[1:]).strip()
            return verdict_head, rest[:4000]
        return None
    return None


def pr_file_paths(pr):
    paths = []
    for item in pr.get('files') or []:
        if isinstance(item, str) and item:
            paths.append(item)
        elif isinstance(item, dict):
            path = item.get('path') or item.get('filename') or ''
            if path:
                paths.append(path)
    return paths


def pr_owner_only_reason(pr, run=subprocess.run, repo_root=None):
    """Refuse text from check_owner_only_paths or missing Owner-approved receipt, None when clear, or 'error'."""
    paths = pr_file_paths(pr)
    if not paths:
        return None
    script = (
        'files=$BABYSIT_FILES\n'
        'refuse() { printf \'%s\\n\' "$*" >&2; exit 2; }\n'
        'die() { printf \'%s\\n\' "$*" >&2; exit 3; }\n'
        'field() { printf \'\\n\'; }\n'
        'verdict_carry() { return 1; }\n'
        'head=0000000000000000000000000000000000000000\n'
        'diff=\n'
        'info=\'{"comments":[]}\'\n'
        'source "$BABYSIT_PROTECTED"\n'
        'check_owner_only_paths\n'
    )
    env = os.environ.copy()
    env['BABYSIT_FILES'] = json.dumps(paths)
    env['BABYSIT_PROTECTED'] = str(Path(__file__).resolve().parent / 'lib' / 'protected-paths.sh')
    try:
        proc = run(
            ['bash', '-c', script],
            capture_output=True, text=True, timeout=20, env=env, check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return 'error'
    if proc.returncode == 2:
        message = (proc.stderr or proc.stdout or '').strip()
        return message or 'owner-only path'
    if proc.returncode != 0:
        return 'error'
    head = (pr or {}).get('headRefOid') or ''
    base = (pr or {}).get('baseRefOid') or ''
    if (isinstance(repo_root, str) and repo_root and os.path.exists(os.path.join(repo_root, '.git'))
            and re.fullmatch(r'[0-9a-f]{40}', head) and re.fullmatch(r'[0-9a-f]{40}', base)):
        receipt_script = (
            'cd "$BABYSIT_ROOT" || exit 0\n'
            'files=$BABYSIT_FILES\n'
            'head=$BABYSIT_HEAD\n'
            'base=$BABYSIT_BASE\n'
            'pr=$BABYSIT_PR\n'
            'info=$(printf \'{"baseRefOid":"%s","comments":[]}\' "$base")\n'
            'field() { jq -r "$1" <<<"$info"; }\n'
            'refuse() { printf \'%s\\n\' "$*" >&2; exit 2; }\n'
            'die() { exit 0; }\n'
            'verdict_carry() { return 1; }\n'
            'source "$BABYSIT_PROTECTED"\n'
            'ensure_commit_in_store "$head" || exit 0\n'
            'ensure_commit_in_store "$base" || exit 0\n'
            'diff=$(git diff "$base..$head" -- docs/intent 2>/dev/null || true)\n'
            'intent_acceptance_receipt\n'
        )
        env['BABYSIT_ROOT'] = repo_root
        env['BABYSIT_HEAD'] = head
        env['BABYSIT_BASE'] = base
        env['BABYSIT_PR'] = str((pr or {}).get('number') or '')
        try:
            rproc = run(
                ['bash', '-c', receipt_script],
                capture_output=True, text=True, timeout=20, env=env, check=False,
            )
            if rproc.returncode == 2:
                message = (rproc.stderr or rproc.stdout or '').strip()
                return message or 'owner-only path'
        except (subprocess.SubprocessError, OSError):
            pass
    return None


def github_repo_from_url(url):
    """owner/name from a GitHub remote URL, or None."""
    text = (url or '').strip()
    if text.endswith('/'):
        text = text[:-1]
    rest = None
    for prefix in (
        'git@github.com:',
        'ssh://git@github.com/',
        'git://github.com/',
        'https://github.com/',
        'http://github.com/',
    ):
        if text.startswith(prefix):
            rest = text[len(prefix):]
            break
    if rest is None:
        return None
    if rest.endswith('.git'):
        rest = rest[:-4]
    owner, sep, name = rest.partition('/')
    if not sep or not owner or not name or '/' in name:
        return None
    return owner + '/' + name


def github_repo_from_origin(path, run=None):
    """owner/name from git remote.origin.url at path, or None when it cannot be read."""
    if not path or not os.path.isdir(path):
        return None
    if run is None:
        run = subprocess.run
    try:
        proc = run(
            ['git', '-C', path, 'config', '--get', 'remote.origin.url'],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if proc.returncode != 0:
        return None
    return github_repo_from_url((proc.stdout or '').strip())


def iter_repo_root_paths(value):
    """Checkout paths from a list, a dict of paths, or one path string."""
    if isinstance(value, str) and value.strip():
        yield value.strip()
        return
    if isinstance(value, list):
        for item in value:
            yield from iter_repo_root_paths(item)
        return
    if isinstance(value, dict):
        for item in value.values():
            yield from iter_repo_root_paths(item)


def repos_from_roots(value, origin_of=None):
    """(owner/name list, owner/name -> path) from each repo_roots checkout."""
    origin_of = origin_of or github_repo_from_origin
    repos = []
    mapping = {}
    for path in iter_repo_root_paths(value):
        repo = origin_of(path)
        if not repo or repo in mapping:
            continue
        mapping[repo] = path
        repos.append(repo)
    return repos, mapping


def worker_checkout_path(worker):
    """Filesystem path of a worker checkout. A worktree id may be ``id::path``."""
    raw = worker_worktree_selector(worker)
    if not isinstance(raw, str) or not raw:
        workspace = ((worker or {}).get('projection') or {}).get('workspace')
        raw = workspace.get('path') if isinstance(workspace, dict) else ''
    if not isinstance(raw, str) or not raw:
        return ''
    if '::' in raw:
        raw = raw.split('::', 1)[1]
    return raw


def repo_for_worker(worker, config, origin_of=None):
    """GitHub repo of this worker: its checkout origin, else the longest matching repo_roots path."""
    path = worker_checkout_path(worker)
    if path:
        repo = (origin_of or github_repo_from_origin)(path)
        if repo:
            return repo
    roots = {}
    for block_name in ('issue_scan', 'babysit'):
        block = (config or {}).get(block_name) or {}
        candidate = block.get('repo_roots') or {}
        if isinstance(candidate, dict):
            roots.update(candidate)
    best_repo = None
    best_len = -1
    for repo, root in roots.items():
        if not isinstance(repo, str) or not isinstance(root, str) or not root:
            continue
        root_norm = root.rstrip('/')
        if path and (path == root_norm or path.startswith(root_norm + '/')):
            if len(root_norm) > best_len:
                best_repo = repo
                best_len = len(root_norm)
    return best_repo


# The reply recorder's run. wrap-up creates it. It is never the coordinator.
# script/fleet-watch-record.py uses this same objective string.
RECORDER_SCRATCH_OBJECTIVE = 'fleet-watch recorder scratch'


def select_coordinator_run(runs):
    """Newest run that has a coordinator terminal. Equal timestamps keep the earlier row.

    The recorder scratch run is skipped. A fresh shape check must not become the coordinator.
    """
    best = None
    best_rank = None
    for index, run in enumerate(runs or []):
        if not isinstance(run, dict):
            continue
        if (run.get('objective') or '').strip() == RECORDER_SCRATCH_OBJECTIVE:
            continue
        handle = run.get('coordinator_handle')
        rid = run.get('id')
        if not isinstance(handle, str) or not handle.strip():
            continue
        if not isinstance(rid, str) or not rid.strip():
            continue
        stamp = run.get('updated_at')
        stamp = stamp if isinstance(stamp, str) else ''
        rank = (stamp, -index)
        if best_rank is None or rank > best_rank:
            best_rank = rank
            best = run
    return best


def coordinator_terminal_from_show(shown, fallback_handle):
    """Coordinator terminal from a run-show result, else the run-list handle."""
    run = None
    if isinstance(shown, dict):
        nested = shown.get('run')
        run = nested if isinstance(nested, dict) else shown
    handle = run.get('coordinator_handle') if isinstance(run, dict) else None
    if isinstance(handle, str) and handle.strip():
        return handle.strip()
    if isinstance(fallback_handle, str) and fallback_handle.strip():
        return fallback_handle.strip()
    return ''


def read_coordinator_run():
    """('run', {id, terminal, waiter_pattern}), ('no-run', None), or ('unread', None).

    unread means Orca did not answer. That is not an empty run list, so the caller
    keeps the loaded file. A successful answer with no coordinator terminal is no-run.
    """
    try:
        runs = []
        for page in list_pages('orchestration', 'run-list', '--full'):
            for run in page.get('runs') or []:
                if isinstance(run, dict):
                    runs.append(run)
    except (OrcaReadError, subprocess.SubprocessError, OSError, TypeError, ValueError, KeyError):
        return 'unread', None
    chosen = select_coordinator_run(runs)
    if chosen is None:
        return 'no-run', None
    rid = chosen['id'].strip()
    terminal = chosen['coordinator_handle'].strip()
    try:
        shown = rpc('orchestration', 'run-show', '--id', rid, '--full')
    except (OrcaReadError, subprocess.SubprocessError, OSError, TypeError, ValueError, KeyError):
        shown = None
    terminal = coordinator_terminal_from_show(shown, terminal) or terminal
    if isinstance(shown, dict):
        nested = shown.get('run') if isinstance(shown.get('run'), dict) else None
        shown_id = nested.get('id') if isinstance(nested, dict) else None
        if isinstance(shown_id, str) and shown_id.strip():
            rid = shown_id.strip()
    return 'run', {
        'id': rid,
        'terminal': terminal,
        'waiter_pattern': 'orchestration check --run %s' % rid,
    }


def _arm_fault_repo(config, key, armed):
    block = config.get(key)
    if not isinstance(block, dict) or not armed(block):
        return
    block.pop('issue_repo', None)
    block['issue_repo'] = FAULT_REPO


def bind_pass_config(config, read_run=None, origin_of=None):
    """Fill the pass from Orca and git. File runs, label_repo, issue_repo and issue_scan.enabled are ignored.

    Returns 'run', 'no-run', or 'unread'. unread leaves config unchanged.
    """
    if not isinstance(config, dict):
        return 'unread'
    status, run = (read_run or read_coordinator_run)()
    if status != 'run':
        return status
    config['runs'] = [{
        'id': run['id'],
        'terminal': run['terminal'],
        'waiter_pattern': run.get('waiter_pattern') or ('orchestration check --run %s' % run['id']),
    }]
    repos, mapping = repos_from_roots(config.get('repo_roots'), origin_of=origin_of)
    scan = config.get('issue_scan')
    if not isinstance(scan, dict):
        scan = {}
    scan.pop('enabled', None)
    scan['enabled'] = True
    scan['run'] = run['id']
    scan['from_terminal'] = run['terminal']
    scan['repos'] = list(repos)
    scan['pr_repos'] = list(repos)
    scan['repo_roots'] = mapping
    config['issue_scan'] = scan
    babysit = config.get('babysit')
    if not isinstance(babysit, dict):
        babysit = {}
    babysit['run'] = run['id']
    babysit['from_terminal'] = run['terminal']
    babysit['repos'] = list(repos)
    babysit['repo_roots'] = dict(mapping)
    config['babysit'] = babysit
    watch = config.get('pr_watch')
    if not isinstance(watch, dict):
        watch = {}
    watch['repos'] = list(repos)
    config['pr_watch'] = watch
    stall = config.get('worker_stall')
    if not isinstance(stall, dict):
        stall = {}
    stall.pop('label_repo', None)
    stall['from_system'] = True
    config['worker_stall'] = stall
    _arm_fault_repo(
        config, 'backup',
        lambda block: isinstance(block.get('stamp'), str) and bool(block.get('stamp').strip()),
    )
    _arm_fault_repo(
        config, 'heavy_gate',
        lambda block: (
            (isinstance(block.get('hosts'), dict) and bool(block.get('hosts')))
            or (isinstance(block.get('slot_roots'), dict) and bool(block.get('slot_roots')))
        ),
    )
    _arm_fault_repo(
        config, 'wrap_up',
        lambda block: isinstance(block.get('hosts'), dict) and bool(block.get('hosts')),
    )
    log_fleet_watch('coordinator run %s terminal %s' % (run['id'], run['terminal']))
    return 'run'


def config_runs(config):
    runs = config.get('runs') if isinstance(config, dict) else None
    if not isinstance(runs, list) or not runs:
        return None
    return runs


def coordinator_config_path():
    override = os.environ.get('FLEET_WATCH_COORDINATOR_CONFIG')
    if override:
        return Path(override)
    return Path.home() / '.claude' / 'state' / 'fleet-watch-elon.json'


_STUB_FILL_KEYS = ('local_host', 'host_caps', 'host_load_ceilings', 'worker_placement')


def _read_json_object(path):
    try:
        loaded = json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    return loaded if isinstance(loaded, dict) else None


def _fill_missing_stub_keys(dest, source):
    if not isinstance(dest, dict) or not isinstance(source, dict):
        return
    for key in _STUB_FILL_KEYS:
        if key not in dest and key in source:
            dest[key] = source[key]


def _host_caps_present(config):
    caps = config.get('host_caps') if isinstance(config, dict) else None
    return isinstance(caps, dict) and bool(caps)


def resolve_pass_config(config, config_path):
    """Use the coordinator file when the scheduled stub has no runs.

    Fill local_host, host_caps, host_load_ceilings and worker_placement from the
    stub when the pass config lacks them, whichever file was --config.
    """
    stub_path = Path.home() / '.config' / 'fleet-watch' / 'config.json'
    try:
        given_is_stub = Path(config_path).resolve() == stub_path.resolve()
    except OSError:
        given_is_stub = False
    adopted = None
    pass_config = config
    if isinstance(config, dict) and not config_runs(config) and given_is_stub:
        loaded = _read_json_object(coordinator_config_path())
        if loaded is not None and config_runs(loaded):
            pass_config = loaded
            adopted = coordinator_config_path()
    source = config if given_is_stub and isinstance(config, dict) else _read_json_object(stub_path)
    _fill_missing_stub_keys(pass_config, source)
    if isinstance(pass_config, dict) and not _host_caps_present(pass_config):
        log_fleet_watch('pass_config_no_host_caps')
    return pass_config, adopted


def current_coordinator_handle(run_id):
    """Coordinator terminal Orca holds for this run now, or None when it cannot be read.

    The handle saved in the coordinator file goes stale when the coordinator terminal restarts.
    """
    try:
        for page in list_pages('orchestration', 'run-list', '--full'):
            for run in page['runs']:
                if isinstance(run, dict) and run.get('id') == run_id:
                    handle = run.get('coordinator_handle')
                    if isinstance(handle, str) and handle.strip():
                        return handle.strip()
                    return None
    except Exception:
        return None
    return None


def apply_active_run(config, pick=None, resolve_handle=None):
    """Copy runs[0] onto issue_scan, and refresh agent and model from the role pick.

    The sender terminal is the run's current coordinator handle; the saved one is the fallback.
    """
    scan = config.get('issue_scan') if isinstance(config, dict) else None
    runs = config_runs(config)
    if not isinstance(scan, dict) or not runs or not isinstance(runs[0], dict):
        return
    active = runs[0]
    run_id = active.get('id')
    terminal = active.get('terminal')
    if isinstance(run_id, str) and run_id.strip():
        scan['run'] = run_id.strip()
    if isinstance(terminal, str) and terminal.strip():
        scan['from_terminal'] = terminal.strip()
    if isinstance(run_id, str) and run_id.strip():
        current = (resolve_handle or current_coordinator_handle)(run_id.strip())
        if current:
            scan['from_terminal'] = current
            active['terminal'] = current
            if isinstance(config.get('babysit'), dict) and config['babysit'].get('from_terminal'):
                config['babysit']['from_terminal'] = current
    if not scan.get('enabled'):
        return
    data = pick('fullstack-dev') if pick else pick_role('fullstack-dev')
    chosen = choose_pick(data)
    if chosen:
        scan['agent'], scan['model'] = chosen[0], chosen[1]
        scan.pop('rework_agent', None)
        scan.pop('rework_model', None)


def babysit_repos(config):
    block = config.get('babysit') or {}
    configured = block.get('repos')
    if configured:
        return [repo for repo in configured if isinstance(repo, str) and repo]
    seen = []
    scan = config.get('issue_scan') or {}
    watch = config.get('pr_watch') or {}
    for repo in list(scan.get('pr_repos') or []) + list(watch.get('repos') or []):
        if isinstance(repo, str) and repo and repo not in seen:
            seen.append(repo)
    if seen:
        return seen
    configured_scan = [repo for repo in (scan.get('repos') or []) if isinstance(repo, str) and repo]
    if configured_scan:
        return configured_scan
    # --babysit-only runs before bind_pass_config, so read the repos from the checkouts (#1394).
    return repos_from_roots(block.get('repo_roots') or scan.get('repo_roots') or config.get('repo_roots'))[0]


def babysit_settings(config):
    scan = config.get('issue_scan') or {}
    block = config.get('babysit') or {}
    startup = (block.get('startup') or scan.get('startup') or '').strip()
    if not startup:
        startup = str(Path(__file__).with_name('worker-startup.sh'))
    run_id = (block.get('run') or scan.get('run') or '').strip()
    from_terminal = (block.get('from_terminal') or scan.get('from_terminal') or '').strip()
    roots = block.get('repo_roots') or scan.get('repo_roots') or {}
    if not isinstance(roots, dict) or not roots:
        roots = repos_from_roots(config.get('repo_roots'))[1]
    return startup, run_id, from_terminal, roots


START_FINISH_BY = 140.0  # a start may begin only if it can end before this many seconds into the pass (#1820); not the issue start (#2009)
START_COST_AGY = 105.0  # an antigravity start that keeps worker-startup's 60 s sign in screen wait
START_COST_OTHER = 45.0  # any other start
START_TAIL = 25.0  # work after the last start (audit, issue scan, deliver, save, process exit) took 10 to 22 s in the #1820 live check
_PASS_BEGAN = None


def begin_pass_clock(now=None):
    """Start the start budget clock. main() calls it; with no call (tests, direct use) there is no budget."""
    global _PASS_BEGAN
    _PASS_BEGAN = time.time() if now is None else now
    del _DEADLINE_SKIPPED[:]


def end_pass_clock():
    global _PASS_BEGAN
    _PASS_BEGAN = None


def agent_start_cost(agent):
    return START_COST_AGY if _AGENT_ALIASES.get(agent, agent) == 'antigravity' else START_COST_OTHER


def start_cost(command):
    """Cost of a start command by its --agent. A command with no --agent (the ship script) is the cheap kind."""
    if isinstance(command, (list, tuple)) and '--agent' in command:
        index = command.index('--agent') + 1
        if index < len(command):
            return agent_start_cost(command[index])
    return START_COST_OTHER


PASS_HARD_END = 250.0  # the pass stops new work here, ahead of the automation's 280 s precheck timeout (#1838)
_DEADLINE_SKIPPED = []


def pass_deadline_reached():
    """True once the pass is PASS_HARD_END seconds old. Checked cooperatively at phase, babysit row and scan row
    boundaries, so a worker start already begun always finishes. With no clock (tests, direct use) never true."""
    return _PASS_BEGAN is not None and time.time() - _PASS_BEGAN >= PASS_HARD_END


def deadline_hit(log_bits, bit):
    """True at the deadline, and logs `bit` once."""
    if not pass_deadline_reached():
        return False
    if bit not in log_bits:
        log_bits.append(bit)
    return True


def run_phase(name, fn, skipped):
    """Run one phase of main(), or return `skipped` once the deadline passed and record the phase as skipped."""
    if pass_deadline_reached():
        _DEADLINE_SKIPPED.append(name)
        return skipped
    pass_phase(name)
    return fn()


def pass_deadline_line():
    return 'pass deadline %ds: skipped %s' % (PASS_HARD_END, ','.join(_DEADLINE_SKIPPED)) if _DEADLINE_SKIPPED else ''


def start_fits_pass(cost):
    """True while elapsed + cost + START_TAIL fits PASS_HARD_END, so a start and the work after it end by the hard
    end (#1820). Without the tail, two starts of about 100 s ended passes at 252 and 258 s. Verifier and fixer
    starts skip START_FINISH_BY (#1838) but not this. With no clock (tests, direct use) True."""
    return _PASS_BEGAN is None or time.time() - _PASS_BEGAN + cost + START_TAIL <= PASS_HARD_END


def start_allowed(cost):
    """True while elapsed + cost fits START_FINISH_BY. Each start site calls it once, after it picks the agent
    and before it writes any state. with_coordinator_handle does not call it: a start a site let through runs."""
    if _PASS_BEGAN is None:
        return True
    return time.time() - _PASS_BEGAN + cost <= START_FINISH_BY


def with_coordinator_handle(config, start):
    """Wrap a worker start so worker-startup sees the coordinator's ORCA_TERMINAL_HANDLE.

    The scheduled run has no coordinator terminal in its environment, and worker-startup refuses with
    "need --from" without one (#1640, #1655). The command stays free of --from (#1204): hand it over as the env."""
    handle = babysit_settings(config)[2]

    def start_with_handle(command):
        set_handle = bool(handle) and not os.environ.get('ORCA_TERMINAL_HANDLE')
        if set_handle:
            os.environ['ORCA_TERMINAL_HANDLE'] = handle
        began = time.time()
        try:
            return start(command)
        finally:
            if _PASS is not None:
                _PASS.starts.append(time.time() - began)
            if set_handle:
                os.environ.pop('ORCA_TERMINAL_HANDLE', None)
    return start_with_handle


def babysit_cap(config):
    raw = (config.get('babysit') or {}).get('per_pass_cap', BABYSIT_PASS_CAP)
    try:
        cap = int(raw)
    except (TypeError, ValueError):
        cap = BABYSIT_PASS_CAP
    return cap if cap > 0 else 0


def babysit_dispatch_repos(config):
    """Repos that have a checkout root and a coordinator run to start from."""
    _startup, run_id, from_terminal, roots = babysit_settings(config)
    if not run_id or not from_terminal:
        return []
    ready = []
    for repo in babysit_repos(config):
        root = roots.get(repo)
        if isinstance(root, str) and root:
            ready.append(repo)
    return ready


def babysit_record(state, repo, number):
    return ((state.get('babysit') or {}).get(repo) or {}).get(str(number)) or {}


def babysit_mark(state, repo, number, head, action):
    state.setdefault('babysit', {}).setdefault(repo, {})[str(number)] = {
        'head': head,
        'action': action,
    }


STARTUP_FAIL_DETAILS = ('agent_readiness', 'dispatch_input', 'process_exited')
STARTUP_FAIL_RE = re.compile(r'terminal_exited|agent_not_in_foreground|agent_readiness|dispatch_input')


def startup_failure_text(text):
    return bool(STARTUP_FAIL_RE.search(str(text or '')))


def worker_startup_failed(worker):
    """True when a failed dispatch died while the agent was starting (readiness or the first input)."""
    w = worker or {}
    if worker_inventory_status(w) != 'failed':
        return False
    proj = w.get('projection') or {}
    stage = proj.get('stage')
    detail = stage.get('detail') if isinstance(stage, dict) else ''
    if not detail and isinstance(w.get('stage'), str):
        detail = w['stage']
    evidence = proj.get('evidence') if isinstance(proj.get('evidence'), dict) else {}
    err = ' '.join(str(v) for v in (w.get('lastError'), proj.get('lastError'), evidence.get('lastError')) if v)
    return detail in STARTUP_FAIL_DETAILS or startup_failure_text(err)


def enrich_failed_worker_show(worker, state, rpc_call):
    """Copy stage and lastError from worker-show onto a failed own or follow-up row that carries neither (#1270).

    Remote and concise worker-list rows hold only the failed status. The one worker-show answer is cached
    in state so later passes reapply it without another call. Rows that are not ours are left alone."""
    w = worker or {}
    did = w.get('dispatchId')
    if not isinstance(did, str) or not did or worker_inventory_status(w) != 'failed':
        return
    proj = w.get('projection') if isinstance(w.get('projection'), dict) else {}
    stage = proj.get('stage')
    if w.get('lastError') or proj.get('lastError') or (isinstance(stage, dict) and stage.get('detail')):
        return
    if did not in (state.get('own_dispatches') or {}) and not _followup_parent(w):
        return
    checked = state.setdefault('show_checked', {})
    if not isinstance(checked, dict):
        checked = {}
        state['show_checked'] = checked
    found = checked.get(did)
    if not isinstance(found, dict):
        try:
            shown = rpc_call('orchestration', 'worker-show', '--dispatch', did)
        except SEND_ERRORS:
            return
        if isinstance(shown, dict) and isinstance(shown.get('worker'), dict):
            shown = shown['worker']
        if not isinstance(shown, dict):
            shown = {}
        shown_stage = shown.get('stage')
        if isinstance(shown_stage, dict):
            shown_stage = shown_stage.get('detail')
        found = {'stage': str(shown_stage or ''), 'lastError': str(shown.get('lastError') or '')}
        checked[did] = found
    if found.get('lastError'):
        w['lastError'] = found['lastError']
    if found.get('stage'):
        w['stage'] = found['stage']


def startup_retry_taken(state, key):
    """Claim the one startup retry for this park key. False when it was already used (#1221)."""
    bucket = state.setdefault('startup_retried', {})
    if not isinstance(bucket, dict):
        bucket = {}
        state['startup_retried'] = bucket
    if bucket.get(key):
        return False
    bucket[key] = True
    return True


def _verifier_row_dead(worker):
    """True when the dispatch ended or its agent is gone without succeeding."""
    kind = worker_settled_kind(worker)
    if kind:
        return kind != 'succeeded'
    status = worker_inventory_status(worker)
    if status in ('failed', 'stopped', 'cancelled', 'abandoned') or worker.get(GONE_REMOTE_KEY):
        return True
    return status != 'completed' and worker_liveness_verdict(worker) == 'exited'


def dead_verifier(state, workers, repo, number, head):
    """(dispatch id, worker row or None) of the verifier recorded for this head that was stopped, failed or
    is gone from the list, else ('', None). The caller checks that no Verdict is posted.

    An empty list proves nothing (the Orca read may have failed), so nothing in it counts as gone. A dispatch
    the stall pass restarted, still owes a restart or parked is its business. A done hold keeps the dispatch
    unreleased (#1849), except after a startup failure, where no worker_done is in play."""
    by_id = {w.get('dispatchId'): w for w in workers or []}
    for did, row in (state.get('own_dispatches') or {}).items():
        if not isinstance(row, dict) or row.get('startup_handled') or row.get('restarted') or row.get('parked'):
            continue
        if _dispatch_is_pending(state.get('stall_pending_start') or {}, did):
            continue
        if (row.get('repo'), row.get('pr'), row.get('head')) != (repo, number, head):
            continue
        if _retry_recorded(state, did):
            continue
        worker = by_id.get(did)
        if release_held(state, did) and not worker_startup_failed(worker):
            continue
        if by_id and (worker is None or _verifier_row_dead(worker)):
            return did, worker
    return '', None


def _projection_agent_model(worker):
    proj = worker.get('projection') or {}
    provider = proj.get('provider') if isinstance(proj, dict) else None
    if isinstance(provider, dict):
        agent = provider.get('id') or provider.get('name')
        model = provider.get('model')
        if agent and model:
            return str(agent), str(model)
    agent = worker.get('agent')
    model = worker.get('model')
    if agent and model:
        return str(agent), str(model)
    return None


def _launch_record_pair(dispatch_id):
    if not isinstance(dispatch_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', dispatch_id):
        return None
    state_dir = os.environ.get('WORKER_STARTUP_STATE') or os.path.expanduser(
        os.path.join('~', '.local', 'state', 'worker-startup')
    )
    path = Path(state_dir) / 'launches' / ('%s.json' % dispatch_id)
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    agent, model = data.get('agent'), data.get('model')
    if isinstance(agent, str) and agent and isinstance(model, str) and model:
        return agent, model
    return None


def _worker_is_verifier(worker):
    proj = worker.get('projection') or {}
    role = proj.get('role') if isinstance(proj, dict) else ''
    if not role:
        role = worker.get('role') or ''
    return str(role).lower() in ('qa', 'qa-sdet', 'reviewer', 'verifier')


_VERIFY_TITLE_RE = re.compile(r'^qa-sdet\b.*?\bverify\b(.*)$', re.I)
_NEW_VERIFY_TITLE_RE = re.compile(r'^#(\d+)\|qa-sdet(?:\|(.*))?$')
_TITLE_PR_RE = re.compile(r'#(\d+)|\bPRs?\s+#?(\d+)', re.I)
_VERIFY_WORKTREE_RE = re.compile(r'^(?:verify|vd|v)-?(\d+)(?:-[a-z0-9]+)?$')
_VERIFIER_TITLE_KEYS = ('_task_title', 'title', 'name')


_BARE_NUMBER_RE = re.compile(r'(?<![\w/#.-])(\d{1,6})(?![\w.-])')


def _title_prs(text):
    """PR numbers in a title segment: "#7", "PR 7", and bare numbers such as "verify 1263" (#1271)."""
    prs = [int(a or b) for a, b in _TITLE_PR_RE.findall(text)]
    prs += [int(n) for n in _BARE_NUMBER_RE.findall(text)]
    return list(dict.fromkeys(prs))


def _verifier_text_prs(text):
    new_form = _NEW_VERIFY_TITLE_RE.match(text)
    if new_form:
        if (new_form.group(2) or '').strip() == 'standing':
            return []
        return list(dict.fromkeys([int(new_form.group(1))] + _title_prs(new_form.group(2) or '')))
    match = _VERIFY_TITLE_RE.match(text)
    if not match:
        return []
    return _title_prs(match.group(1))


def _launch_record_worktree(dispatch_id):
    """Worktree path that worker-startup.sh recorded for a dispatch, else ''."""
    if not isinstance(dispatch_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', dispatch_id):
        return ''
    state_dir = os.environ.get('WORKER_STARTUP_STATE') or os.path.expanduser(
        os.path.join('~', '.local', 'state', 'worker-startup')
    )
    try:
        data = json.loads((Path(state_dir) / 'launches' / ('%s.json' % dispatch_id)).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return ''
    value = data.get('worktree') if isinstance(data, dict) else ''
    return value if isinstance(value, str) else ''


def _verifier_worktree_pr(worker):
    """PR number from a verifier worktree basename (verify-7, v7, verify-7-b), else None."""
    selector = worker_worktree_selector(worker)
    for raw in (worker_checkout_path(worker), selector.split('::', 1)[-1] if isinstance(selector, str) else '',
                _launch_record_worktree(worker.get('dispatchId'))):
        base = os.path.basename(str(raw or '').rstrip('/'))
        found = _VERIFY_WORKTREE_RE.match(base)
        if found:
            return int(found.group(1))
    return None


def verifier_title_prs(worker):
    """PR numbers a verifier worker is on, from its task title ("qa-sdet - verify PR #7", "qa-sdet verify o/r#7",
    a batch "qa-sdet - verify PRs #7, #8 and o/r#9" or "#4|qa-sdet|verify PR 7", which names the issue and the PR)
    or its worktree basename (verify-7, v7, verify-7-b), else an empty list.

    Real worker-list rows carry no role, PR number or branch, only a taskId; fetch_workers joins the task title.
    """
    prs = []
    for key in _VERIFIER_TITLE_KEYS:
        prs += _verifier_text_prs(str(worker.get(key) or '').strip())
    from_tree = _verifier_worktree_pr(worker)
    if from_tree is not None:
        prs.append(from_tree)
    return list(dict.fromkeys(prs))


def _worker_titled_verifier(worker):
    if _worker_is_verifier(worker):
        return True
    for key in _VERIFIER_TITLE_KEYS:
        text = str(worker.get(key) or '').strip()
        if re.match(r'^(?:#\d+\|)?qa-sdet\b', text):
            return True
    return False


def live_verifier_worker(pr, workers, state=None, repo=None):
    """The live verifier worker on this PR, hand dispatched or not, else None."""
    number = pr.get('number')
    head = pr.get('headRefName')
    for rec in ((state or {}).get('standing_verifiers') or {}).values():
        if isinstance(rec, dict) and number is not None and rec.get('current_pr') == number \
                and (repo is None or rec.get('repo') == repo):
            worker = _standing_worker(rec, workers)
            if worker is not None and worker_row_is_live(worker):
                return worker
    for worker in workers or []:
        if not isinstance(worker, dict) or not worker_row_is_live(worker):
            continue
        if number is not None and number in verifier_title_prs(worker):
            return worker
        if not _worker_titled_verifier(worker):
            continue
        if number is not None and worker_pr_number(worker) == number:
            return worker
        if head and worker_branch_name(worker) == head:
            return worker
    return None


def live_verifier_for_pr(pr, workers, state=None, repo=None):
    """True when a live verifier worker, hand dispatched or not, is already on this PR."""
    return live_verifier_worker(pr, workers, state, repo) is not None


IDLE_SEAT_QUIET_SECONDS = 20 * 60
IDLE_SEAT_GRACE_SECONDS = 15 * 60
IDLE_SEAT_STOP_QUIET_SECONDS = 5 * 60
IDLE_SEAT_TEXT = 'fleet-watch: you look idle. Read your inbox (orca orchestration check), finish, then send worker_done.'


def idle_seat_dispatches(state):
    """Dispatch ids the idle seat pass flagged as finished or idle and not back at work (#1904, #1905)."""
    book = (state or {}).get('idle_seat') or {}
    return {did for did, rec in book.items() if isinstance(rec, dict) and not rec.get('busy')}


def _idle_seat_ref(worker, repo_of, ref_state):
    """('owner/repo#n', closed) for the worker's PR, else its issue; closed is False when unknown."""
    number = worker_pr_number(worker) or _worker_issue_number(worker)
    try:
        repo = repo_of(worker)
    except SEND_ERRORS:
        repo = None
    if not repo or not number:
        return '', False
    try:
        closed = ref_state(repo, number) == 'CLOSED'
    except SEND_ERRORS:
        closed = False
    return '%s#%d' % (repo, number), closed


def idle_seat_pass(config, state, now, workers, term_times, messages, rpc_call, ref_state=None, repo_of=None):
    """Wake a worker idle at its prompt once, then free its seat when its work is closed (#1905).

    A worker whose output is quiet IDLE_SEAT_QUIET_SECONDS while its issue or PR is closed, or while a message
    to it is unread, gets one wake line. After IDLE_SEAT_GRACE_SECONDS, if the work is still closed and the
    output is quiet IDLE_SEAT_STOP_QUIET_SECONDS, it is stopped and released; otherwise elon hears it once and
    it is never stopped. Verifiers wait for their next PR and are left alone. Returns (notices, log_bits)."""
    ref_state = ref_state or fetch_ref_state
    repo_of = repo_of or (lambda w: repo_for_worker(w, config))
    notices, bits = [], []
    book = state.setdefault('idle_seat', {})
    live = {w.get('dispatchId'): w for w in workers or []
            if isinstance(w, dict) and w.get('dispatchId') and worker_row_is_live(w)}
    for did in list(book):
        if did not in live:
            book.pop(did, None)
    unread = set()
    for m in messages or []:
        if isinstance(m, dict) and not m.get('read') and not m.get('handled') and isinstance(m.get('to'), str):
            unread.add(m['to'])
    for did, w in live.items():
        if _worker_titled_verifier(w) or worker_liveness_verdict(w) == 'live':
            continue
        rec = book.get(did)
        if rec and rec.get('stopped'):
            continue
        handle = worker_terminal_handle(w)
        last = _normalize_terminal_time_ms((term_times or {}).get(handle)) if handle else None
        if last is None:
            continue
        quiet = now - last
        env = remote_environment(w) if worker_is_remote(w, config) else ''
        if rec is None:
            if quiet < IDLE_SEAT_QUIET_SECONDS:
                continue
            ref, closed = _idle_seat_ref(w, repo_of, ref_state)
            if not closed and handle not in unread:
                continue
            on_host = ('--environment', env) if env else ()
            try:
                rpc_call('terminal', 'send', *on_host, '--terminal', handle, '--text', IDLE_SEAT_TEXT, '--enter')
            except SEND_ERRORS as error:
                log_send_failed(handle, error)
                bits.append('idle_wake_fail=%s' % did)
                continue
            book[did] = {'woke_at': now, 'closed': closed}
            bits.append('idle_wake=%s' % did)
            continue
        woke = float(rec.get('woke_at') or now)
        # Output well after the wake line, and recent: back at work, so it fills a seat again.
        rec['busy'] = last > woke + 60 and quiet < IDLE_SEAT_STOP_QUIET_SECONDS
        if rec['busy'] or rec.get('reported') or now - woke < IDLE_SEAT_GRACE_SECONDS:
            continue
        ref, closed = _idle_seat_ref(w, repo_of, ref_state)
        if closed:
            if quiet < IDLE_SEAT_STOP_QUIET_SECONDS:
                continue
            code = stop_and_release_stalled(rpc_call, w, did, env)
            if code:
                bits.append('idle_stop_fail=%s:%s' % (did, code))
                continue
            rec['stopped'] = True
            bits.append('idle_stop=%s' % did)
            notices.append('worker %s stopped: idle at its prompt after a wake and %s is closed, so its seat is free' % (did, ref))
            continue
        rec['reported'] = True
        bits.append('idle_report=%s' % did)
        notices.append('worker %s idle at its prompt after a wake, %s still open: not stopped, check its inbox' % (did, ref or 'its work'))
    return notices, bits


UNREAD_NUDGE_IDLE_SECONDS = 300
UNREAD_NUDGE_REPEAT_SECONDS = 300
UNREAD_NUDGE_MAX = 2
UNREAD_NUDGE_TEXT = 'You have an unread orchestration message: run orca orchestration check'


def unread_nudge_pass(state, now, workers, term_times, messages, rpc_call):
    """Type a short nudge into an idle worker that has an unread message addressed to it.

    orchestration send only queues; an idle worker never sees it. Each message is nudged at most
    twice, 5 minutes apart. A terminal that is not writable is logged and not retried.
    """
    log_bits = []
    bucket = state.setdefault('unread_nudge', {})
    unread = {}
    for m in messages:
        if not isinstance(m, dict) or m.get('read') or m.get('handled') or not m.get('id'):
            continue
        to = m.get('to')
        if isinstance(to, str) and to:
            unread.setdefault(to, []).append(m['id'])
    live_ids = {i for ids in unread.values() for i in ids}
    for mid in list(bucket):
        if mid not in live_ids:
            bucket.pop(mid, None)
    for w in workers:
        if not worker_row_is_live(w) or worker_liveness_verdict(w) == 'live':
            continue
        handle = worker_terminal_handle(w)
        ids = unread.get(handle)
        if not ids:
            continue
        last = _normalize_terminal_time_ms((term_times or {}).get(handle))
        for mid in ids:
            row = bucket.get(mid) or {'count': 0, 'at': 0}
            if row['count'] >= UNREAD_NUDGE_MAX:
                continue
            if row['count'] == 0:
                if last is None or now - last < UNREAD_NUDGE_IDLE_SECONDS:
                    break
            elif now - row['at'] < UNREAD_NUDGE_REPEAT_SECONDS:
                continue
            try:
                rpc_call('terminal', 'send', '--terminal', handle, '--text', UNREAD_NUDGE_TEXT, '--enter')
            except SEND_ERRORS as error:
                if 'terminal_not_writable' in str(error) or 'terminal_not_writable' in str(orchestration_failure_log_code(error)):
                    bucket[mid] = {'count': UNREAD_NUDGE_MAX, 'at': now}
                    log_bits.append('nudge_not_writable=%s' % handle)
                else:
                    log_send_failed(handle, error)
                break
            bucket[mid] = {'count': row['count'] + 1, 'at': now}
            log_bits.append('nudged=%s' % handle)
            break
    return log_bits


def verifier_idle_seconds(worker, term_times, now):
    handle = worker_terminal_handle(worker)
    if not handle or not term_times:
        return 0
    last = _normalize_terminal_time_ms(term_times.get(handle))
    if last is None:
        return 0
    return max(0, now - last)


def _verifier_head_bucket(state, repo):
    return state.setdefault('verifier_head', {}).setdefault(repo, {})


def release_closed_verifier(pr, workers, state, repo, release):
    """Release a live verifier on a merged or closed pull request. True when released."""
    worker = live_verifier_worker(pr, workers)
    if worker is None or release_held(state, worker.get('dispatchId')):
        return False
    release(worker)
    _verifier_head_bucket(state, repo).pop(str(pr.get('number')), None)
    return True


def release_idle_rework_verifier(pr, workers, state, repo, now, term_times, release):
    """Release a verifier that has waited out a rework for an hour. True when released."""
    worker = live_verifier_worker(pr, workers)
    if worker is None or not rework_needed_at_head(pr) or release_held(state, worker.get('dispatchId')):
        return False
    if verifier_idle_seconds(worker, term_times, now) < VERIFIER_REWORK_IDLE_SECONDS:
        return False
    release(worker)
    _verifier_head_bucket(state, repo).pop(str(pr.get('number')), None)
    return True


def route_rework_head(pr, workers, state, repo, now, term_times, release, notify):
    """Send a new green head to the live verifier, or release that verifier after an hour idle.

    Returns 'sticky', 'released', 'live', or 'none'.
    """
    worker = live_verifier_worker(pr, workers)
    if worker is None:
        return 'none'
    number = pr.get('number')
    head = pr.get('headRefOid') or ''
    bucket = _verifier_head_bucket(state, repo)
    tracked = bucket.get(str(number)) or ''
    idle = verifier_idle_seconds(worker, term_times, now)
    if tracked and tracked != head:
        if idle >= VERIFIER_REWORK_IDLE_SECONDS:
            if release_held(state, worker.get('dispatchId')):
                return 'live'
            release(worker)
            bucket.pop(str(number), None)
            return 'released'
        mail_worker(
            notify, worker,
            'Rework head %s is on %s#%s. Check only the prior FAIL items and git diff %s..%s (the diff since the last verified head).'
            % (head, repo, number, tracked, head),
        )
        bucket[str(number)] = head
        return 'sticky'
    if not tracked:
        bucket[str(number)] = head
        return 'recorded'
    return 'live'


def builder_pair_from_body(pr):
    """Builder agent and model from the last Builder line of the PR body, else None."""
    found = None
    for line in (pr.get('body') or '').splitlines():
        match = _BUILDER_LINE_RE.match(line.strip()) or _BUILDER_SLASH_RE.match(line.strip())
        if match:
            found = (_AGENT_ALIASES.get(match.group(1).lower(), match.group(1)), match.group(2))
    return found


def builder_pair(pr, workers=None):
    """Builder agent and model from the PR body, else the dispatch that owns the PR (#1940)."""
    found = builder_pair_from_body(pr)
    if found:
        return found
    number = pr.get('number')
    branch = pr.get('headRefName') or ''
    matches = []
    for worker in workers or []:
        if not isinstance(worker, dict):
            continue
        if number is not None and worker_pr_number(worker) == number:
            matches.append(worker)
        elif branch and worker_branch_name(worker) == branch:
            matches.append(worker)
    matches.sort(key=_worker_is_verifier)
    for worker in matches:
        pair = _projection_agent_model(worker)
        if pair:
            return pair
        pair = _launch_record_pair(worker.get('dispatchId') or worker.get('dispatch_id'))
        if pair:
            return pair
    return None


def _usage_gate_argv():
    cli = os.environ.get('USAGE_GATE_CLI') or str(Path(__file__).with_name('usage-gate.py'))
    if cli.endswith('.py'):
        return [sys.executable, cli]
    return [cli]


def pick_role(role, run=subprocess.run, avoid_family=None, tier=None, avoid_provider=None):
    command = _usage_gate_argv() + ['pick', '--role', role, '--json', '--auto']
    if avoid_family:
        command += ['--avoid-family', avoid_family]
    if avoid_provider:
        command += ['--avoid-provider', avoid_provider]
    if tier:
        command += ['--tier', tier]
    USAGE_GATE_CALLS[0] += 1
    try:
        proc = run(command, capture_output=True, text=True, timeout=60, check=False)
    except (subprocess.SubprocessError, OSError):
        return None
    try:
        data = json.loads(proc.stdout or '')
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    if not data.get('selected'):
        for candidate in data.get('candidates') or []:
            if isinstance(candidate, dict) and candidate.get('verdict') in ('blocked', 'unknown'):
                headroom = candidate.get('headroom')
                record_gate_refusal(candidate.get('provider'), candidate['verdict'], candidate.get('reason'),
                                    candidate.get('reading_age_min'),
                                    candidate.get('last_headroom') if headroom is None else headroom)
    return data


def _exact_pair(agent, model, avoid):
    if not avoid:
        return False
    return agent.lower() == avoid[0].lower() and model.lower() == avoid[1].lower()


def _avoid_family(pair):
    if not pair:
        return None
    family = _sibling('usage_gate_family', 'usage-gate.py').model_family(pair[0], pair[1])
    return family if family in _AVOID_FAMILIES else None


def _same_agent_model(agent, model, avoid):
    """True for the builder pair, or for the same model family from the shared map."""
    if not avoid:
        return False
    if _exact_pair(agent, model, avoid):
        return True
    gate = _sibling('usage_gate_family', 'usage-gate.py')
    left = gate.model_family(agent, model)
    right = gate.model_family(avoid[0], avoid[1])
    return bool(left and right and left == right)


def choose_pick(data, avoid=None):
    """First eligible pick. Same family is skipped unless it is the quota fallback, and the exact pair never wins.

    Returns (agent, model, tag). tag is same-family-different-model or ''.
    """
    if not isinstance(data, dict):
        return None
    ordered = []
    selected = data.get('selected')
    if isinstance(selected, dict):
        ordered.append(selected)
    for candidate in data.get('candidates') or []:
        if isinstance(candidate, dict) and candidate not in ordered:
            ordered.append(candidate)
    fallback = None
    for candidate in ordered:
        agent = candidate.get('provider') or candidate.get('agent')
        model = candidate.get('model')
        if not isinstance(agent, str) or not agent or not isinstance(model, str) or not model:
            continue
        if _exact_pair(agent, model, avoid):
            continue
        if candidate.get('same_family_fallback'):
            if fallback is None:
                fallback = (agent, model)
            continue
        if candidate.get('eligible') is False:
            continue
        if _same_agent_model(agent, model, avoid):
            continue
        return agent, model, ''
    if fallback:
        return fallback[0], fallback[1], 'same-family-different-model'
    return None


def pick_failure_reason(data, avoid=None):
    """Why choose_pick returned nothing. The pick_fail line carries this text."""
    if not isinstance(data, dict):
        return 'no-pick'
    rows = []
    selected = data.get('selected')
    if isinstance(selected, dict):
        rows.append(selected)
    for candidate in data.get('candidates') or []:
        if isinstance(candidate, dict) and candidate not in rows:
            rows.append(candidate)
    builder = False
    for candidate in rows:
        agent = candidate.get('provider') or candidate.get('agent')
        model = candidate.get('model')
        if isinstance(agent, str) and isinstance(model, str) and _same_agent_model(agent, model, avoid):
            builder = True
            continue
        reason = candidate.get('reason')
        if isinstance(reason, str) and reason.strip():
            return one_line_reason(reason)
    if builder:
        return 'builder'
    return 'no-pick'


def pr_open_now(repo, number, fetch):
    """'OPEN' when a fresh read of the open list still has this PR, 'closed' when it does not, '' when the read fails."""
    rows = fetch(repo)
    if rows is None:
        return ''
    for row in rows:
        if isinstance(row, dict) and row.get('number') == number and pr_open_for_dispatch(row):
            return 'OPEN'
    return 'closed'


def pr_open_for_dispatch(pr_row):
    """An open pull request with no merge or close time. Merged and closed rows are not dispatched."""
    if not isinstance(pr_row, dict):
        return False
    if str(pr_row.get('state') or '').upper() != 'OPEN':
        return False
    if pr_row.get('mergedAt') or pr_row.get('closedAt'):
        return False
    return True


def _babysit_closed(pr_row):
    if not isinstance(pr_row, dict):
        return False
    state_name = str(pr_row.get('state') or '').upper()
    return state_name in ('MERGED', 'CLOSED') or bool(pr_row.get('mergedAt') or pr_row.get('closedAt'))


def live_verifier_claims(workers):
    """PR numbers and branch names that live verifier workers name, the keys live_verifier_worker matches on."""
    numbers, branches = set(), set()
    for worker in workers or []:
        if not isinstance(worker, dict) or not worker_row_is_live(worker):
            continue
        numbers.update(verifier_title_prs(worker))
        if _worker_titled_verifier(worker):
            if worker_pr_number(worker) is not None:
                numbers.add(worker_pr_number(worker))
            if worker_branch_name(worker):
                branches.add(worker_branch_name(worker))
    return numbers, branches


UNKNOWN_BUILDER_REFUSALS = 3  # refusals on one head before one notice and a skip until the head changes (#1841)


def _unknown_builder_book(state, repo):
    return state.setdefault('babysit_unknown_builder', {}).setdefault(repo, {})


def unknown_builder_refused(state, repo, number, head):
    """Count one unknown builder refusal on this head. True on the refusal that parks it, once per head."""
    book = _unknown_builder_book(state, repo)
    entry = book.get(str(number))
    if not isinstance(entry, dict) or entry.get('head') != head:
        entry = book[str(number)] = {'head': head, 'refusals': 0}
    entry['refusals'] = int(entry.get('refusals') or 0) + 1
    return entry['refusals'] == UNKNOWN_BUILDER_REFUSALS


def unknown_builder_parked(state, repo, number, head):
    entry = ((state.get('babysit_unknown_builder') or {}).get(repo) or {}).get(str(number))
    return isinstance(entry, dict) and entry.get('head') == head \
        and int(entry.get('refusals') or 0) >= UNKNOWN_BUILDER_REFUSALS


def unknown_builder_clear(state, repo, number):
    ((state.get('babysit_unknown_builder') or {}).get(repo) or {}).pop(str(number), None)


def unknown_builder_prune(state, repo, open_numbers):
    """Drop records for PRs that are no longer open."""
    book = (state.get('babysit_unknown_builder') or {}).get(repo)
    if not isinstance(book, dict):
        return
    keep = {str(n) for n in open_numbers}
    for key in [k for k in book if k not in keep]:
        book.pop(key)


def _babysit_line(repo, number, head, action, detail=''):
    text = 'babysit %s#%s head=%s action=%s' % (repo, number, head, action)
    if detail:
        text += ' ' + detail
    return text


def pr_touches_no_package(pr_row, root):
    """True when the PR has changed files and none sits in a folder with a package.json."""
    paths = pr_file_paths(pr_row)
    if not paths:
        return False
    for path in paths:
        folder = Path(path).parent
        while True:
            if (Path(root) / folder / 'package.json').is_file():
                return False
            if folder == folder.parent:
                break
            folder = folder.parent
    return True


def build_babysit_spec(repo, pr_row, kind, builder, root, verdict_tag='', standing=False):
    number = pr_row['number']
    head = pr_row.get('headRefOid') or ''
    verify = checks_local_verify_text(root, 'bash script/checks-local.sh')
    setup_line = '\nSetup: none' if pr_touches_no_package(pr_row, root) else ''
    if kind == 'verifier':
        if builder:
            who = 'The builder is agent=%s model=%s. Use a different agent and model.' % builder
        else:
            who = 'The builder agent and model were not recorded.'
        if verdict_tag:
            who += ' No other family has quota. Tag the Verdict %s.' % verdict_tag
        prior_fail = prior_verdict_fail(pr_row)
        if prior_fail:
            last_head, findings = prior_fail
            scope_line = (
                'Re-verify after a fix: check only the prior FAIL items and the diff since the last verified head '
                '(git diff %s..%s).' % (last_head, head)
            )
            if findings:
                scope_line += '\n\nPrior FAIL items from head %s:\n%s' % (last_head, findings)
            verify = (
                'GitHub Checks are green and Review is green at head %s. Check only the prior FAIL items and git diff %s..%s.'
                % (head, last_head, head)
            )
        else:
            scope_line = ''
            verify = (
                'GitHub Checks are green at head %s. Review the diff and run the live checks this brief names.'
                % head
            )
        if checks_local_applies(root):
            verify += '\nbash script/checks-local.sh 2>&1 | tail -40'
        extra_scope = ('\n\n%s' % scope_line) if scope_line else ''
        text = (
            'Refs %s#%s%s\n\n'
            'Role: qa-sdet. Verify this open PR at head %s the way a user would, '
            'and post the Verdict with script/post-verdict.sh (add --ship on a PASS or PASS+NOTES: it runs ship.sh at once; put any SHIP REFUSED line in worker_done). %s%s\n\n'
            '## Acceptance\n'
            '- [ ] a Verdict for head %s is posted\n\n'
            '## Out of scope\n'
            'Merging by hand. post-verdict.sh --ship runs ship.sh after your PASS, and fleet-watch starts ship.sh for a ready head. Verdict format stays as it is.\n\n'
            '## Verify\n'
            '%s\n\n'
            '## Finish\n'
            'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        ) % (repo, number, setup_line, head, who, extra_scope, head, verify)
        if standing:
            text = text.split('## Finish')[0] + (
                '## Finish\n'
                'You are a standing verifier. After you post the Verdict, stay at your idle prompt and do not send worker_done. '
                'fleet-watch sends the next PR as a prompt. When a prompt says it is your last PR, post the Verdict, run '
                'orca worktree set --worktree active --workspace-status completed, then send worker_done.\n'
            )
        return _write_issue_scan_spec(_with_preamble(text, 'qa-sdet'))
    else:
        text = (
            'Refs %s#%s%s\n\n'
            'Role: fullstack-dev. Fix this PR. head-checks failed at head %s.\n\n'
            '## Acceptance\n'
            '- [ ] head-checks pass for the new head\n\n'
            '## Out of scope\n'
            'Merging. fleet-watch starts ship.sh for a ready head. Files outside this PR.\n\n'
            '## Verify\n'
            '%s\n\n'
            '## Finish\n'
            'Wait until gh pr checks <n> --watch --fail-fast (or gh run list --branch <branch> --limit 3) passes at the final head, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        ) % (repo, number, setup_line, head, verify)
        return _write_issue_scan_spec(_with_preamble(text, 'fullstack-dev'))


def tier0_audit_title(week):
    return 'tier 0 audit %s' % week


TIER0_AUDIT_PREFIX = 'tier 0 audit '
TIER0_SAME_FAMILY_NOTE = (
    '\n\nNo auditor of another model family is available. Tag each Audit comment with a second line '
    '`same-family-different-model` and do not ask the coordinator.')


def tier0_audit_pick(issue, pick_fn):
    """(agent, model, tag) for a tier 0 audit issue: an agent of another family than the PR builders (#1765).

    The builders are the `Builder: agent= model=` lines in the issue body. Without another family the pick is the
    same family and the tag is same-family-different-model. None when nothing can be picked."""
    pairs = []
    for line in (issue.get('body') or '').splitlines():
        match = _BUILDER_LINE_RE.match(line.strip())
        if match:
            pairs.append((_AGENT_ALIASES.get(match.group(1).lower(), match.group(1)), match.group(2)))
    by_family = {}
    for pair in pairs:
        family = _avoid_family(pair)
        if family:
            by_family.setdefault(family, pair)
    first = None
    for family, pair in by_family.items() or [(None, None)]:
        chosen = choose_pick(pick_fn('qa-sdet', avoid_family=family), pair)
        if not chosen:
            continue
        if _avoid_family(chosen[:2]) not in by_family:
            return chosen[0], chosen[1], ''
        first = first or (chosen[0], chosen[1], 'same-family-different-model')
    return first


def tier0_audit_find_issue(repo, title, run=subprocess.run):
    """Number of an issue (open or closed) with this exact title, 0 when there is none, None when gh fails."""
    try:
        out = run(['gh', 'issue', 'list', '--repo', repo, '--state', 'all', '--search',
                   '"%s" in:title' % title, '--json', 'number,title', '--limit', '20'],
                  capture_output=True, text=True, timeout=30, check=True)
        for row in json.loads(out.stdout):
            if row.get('title') == title:
                return row.get('number') or 0
        return 0
    except (subprocess.SubprocessError, OSError, ValueError, AttributeError):
        return None


def tier0_audit_issue_body(prs, repo):
    """Issue body for a qa-sdet verifier: the picked PRs, and one Audit comment per PR."""
    rows = '\n'.join(
        '- #%s `%s`' % (p['number'], (p.get('mergeCommit') or {}).get('oid') or 'unknown') for p in prs)
    builders = '\n'.join('Builder: agent=%s model=%s' % pair for pair in
                         dict.fromkeys(pair for pair in (builder_pair(p) for p in prs) if pair))
    rows += '\n\n' + builders if builders else ''
    return (
        'These tier 0 PRs (test files and docs only) merged on Review PASS and green Checks with no verifier. '
        'Audit each one after the fact. Merge commits:\n\n%s\n\n'
        '## Acceptance\n'
        '- [ ] For each PR above, read the diff (`gh pr diff <n>`), check out its merge commit, and run the tests it added or changed.\n'
        '- [ ] Each PR gets one comment whose first line is exactly `Audit: PASS merged=<merge commit>` or '
        '`Audit: FAIL merged=<merge commit>`, then the findings and the exact command run. Never a `Verdict:` line.\n'
        '- [ ] PASS only when the tests prove real behavior (no tautology, nothing skipped) and changed docs match the code.\n\n'
        '## Out of scope\n'
        'Merging, reverting, editing code. A FAIL goes to the weekly report and the coordinator files the follow up.\n\n'
        '## Verify\n'
        '`python3 ~/dotfiles/script/tier0-audit.py report --repo %s` lists each PR above as PASS or FAIL.\n'
    ) % (rows, repo)


def fetch_merged_prs(repo, now, days=7, run=None):
    """PRs merged in the last `days` days, or None when gh fails."""
    if run is None:
        run = subprocess.run
    since = time.strftime('%Y-%m-%d', time.gmtime(now - days * 86400))
    command = [
        'gh', 'pr', 'list', '--repo', repo, '--state', 'merged', '--search', 'merged:>=%s' % since, '--limit', '100',
        '--json', 'number,title,body,headRefName,files,mergedAt,mergeCommit',
    ]
    try:
        return json.loads(run(command, capture_output=True, text=True, timeout=30, check=True).stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def tier0_audit_pass(config, state, now, merged_fetch=None, find_issue=None, create_issue=None, rng=None,
                     persist_state=None, log_file=None):
    """Once a week per repo: file one issue listing 5 random tier 0 PRs merged in the past week (#1730).

    The PRs are new to the log (tier0-audit.tsv). No worker starts here: a qa-sdet picks the issue up like any other.
    The log rows are written before the issue and cut again when the issue is not created, so a row never lacks its issue.
    A week is marked done only after the issue exists or when there is nothing to audit; a failed fetch, lookup,
    log write or create leaves it open for the next pass."""
    lines, log_bits = [], []
    if (config.get('babysit') or {}).get('tier0_audit') is False:
        return lines, log_bits
    audit = _sibling('tier0_audit', 'tier0-audit.py')
    week = time.strftime('%G-W%V', time.gmtime(now))
    title = tier0_audit_title(week)
    done = state.setdefault('tier0_audit', {})
    find_issue = find_issue or tier0_audit_find_issue
    create_issue = create_issue or (lambda repo, name, body: main_red_create_issue(repo, name, body, labels=('ready-for-agent', 'role:qa')))
    path = log_file or audit.log_path()
    for repo in babysit_repos(config):
        if done.get(repo) == week:
            continue
        found = find_issue(repo, title)
        if found is None:
            lines.append('tier0-audit %s skip issue-lookup-failed' % repo)
            log_bits.append('tier0_audit_lookup_fail=%s' % repo)
            continue
        if found:
            done[repo] = week
            lines.append('tier0-audit %s skip issue-exists' % repo)
            continue
        prs = (merged_fetch or fetch_merged_prs)(repo, now)
        if prs is None:
            log_bits.append('tier0_audit_fetch_fail=%s' % repo)
            continue
        seen = {pr for _w, pr, _s in audit.read_log(path, repo, 0)}
        picks = audit.pick([p for p in prs if isinstance(p, dict) and p.get('number') not in seen], pr_tier, rng=rng)
        if not picks:
            done[repo] = week
            lines.append('tier0-audit %s skip no-tier-0-pr' % repo)
            continue
        size = os.path.getsize(path) if os.path.exists(path) else 0
        try:
            audit.append_log(path, week, repo, picks, now=now)
        except OSError as error:
            lines.append('tier0-audit %s skip log-not-written: %s' % (repo, error))
            log_bits.append('tier0_audit_log_fail=%s' % repo)
            continue
        number = create_issue(repo, title, tier0_audit_issue_body(picks, repo))
        if not number:
            try:
                os.truncate(path, size)
            except OSError:
                pass
            lines.append('tier0-audit %s skip issue-not-created' % repo)
            log_bits.append('tier0_audit_issue_fail=%s' % repo)
            continue
        done[repo] = week
        lines.append('tier0-audit %s issue #%s PRs %s' % (repo, number, ','.join('#%s' % p['number'] for p in picks)))
        log_bits.append('tier0_audit=%s:%d' % (repo, len(picks)))
        if persist_state:
            persist_state()
    return lines, log_bits


class BabysitStartResult(int):
    """A start exit code that also carries the failing command's last stderr line and dispatch id."""

    def __new__(cls, code, reason='', dispatch_id='', terminal=''):
        self = super().__new__(cls, code)
        self.reason = reason
        self.dispatch_id = dispatch_id or ''
        self.terminal = terminal or ''
        return self


BABYSIT_DEFERRED_EXITS = (3, 4)  # worker-startup.sh: usage gate refused, host placement refused
# worker-startup.sh with WORKER_STARTUP_AGY_SIGNIN=exit: the antigravity start hit the sign in screen and undid itself (#1832).
AGY_SIGNIN_ENV = 'WORKER_STARTUP_AGY_SIGNIN'
AGY_SIGNIN_HELD_EXIT = 10
_AGY_SIGNIN_LINE_RE = re.compile(r'agy-signin: host=(\S+) (notify|known)\s*$')


@contextlib.contextmanager
def agy_signin_exit_env():
    """An issue start only: set WORKER_STARTUP_AGY_SIGNIN=exit for the one start call, then put the variable back."""
    previous = os.environ.get(AGY_SIGNIN_ENV)
    os.environ[AGY_SIGNIN_ENV] = 'exit'
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(AGY_SIGNIN_ENV, None)
        else:
            os.environ[AGY_SIGNIN_ENV] = previous


def agy_signin_held(reason):
    """(host, notify) from the last line worker-startup printed before exit 10; host is '' when it did not print one."""
    found = _AGY_SIGNIN_LINE_RE.search(reason or '')
    return (found.group(1), found.group(2) == 'notify') if found else ('', False)


def _json_error_message(text):
    """First line of error.message in an Orca JSON object, or '' when it is not there."""
    text = text or ''
    start = text.find('{')
    if start < 0:
        return ''
    try:
        error = json.JSONDecoder().raw_decode(text[start:])[0].get('error')
    except (ValueError, AttributeError, json.JSONDecodeError):
        return ''
    message = error.get('message') if isinstance(error, dict) else None
    if not isinstance(message, str) or not message.strip():
        return ''
    lines = [line.strip() for line in message.splitlines() if line.strip()]
    return re.sub(r'[,;\s]+', ' ', lines[0]).strip()[:160] if lines else ''


def _start_reason(stderr, stdout=''):
    """First line of Orca's error.message. Stdout wins, then stderr, then the last plain line."""
    for text in (stdout, stderr):
        message = _json_error_message(text)
        if message:
            return message
    for text in (stderr, stdout):
        lines = [line.strip() for line in (text or '').splitlines() if line.strip()]
        if lines:
            return re.sub(r'[,;\s]+', ' ', lines[-1]).strip()[:160]
    return ''


def _mtime_value(raw):
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return int(raw)


def config_mtime(config):
    return _mtime_value((config or {}).get('config_mtime'))


def park_id(kind, *parts):
    return '|'.join([kind, *[str(part) for part in parts]])


def park_is_active(state, key, config):
    """True when this start must not run. A changed config mtime drops the row and re-arms it."""
    parked = state.get('parked')
    if not isinstance(parked, dict):
        return False
    entry = parked.get(key)
    if not isinstance(entry, dict):
        return False
    current = config_mtime(config)
    saved = _mtime_value(entry.get('config_mtime'))
    if current is not None and saved is not None and saved != current:
        parked.pop(key, None)
        return False
    return True


def park_failure(state, key, reason, config, **meta):
    """Record one parked start. False when that key is already parked."""
    if park_is_active(state, key, config):
        return False
    record = {'reason': reason or '', 'config_mtime': config_mtime(config)}
    for name, value in meta.items():
        if value is None or value == '':
            continue
        record[name] = value
    state.setdefault('parked', {})[key] = record
    count_failed()
    count_parked()
    return True


def park_notice(kind, target, reason, command=None):
    """Urgent notice for a parked start. An Orca fence on fleet-watch's own terminal (#1170) is a handoff.

    The notice carries the ready command so the coordinator, which Orca does accept, can run it.
    """
    if command and reason and 'consumer_fenced' in reason:
        # worker-startup defaults --from to the coordinator's own terminal handle, so the line leaves it out.
        parts = [str(part) for part in command]
        while '--from' in parts:
            at = parts.index('--from')
            del parts[at:at + 2]
        return Urgent('handoff %s %s: Orca refuses worker starts from fleet-watch, start it from the coordinator: %s'
                      % (kind, target, shlex.join(parts)))
    text = 'parked %s %s' % (kind, target)
    if reason:
        text += ': ' + reason
    return Urgent(text)


def start_result_parts(result):
    if isinstance(result, int) and not isinstance(result, bool):
        return int(result), getattr(result, 'reason', '') or ''
    return 1, ''


def exception_start_failure(exc):
    """(reason, exit code) from an Orca or worker-startup failure. Exit code is None when there is none."""
    cause = exc.__cause__ if isinstance(getattr(exc, '__cause__', None), subprocess.CalledProcessError) else None
    if cause is None and isinstance(exc, subprocess.CalledProcessError):
        cause = exc
    if cause is not None:
        stdout = cause.stdout or ''
        stderr = cause.stderr or ''
        if isinstance(stdout, bytes):
            stdout = stdout.decode('utf-8', 'replace')
        if isinstance(stderr, bytes):
            stderr = stderr.decode('utf-8', 'replace')
        return _start_reason(stderr, stdout), cause.returncode
    return _start_reason(str(exc)), None


def _closed_numbers(rows):
    """Issue or PR numbers this list shows as not open. None means the list was not fetched."""
    if not isinstance(rows, list):
        return None
    closed, opened = set(), set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        number = row.get('number')
        if isinstance(number, bool) or not isinstance(number, int):
            continue
        if str(row.get('state') or '').upper() == 'OPEN':
            opened.add(number)
        else:
            closed.add(number)
    return closed - opened


def _matches_pr(entry, repo, numbers):
    return isinstance(entry, dict) and entry.get('repo') == repo and entry.get('pr') in numbers


def _drop_closed_prs(state, repo, numbers):
    babysit = state.get('babysit')
    if isinstance(babysit, dict):
        repo_rows = babysit.get(repo)
        if isinstance(repo_rows, dict):
            for number in numbers:
                repo_rows.pop(str(number), None)
            if not repo_rows:
                babysit.pop(repo, None)
    parked = state.get('parked')
    if isinstance(parked, dict):
        for key, entry in list(parked.items()):
            if _matches_pr(entry, repo, numbers):
                parked.pop(key, None)
    refs = state.get('failed_refs')
    failed = state.get('failed')
    if isinstance(refs, dict) and isinstance(failed, list):
        drop = [did for did, ref in refs.items() if _matches_pr(ref, repo, numbers)]
        if drop:
            gone = set(drop)
            state['failed'] = [did for did in failed if did not in gone]
            for did in drop:
                refs.pop(did, None)
    stopped = state.get('stall_stopped')
    if isinstance(stopped, dict):
        for task, value in list(stopped.items()):
            if _matches_pr(value, repo, numbers):
                stopped.pop(task, None)


def _drop_closed_issues(state, repo, numbers):
    parked = state.get('parked')
    if not isinstance(parked, dict):
        return
    for key, entry in list(parked.items()):
        if isinstance(entry, dict) and entry.get('repo') == repo and entry.get('issue') in numbers:
            parked.pop(key, None)


def prune_closed_maps(state, prs_by_repo, issues_by_repo):
    """Drop parked, failed, stall_stopped and babysit rows for PRs and issues listed as not open.

    A repo whose list is None was not fetched, so its rows stay.
    """
    for repo, rows in (prs_by_repo or {}).items():
        numbers = _closed_numbers(rows)
        if numbers:
            _drop_closed_prs(state, repo, numbers)
    for repo, rows in (issues_by_repo or {}).items():
        numbers = _closed_numbers(rows)
        if numbers:
            _drop_closed_issues(state, repo, numbers)


def prune_closed_issues(state, fetch):
    """Ask `fetch(repo)` for closed issues and drop parked rows for the ones it lists."""
    repos = []
    for entry in (state.get('parked') or {}).values():
        if not isinstance(entry, dict) or not entry.get('issue'):
            continue
        repo = entry.get('repo')
        if repo and repo not in repos:
            repos.append(repo)
    if not repos or fetch is None:
        return
    for repo in repos:
        try:
            rows = fetch(repo)
        except (subprocess.SubprocessError, OSError, ValueError):
            continue
        prune_closed_maps(state, {}, {repo: rows})


def fetch_closed_issue_rows(repo, run=subprocess.run):
    command = [
        'gh', 'issue', 'list', '--repo', repo, '--state', 'closed', '--limit', '100',
        '--json', 'number,state',
    ]
    try:
        output = run(command, capture_output=True, text=True, timeout=30, check=True)
        rows = json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        return None
    return rows if isinstance(rows, list) else None


def _state_tracks_repo(state, repo):
    if repo in (state.get('babysit') or {}):
        return True
    for entry in (state.get('parked') or {}).values():
        if isinstance(entry, dict) and entry.get('repo') == repo and entry.get('pr'):
            return True
    for ref in (state.get('failed_refs') or {}).values():
        if isinstance(ref, dict) and ref.get('repo') == repo:
            return True
    for value in (state.get('stall_stopped') or {}).values():
        if isinstance(value, dict) and value.get('repo') == repo:
            return True
    return False


def remember_config_mtime(config, path):
    try:
        config['config_mtime'] = int(Path(path).stat().st_mtime_ns)
    except OSError:
        return


def default_babysit_start(command, run=subprocess.run):
    try:
        done = run(command, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return BabysitStartResult(1, 'timed out after 180s')
    except (subprocess.SubprocessError, OSError) as exc:
        return BabysitStartResult(1, _start_reason(str(exc)))
    return BabysitStartResult(
        done.returncode,
        _start_reason(done.stderr, getattr(done, 'stdout', '') or ''),
        dispatch_id_from_text(getattr(done, 'stdout', None) or ''),
        terminal_from_text(getattr(done, 'stdout', None) or ''),
    )


def build_babysit_command(config, repo, pr_row, kind, agent, model, builder, verdict_tag='', standing_host=None):
    startup, run_id, from_terminal, roots = babysit_settings(config)
    root = roots.get(repo)
    if not startup or not run_id or not from_terminal or not isinstance(root, str) or not root:
        return None
    if not agent or not model:
        return None
    if kind == 'verifier' and standing_host:
        title = '#%s|qa-sdet|standing' % pr_row['number']
        name = 'verify-standing-%s' % re.sub(r'[^a-z0-9]+', '-', repo.lower()).strip('-')
    elif kind == 'verifier':
        title = '#%s|qa-sdet' % pr_row['number']
        name = 'verify-%s' % pr_row['number']
    else:
        title = '#%s|fullstack-dev' % pr_row['number']
        name = 'fix-%s' % pr_row['number']
    command = [
        'bash', startup,
        '--run', run_id,
        '--spec', build_babysit_spec(repo, pr_row, kind, builder, root, verdict_tag, standing=bool(standing_host)),
        '--title', title,
        '--agent', agent,
        '--model', model,
        '--name', name,
        '--repo', local_repo_selector(root),
    ]
    if standing_host:
        command += ['--on', standing_host]
    branch = pr_row.get('headRefName') or ''
    if branch:
        command += ['--base-branch', pr_base_ref(root, branch)]
    return command


def _default_notify_worker(terminal, text):
    if not terminal or not text:
        return
    try:
        rpc('terminal', 'send', '--terminal', terminal, '--text', text, '--enter')
    except SEND_ERRORS as error:
        log_send_failed(terminal, error)


STANDING_DEFAULTS = {
    'enabled': False, 'hosts': [], 'agent': 'antigravity', 'model': 'gemini-4-argon-high',
    'max_prs': 5, 'wake_timeout_seconds': 90, 'max_context_percent': 70, 'max_turns': 120,
}
STANDING_BUSY_RE = re.compile(r'[⠁-⣿]|\b(?:Running|Thinking)\b|esc to interrupt', re.I)
STANDING_CTX_RE = re.compile(r'ctx:\s*(\d+)%')
STANDING_STOP_RE = re.compile(
    r'Context limit reached|Run /compact|Individual quota reached|usage limit reached|hit your usage limit'
    r'|There was a network issue connecting|\bSTOPPED\b', re.I)
STANDING_TURNS_RE = re.compile(r'\b(\d+)\s+turns?\b|\bturns?\s*[:=]\s*(\d+)', re.I)
STANDING_PROBE_DELAYS = (5, 10)
TRIAL_COLUMNS = (
    'timestamp', 'host', 'mode', 'dispatch_id', 'repo', 'pr', 'head', 'event',
    'prs_done', 'reason', 'duration_s', 'headroom_pct',
)


def standing_settings(config):
    """babysit.standing_verifier merged over its defaults. Disabled unless the config enables it."""
    cfg = dict(STANDING_DEFAULTS)
    block = (config.get('babysit') or {}).get('standing_verifier')
    if isinstance(block, dict):
        cfg.update({key: block[key] for key in STANDING_DEFAULTS if key in block})
    for key in ('max_prs', 'wake_timeout_seconds', 'max_context_percent', 'max_turns'):
        try:
            cfg[key] = int(cfg[key])
        except (TypeError, ValueError):
            cfg[key] = STANDING_DEFAULTS[key]
    hosts = cfg.get('hosts')
    cfg['hosts'] = [h for h in hosts if isinstance(h, str) and h and h != 'auto'] if isinstance(hosts, list) else []
    cfg['enabled'] = bool(cfg.get('enabled')) and bool(cfg['hosts'])
    return cfg


def trial_log_path():
    return Path(os.environ.get('STANDING_VERIFIER_TRIAL_LOG') or Path.home() / '.claude' / 'state' / 'verifier-trial.tsv')


def trial_event(event, mode, host='', now=None, **fields):
    """Append one row to the verifier trial log. A log failure never stops a pass."""
    row = dict.fromkeys(TRIAL_COLUMNS, '')
    row.update(fields)
    row.update(
        timestamp=datetime.datetime.fromtimestamp(now or time.time(), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        host=host, mode=mode, event=event,
    )
    line = '\t'.join(re.sub(r'[\t\r\n]+', ' ', str(row[col])) for col in TRIAL_COLUMNS)
    path = trial_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fresh = not path.exists() or path.stat().st_size == 0
        with open(path, 'a') as handle:
            if fresh:
                handle.write('\t'.join(TRIAL_COLUMNS) + '\n')
            handle.write(line + '\n')
    except OSError:
        return


def read_trial_rows(path=None):
    path = Path(path) if path else trial_log_path()
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines[1:]:
        parts = line.split('\t')
        if len(parts) == len(TRIAL_COLUMNS):
            rows.append(dict(zip(TRIAL_COLUMNS, parts)))
    return rows


def _to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def trial_summary(rows):
    """Text report comparing standing and fresh verifiers from verifier-trial.tsv rows."""
    def count(mode, event):
        return sum(1 for r in rows if r['mode'] == mode and r['event'] == event)

    def mean(values):
        values = [v for v in values if v is not None]
        return sum(values) / len(values) if values else None

    def fmt(value, suffix=''):
        return 'n/a' if value is None else '%.1f%s' % (value, suffix)

    def rate(num, den):
        return 'n/a' if not den else '%.0f%% (%d/%d)' % (100.0 * num / den, num, den)

    out = []
    for mode in ('standing', 'fresh'):
        starts, fails = count(mode, 'start'), count(mode, 'start_fail')
        verdicts = [r for r in rows if r['mode'] == mode and r['event'] == 'verdict']
        latency = mean([_to_float(r['duration_s']) for r in verdicts])
        deltas = []
        seq = [r for r in rows if r['mode'] == mode and _to_float(r['headroom_pct']) is not None]
        for prev, cur in zip(seq, seq[1:]):
            if cur['event'] == 'verdict':
                deltas.append(_to_float(prev['headroom_pct']) - _to_float(cur['headroom_pct']))
        out.append('%s: starts=%d start_failure_rate=%s verdicts=%d verification_latency_s=%s headroom_delta_per_pr=%s' % (
            mode, starts, rate(fails, starts + fails), len(verdicts), fmt(latency), fmt(mean(deltas), ' pts')))
    wakes, fallbacks = count('standing', 'wake'), count('standing', 'wake_fallback')
    out.append('standing wake_failure_rate=%s' % rate(fallbacks, wakes + fallbacks))
    done = [_to_float(r['prs_done']) for r in rows if r['mode'] == 'standing' and r['event'] == 'retire']
    out.append('standing prs_per_dispatch=%s retirements=%d' % (fmt(mean(done)), len(done)))
    return '\n'.join(out)


def _terminal_in(data):
    if not isinstance(data, dict):
        return ''
    term = data.get('terminal')
    if isinstance(term, dict):
        term = term.get('handle')
    if isinstance(term, str) and term.strip():
        return term.strip()
    return _terminal_in(data.get('result'))


def terminal_from_text(text):
    raw = text if isinstance(text, str) else ''
    start = raw.find('{')
    while start >= 0:
        try:
            data, _end = json.JSONDecoder().raw_decode(raw[start:])
        except json.JSONDecodeError:
            start = raw.find('{', start + 1)
            continue
        found = _terminal_in(data)
        if found:
            return found
        start = raw.find('{', start + 1)
    return ''


class StandingIO:
    """Terminal reads, sends and sleeps for the standing verifier. Tests replace it."""

    def __init__(self, config):
        self.config = config

    def _env(self, host):
        return [] if _is_local_coordinator_host(host, self.config) else ['--environment', host]

    def read(self, terminal, host):
        """(screen text, lastOutputAt) of a terminal, or ('', None) when it cannot be read."""
        try:
            data = rpc('terminal', 'read', '--terminal', terminal, '--screen', *self._env(host))
        except SEND_ERRORS:
            return '', None
        data = data if isinstance(data, dict) else {}
        term = data.get('terminal') if isinstance(data.get('terminal'), dict) else {}
        tail = term.get('tail') or data.get('tail') or data.get('text') or ''
        text = '\n'.join(str(line) for line in tail) if isinstance(tail, list) else str(tail)
        return text, term.get('lastOutputAt') or data.get('lastOutputAt')

    def send(self, terminal, text, host):
        try:
            rpc('terminal', 'send', *self._env(host), '--terminal', terminal, '--text', text, '--enter')
        except SEND_ERRORS as error:
            log_send_failed(terminal, error)
            return False
        return True

    def resolve_terminal(self, dispatch_id, worktree_name, host):
        """Terminal handle of a remote standing verifier, whose worker-list row carries none (#1272), else ''."""
        try:
            shown = rpc('orchestration', 'worker-show', '--dispatch', dispatch_id, *self._env(host))
        except SEND_ERRORS:
            shown = None
        if isinstance(shown, dict) and isinstance(shown.get('worker'), dict):
            shown = shown['worker']
        found = worker_terminal_handle(shown) if isinstance(shown, dict) else ''
        if found:
            return found
        try:
            listed = rpc('terminal', 'list', *self._env(host))
        except SEND_ERRORS:
            return ''
        rows = listed.get('terminals') if isinstance(listed, dict) else None
        for row in rows if isinstance(rows, list) else []:
            if isinstance(row, dict) and worktree_name and worktree_name in json.dumps(row):
                handle = row.get('handle')
                if isinstance(handle, str) and handle:
                    return handle
        return ''

    def sleep(self, seconds):
        time.sleep(seconds)


def standing_low_context(text, cfg):
    """Reason a standing verifier's screen calls for retirement, else ''."""
    for match in STANDING_CTX_RE.finditer(text or ''):
        if int(match.group(1)) >= cfg['max_context_percent']:
            return 'ctx=%s%%' % match.group(1)
    if STANDING_STOP_RE.search(text or ''):
        return 'stopped_banner'
    for match in STANDING_TURNS_RE.finditer(text or ''):
        if int(match.group(1) or match.group(2)) >= cfg['max_turns']:
            return 'turns=%s' % (match.group(1) or match.group(2))
    return ''


def standing_records(state):
    records = state.get('standing_verifiers')
    if not isinstance(records, dict):
        records = {}
        state['standing_verifiers'] = records
    return records


def _standing_worker(rec, workers):
    for worker in workers or []:
        if isinstance(worker, dict) and worker.get('dispatchId') == rec.get('dispatch_id'):
            return worker
    return None


def _standing_terminal(rec, workers, io=None):
    if rec.get('terminal'):
        return rec['terminal']
    worker = _standing_worker(rec, workers)
    found = worker_terminal_handle(worker) if worker else ''
    if not found and io is not None and hasattr(io, 'resolve_terminal') and rec.get('dispatch_id'):
        slug = re.sub(r'[^a-z0-9]+', '-', str(rec.get('repo') or '').lower()).strip('-')
        found = io.resolve_terminal(rec['dispatch_id'], 'verify-standing-%s' % slug, rec.get('host') or '') or ''
        if found:
            rec['terminal'] = found
    return found


def standing_idle(rec, open_prs):
    """The standing verifier is free: its PR has a Verdict at the assigned head, or is no longer open."""
    if not rec.get('current_pr'):
        return True
    row = open_prs.get((rec.get('repo'), rec.get('current_pr')))
    if row is None:
        return True
    return verdict_posted_for_head(dict(row, headRefOid=rec.get('current_head') or ''))


def standing_retire(state, host, rec, reason, rows, release_worker, now, log_bits, event='retire'):
    """Stop and release a standing verifier, clear its record, and log the retirement."""
    did = rec.get('dispatch_id') or ''
    if did and release_held(state, did):
        log_bits.append('standing_retire_held=%s:%s' % (did, reason))
        return
    if did:
        release_worker(row_for_dispatch(rows, did, '' if rec.get('local') else host))
    standing_records(state).pop(host, None)
    trial_event(
        event, 'standing', host, now, dispatch_id=did, repo=rec.get('repo', ''), prs_done=len(rec.get('prs_assigned') or []),
        reason=reason, duration_s=int(now - (rec.get('started_at') or now)),
    )
    log_bits.append('standing_retire=%s:%s' % (did, reason))


def standing_housekeeping(config, state, workers, open_prs, io, release_worker, now, log_bits):
    """Once per pass: record finished PRs, retire after the last one, and fail a wake that never took."""
    cfg = standing_settings(config)
    failed = set()
    for host, rec in list(standing_records(state).items()):
        if not isinstance(rec, dict):
            standing_records(state).pop(host, None)
            continue
        worker = _standing_worker(rec, workers)
        if workers and (worker is None or not worker_row_is_live(worker)):
            standing_retire(state, host, rec, 'gone', workers, release_worker, now, log_bits)
            continue
        if not rec.get('current_pr'):
            continue
        if standing_idle(rec, open_prs):
            trial_event(
                'verdict', 'standing', host, now, dispatch_id=rec.get('dispatch_id', ''), repo=rec.get('repo', ''),
                pr=rec['current_pr'], head=rec.get('current_head', ''), prs_done=len(rec.get('prs_assigned') or []),
                duration_s=int(now - (rec.get('assigned_at') or now)), headroom_pct=rec.get('headroom', ''),
            )
            rec['current_pr'] = None
            if len(rec.get('prs_assigned') or []) >= cfg['max_prs']:
                standing_retire(state, host, rec, 'max_prs', workers, release_worker, now, log_bits)
            continue
        if rec.get('wake_verified') is False and not rec.get('wake_checked') \
                and now - (rec.get('assigned_at') or now) >= cfg['wake_timeout_seconds']:
            rec['wake_checked'] = True
            text, last = io.read(_standing_terminal(rec, workers, io), host)
            if last == rec.get('assigned_last') and not STANDING_BUSY_RE.search(text or ''):
                failed.add((rec.get('repo'), rec.get('current_pr')))
                (state.get('babysit') or {}).get(rec.get('repo'), {}).pop(str(rec.get('current_pr')), None)
                standing_wake_fail(state, host, rec, 'timeout', workers, release_worker, now, log_bits)
            else:
                rec['wake_verified'] = True
    return failed


def standing_wake_fail(state, host, rec, reason, rows, release_worker, now, log_bits):
    did = rec.get('dispatch_id') or ''
    pr = rec.get('current_pr') or ''
    log_bits.append('standing_wake_fail=%s:%s#%s' % (did, rec.get('repo', ''), pr))
    trial_event(
        'wake_fallback', 'standing', host, now, dispatch_id=did, repo=rec.get('repo', ''), pr=pr,
        head=rec.get('current_head', ''), reason=reason,
    )
    standing_retire(state, host, rec, 'wake_fail', rows, release_worker, now, log_bits, event='retire')


def _pick_headroom(picked):
    selected = (picked or {}).get('selected') if isinstance(picked, dict) else None
    value = selected.get('headroom') if isinstance(selected, dict) else None
    return value if isinstance(value, (int, float)) else None


def trial_fresh_housekeeping(state, open_prs, now):
    """Log the Verdict for each fresh one-shot verifier started during the trial, once its PR has one."""
    bucket = state.get('fresh_verifiers')
    if not isinstance(bucket, dict):
        return
    for did, rec in list(bucket.items()):
        row = open_prs.get((rec.get('repo'), rec.get('pr')))
        if row is None or verdict_posted_for_head(dict(row, headRefOid=rec.get('head') or '')):
            trial_event(
                'verdict', 'fresh', now=now, dispatch_id=did, repo=rec.get('repo', ''), pr=rec.get('pr', ''),
                head=rec.get('head', ''), duration_s=int(now - (rec.get('started_at') or now)),
                headroom_pct='' if rec.get('headroom') is None else rec['headroom'],
            )
            bucket.pop(did, None)


def standing_prompt(repo, pr_row, builder, root, dispatch_id, final):
    number, head = pr_row['number'], pr_row.get('headRefOid') or ''
    who = ('The builder is agent=%s model=%s. Use a different family.' % builder) if builder else 'The builder was not recorded.'
    verify = 'GitHub Checks are green at head %s. Review the diff and run the live checks the PR names.' % head
    prior_fail = prior_verdict_fail(pr_row)
    if prior_fail:
        verify = 'Re-verify after a fix: check only the prior FAIL items and git diff %s..%s.' % (prior_fail[0], head)
    elif checks_local_applies(root):
        verify += ' Run: bash script/checks-local.sh 2>&1 | tail -40.'
    text = (
        'Next PR to verify. Refs %s#%s. headRefOid %s. %s First run: git fetch origin pull/%s/head && git checkout --detach %s. '
        '## Verify: %s Then post the Verdict: script/post-verdict.sh --verifier %s (add --ship on a PASS or PASS+NOTES). Stay at this prompt and do not send worker_done.'
    ) % (repo, number, head, who, number, head, verify, dispatch_id)
    if final:
        text += (' This is your last PR: after posting the Verdict run orca worktree set --worktree active '
                 '--workspace-status completed and send worker_done.')
    return text


def _standing_own_head(state, dispatch_id, repo, number, head):
    """Record the PR head a standing verifier is on, so its death is seen like a fresh one's (#1932)."""
    row = _own_row(state, dispatch_id)
    if row is not None:
        row.update(repo=repo, pr=number, head=head)


def standing_route(
    config, state, workers, repo, pr_row, builder, tag, open_prs, io, start_worker, release_worker,
    now, term_times, log_bits, headroom=None,
):
    """Send an eligible PR to an idle standing verifier, starting one when none exists.

    Returns 'assigned', 'started' or 'fallback' (the caller starts a fresh one-shot verifier).
    """
    cfg = standing_settings(config)
    if not cfg['enabled']:
        return 'fallback'
    number, head = pr_row['number'], pr_row.get('headRefOid') or ''
    key = '%s#%s@%s' % (repo, number, head)
    _startup, _run, _from, roots = babysit_settings(config)
    root = roots.get(repo) or ''
    records = standing_records(state)
    for host in cfg['hosts']:
        if not _agy_signin().usable(cfg['agent'], host, config):
            continue
        rec = records.get(host)
        if isinstance(rec, dict) and not standing_idle(rec, open_prs):
            continue
        if isinstance(rec, dict):
            terminal = _standing_terminal(rec, workers, io)
            text, pre_last = io.read(terminal, host)
            reason = standing_low_context(text, cfg)
            if len(rec.get('prs_assigned') or []) >= cfg['max_prs']:
                reason = reason or 'max_prs'
            if reason:
                standing_retire(state, host, rec, 'low_context' if reason != 'max_prs' else reason, workers, release_worker, now, log_bits)
                rec = None
            else:
                pre_last = pre_last if pre_last is not None else term_times.get(terminal)
                final = len(rec.get('prs_assigned') or []) + 1 >= cfg['max_prs']
                prompt = standing_prompt(repo, pr_row, builder, root, rec['dispatch_id'], final)
                alive = io.send(terminal, prompt, host) and _standing_wake(io, terminal, host, pre_last)
                if not alive:
                    rec.update(current_pr=number, current_head=head)
                    standing_wake_fail(state, host, rec, 'probe', workers, release_worker, now, log_bits)
                    return 'fallback'
                rec['prs_assigned'].append(key)
                _standing_own_head(state, rec['dispatch_id'], repo, number, head)
                _text, last = io.read(terminal, host)
                rec.update(
                    current_pr=number, current_head=head, repo=repo, assigned_at=now, wake_verified=True,
                    assigned_last=last, headroom=headroom if headroom is not None else '',
                )
                trial_event('wake', 'standing', host, now, dispatch_id=rec['dispatch_id'], repo=repo, pr=number, head=head,
                            prs_done=len(rec['prs_assigned']), headroom_pct=headroom if headroom is not None else '')
                return 'assigned'
        command = build_babysit_command(config, repo, pr_row, 'verifier', cfg['agent'], cfg['model'], builder, tag, standing_host=host)
        if command is None:
            return 'fallback'
        result = start_worker(command)
        code, reason = start_result_parts(result)
        if code != 0:
            trial_event('start_fail', 'standing', host, now, repo=repo, pr=number, head=head, reason=reason)
            log_bits.append('standing_start_fail=%s' % number)
            return 'fallback'
        did = dispatch_id_from_start(result)
        records[host] = {
            'dispatch_id': did, 'terminal': getattr(result, 'terminal', '') or '', 'repo': repo, 'host': host,
            'local': _is_local_coordinator_host(host, config), 'current_pr': number, 'current_head': head,
            'prs_assigned': [key], 'started_at': now, 'assigned_at': now, 'wake_verified': True,
            'headroom': headroom if headroom is not None else '',
        }
        trial_event('start', 'standing', host, now, dispatch_id=did, repo=repo, pr=number, head=head,
                    prs_done=1, headroom_pct=headroom if headroom is not None else '')
        remember_started_dispatch(state, result, 'verifier', repo)
        _standing_own_head(state, did, repo, number, head)
        return 'started'
    return 'fallback'


def _standing_wake(io, terminal, host, pre_last):
    """True when the terminal shows life after a send: output advanced or a busy marker, within 15 seconds."""
    for delay in STANDING_PROBE_DELAYS:
        io.sleep(delay)
        text, last = io.read(terminal, host)
        if last is not None and last != pre_last:
            return True
        if STANDING_BUSY_RE.search(text or ''):
            return True
    return False


def tier0_ship_pending(config, state, repo, pr_row):
    """True when a tier 0 PR with Review PASS at its head waits for the auto-ship, so no verifier starts.

    Once the auto-ship has tried this head and the PR is still open, or when fleet-watch does not auto-ship
    this repo, the old rule applies and a verifier starts."""
    head = pr_row.get('headRefOid') or ''
    if pr_tier(pr_row) != 0 or not cold_review_passed_at_head(pr_row):
        return False
    scan = config.get('issue_scan') or {}
    if not scan.get('enabled') or repo not in (scan.get('pr_repos') or scan.get('repos') or []):
        return False
    return not ((state.get('issue_scan_ship') or {}).get(repo) or {}).get(head)


def review_to_verifier_s(pr_row, head, now):
    """Seconds from the newest Review: PASS at this head to now, or None when no such comment is dated (#1321)."""
    stamps = []
    for comment in pr_row.get('comments') or []:
        if not isinstance(comment, dict) or not (comment.get('body') or '').startswith('Review: PASS head=' + head):
            continue
        try:
            stamps.append(datetime.datetime.fromisoformat(str(comment.get('createdAt')).replace('Z', '+00:00')).timestamp())
        except ValueError:
            continue
    return max(0, int(now - max(stamps))) if stamps else None


def body_gate_blocks_verifier(pr_row, workers, state, repo, dry_run, notify_worker, lines, head, log_bits=None):
    """True when the PR body fails pr-body-gate and a live builder can take the rework note (#1323, #1394).

    The note goes to the live, unreleased builder matched by PR number or head branch, once per reason.
    With no such builder nobody can fix the body, so the verifier is not held back.
    """
    number = pr_row.get('number')
    reason = _sibling('pr_body_gate', 'pr-body-gate.py').finish_block_reason(pr_row.get('body') or '')
    if reason and reason.startswith('PR body needs a'):
        reason = None  # a missing Builder line is not a verifier cost: builder_pair falls back to the dispatch record
    notes = state.setdefault('body_gate_notes', {})
    key = '%s#%s' % (repo, number)
    if not reason:
        notes.pop(key, None)
        return False
    branch = pr_row.get('headRefName')
    builder = None
    for worker in workers or []:
        if not isinstance(worker, dict) or _worker_is_verifier(worker):
            continue
        if worker_pr_number(worker) != number and not (branch and worker_branch_name(worker) == branch):
            continue
        if worker_terminal_released(worker) or worker_settled_kind(worker):
            continue
        builder = worker
        break
    if builder is None:
        return False

    def blocked():
        lines.append(_babysit_line(repo, number, head, 'skip', 'body-gate'))
        if log_bits is not None:
            log_bits.append('body_gate=%s' % number)
        return True
    if dry_run or notes.get(key) == reason:
        return blocked()
    if not mail_worker(notify_worker, builder, 'verifier not started: ' + reason, allow_settled=False):
        return False
    notes[key] = reason
    return blocked()


GROK_FALLBACK_TITLE = 'Grok verifier start failed or stalled'


def grok_fell_back(state, repo, number):
    return str(number) in (state.get('grok_fallback') or {}).get(repo, {})


def grok_fallback(state, repo, number, why, file_issue=None):
    """Remember that this PR's verifier no longer takes Grok, and file one issue for a real failure (ADR 0003).

    `why` None is a deferred start (no slot or host): the PR falls back, with no issue. An open issue with the
    same title is reused, and a failed create is tried again at the next failure."""
    state.setdefault('grok_fallback', {}).setdefault(repo, {})[str(number)] = why or 'deferred'
    if why:
        (file_issue or grok_fallback_issue)('%s#%s: %s' % (repo, number, why))


def grok_fallback_issue(detail, find=None, create=None):
    if (find or main_red_find_issue)(FAULT_REPO, GROK_FALLBACK_TITLE):
        return
    body = ('A Grok verifier failed: %s. That PR now gets the next verifier family (ADR 0003).\n\n'
            '## Acceptance\n- [ ] A Grok verifier starts and posts a Verdict (check the folder trust prompt first).'
            % one_line_reason(detail))
    # No labels: an issue scan must not start a builder on a provider fault.
    (create or main_red_create_issue)(FAULT_REPO, GROK_FALLBACK_TITLE, body, labels=())


def grok_fallback_prune(state, repo, open_numbers):
    book = (state.get('grok_fallback') or {}).get(repo)
    if isinstance(book, dict):
        for key in [k for k in book if k not in {str(n) for n in open_numbers}]:
            book.pop(key)


def babysit_pass(
    config, state, workers=None, dry_run=False, persist_state=None,
    pr_fetch=None, start_worker=None, pick=None, owner_check=None,
    release_worker=None, notify_worker=None, now=None, term_times=None,
    closed_fetch=None, runner_fetch=None, standing_io=None, pr_state_fetch=None, file_issue=None,
):
    """One verifier or one fixer per open PR head. Drafts are skipped. Cap defaults to 2."""
    notices = []
    lines = []
    log_bits = []
    repos = babysit_repos(config)
    if not repos:
        return notices, lines, log_bits
    if start_worker is None:
        start_worker = default_babysit_start
    fenced = []
    real_start = start_worker

    handed_start = with_coordinator_handle(config, real_start)

    def start_worker(command):
        # Orca refuses every start from fleet-watch's terminal once it refuses one, so skip the doomed worktree setup.
        if fenced:
            return BabysitStartResult(1, fenced[0])
        result = handed_start(command)
        reason = getattr(result, 'reason', '') or ''
        if result != 0 and 'consumer_fenced' in reason:
            fenced.append(reason)
        return result
    if pick is None:
        pick = pick_role
    if owner_check is None:
        owner_check = pr_owner_only_reason
    if release_worker is None:
        release_worker = _release_row
    if notify_worker is None:
        notify_worker = _default_notify_worker
    if now is None:
        now = time.time()
    if term_times is None:
        term_times = {}
    if pr_fetch is None:
        pr_fetch = fetch_open_prs
    if closed_fetch is None:
        # The open list drops a pull request the moment it merges. The full list is how a live verifier is released.
        closed_fetch = fetch_prs if pr_fetch is fetch_open_prs else (lambda _repo: None)
    if runner_fetch is None:
        runner_fetch = fetch_actions_runners
    _startup, run_id, from_terminal, roots = babysit_settings(config)
    cap = babysit_cap(config)
    started = 0
    picks = {}
    grok_taken = False
    runner_state = {}

    def review_gate_open(pr_row, repo_name):
        """Review: PASS at head, or the repo has no online review runner (one API call per repo per pass)."""
        if review_passed_at_head(pr_row):
            return True
        if _pr_has_review_lane(pr_row):
            return False
        if repo_name not in runner_state:
            try:
                data = runner_fetch(repo_name)
                runner_state[repo_name] = 'online' if has_online_review_runner(data) else 'none'
            except Exception:
                runner_state[repo_name] = 'error'
            if runner_state[repo_name] == 'none':
                log_bits.append('review_gate_no_runner_%s' % repo_name)
            elif runner_state[repo_name] == 'error':
                log_bits.append('review_gate_runner_error_%s' % repo_name)
        return runner_state[repo_name] == 'none'

    def cached_pick(role, avoid_family=None, avoid_provider=None):
        key = (role, avoid_family or '', avoid_provider or '')
        if key not in picks:
            if avoid_family:
                try:
                    extra = {'avoid_provider': avoid_provider} if avoid_provider else {}
                    picks[key] = pick(role, avoid_family=avoid_family, **extra)
                except TypeError:
                    picks[key] = pick(role)
            else:
                picks[key] = pick(role)
        return picks[key]

    # A closed PR gets per PR work only when a live verifier names it, so a pass does not walk every closed PR (#1841).
    verifier_numbers, verifier_branches = live_verifier_claims(workers)
    rows = []
    for index, repo in enumerate(repos):
        prs = pr_fetch(repo)
        fetch_failed = prs is None
        if fetch_failed:
            log_bits.append('fetch_fail')
            prs = []
        closed = []
        open_numbers = set()
        for pr_row in prs:
            if not isinstance(pr_row, dict):
                continue
            if pr_open_for_dispatch(pr_row):
                open_numbers.add(pr_row.get('number'))
                rows.append((index, pr_row.get('number') or 0, repo, pr_row))
            elif _babysit_closed(pr_row):
                closed.append(pr_row)
        if verifier_numbers - open_numbers or verifier_branches:
            closed_rows = closed_fetch(repo)
            if isinstance(closed_rows, list):
                closed += [r for r in closed_rows if isinstance(r, dict) and _babysit_closed(r)]
        released = set()
        for pr_row in closed:
            number = pr_row.get('number')
            if number in open_numbers or number in released:
                continue
            if number not in verifier_numbers and (pr_row.get('headRefName') or '') not in verifier_branches:
                continue
            if dry_run or not release_closed_verifier(pr_row, workers, state, repo, release_worker):
                continue
            released.add(number)
            lines.append(_babysit_line(repo, number or 0, pr_row.get('headRefOid') or '', 'skip', 'verifier-released'))
            if persist_state:
                persist_state()
        if not fetch_failed and not dry_run:
            unknown_builder_prune(state, repo, open_numbers)
            grok_fallback_prune(state, repo, open_numbers)
    # Tier 1 verifiers start before the rest (#1730).
    rows.sort(key=lambda item: (0 if pr_tier(item[3]) == 1 else 1, item[0], item[1]))

    standing_cfg = standing_settings(config)
    if standing_io is None:
        standing_io = StandingIO(config)
    open_prs = {(item[2], item[1]): item[3] for item in rows}
    standing_failed = set()
    if standing_cfg['enabled'] and not dry_run:
        standing_failed = standing_housekeeping(config, state, workers, open_prs, standing_io, release_worker, now, log_bits)
        trial_fresh_housekeeping(state, open_prs, now)
        if persist_state:
            persist_state()

    for _index, _number, repo, pr_row in rows:
        number = pr_row.get('number')
        if deadline_hit(log_bits, 'babysit_deadline=%s' % number):
            break
        head = pr_row.get('headRefOid') or ''
        if pr_row.get('isDraft'):
            lines.append(_babysit_line(repo, number, head, 'skip', 'draft'))
            continue
        if not re.fullmatch(r'[0-9a-f]{40}', head):
            lines.append(_babysit_line(repo, number, head, 'skip', 'bad-head'))
            continue
        if unknown_builder_parked(state, repo, number, head) and _avoid_family(builder_pair(pr_row, workers)):
            # The Builder line (or a matching dispatch) turned up on the same head: lift the park (#1940).
            unknown_builder_clear(state, repo, number)
            log_bits.append('unknown_builder_cleared=%s' % number)
        if unknown_builder_parked(state, repo, number, head):
            lines.append(_babysit_line(repo, number, head, 'skip', 'unknown-builder-parked'))
            continue
        record = babysit_record(state, repo, number)
        reported = record.get('head') == head and record.get('action') == 'report'
        if record.get('head') == head and record.get('action') and not reported:
            failed_did, failed_row = '', None
            if (record.get('action') == 'verifier' and not dry_run and not verdict_posted_for_head(pr_row)
                    and not live_verifier_for_pr(pr_row, workers, state, repo)):
                failed_did, failed_row = dead_verifier(state, workers, repo, number, head)
            if failed_did:
                # The verifier died with no Verdict: release it, then start one fresh verifier. A second
                # death parks the PR (#1221, #1932).
                _own_row(state, failed_did)['startup_handled'] = True
                if failed_row is not None:
                    release_worker(row_for_dispatch(workers, failed_did))
                park_key = park_id('verifier', repo, number, head)
                # A dispatch that is itself a stall restart already was the one retry.
                if _own_row(state, failed_did).get('agent') == 'grok':
                    # The fresh verifier takes the next family and does not use up the one retry (ADR 0003).
                    grok_fallback(state, repo, number, 'verifier ended with no Verdict', file_issue)
                    state['babysit'][repo].pop(str(number), None)
                    log_bits.append('grok_fallback=%s' % number)
                elif not _own_row(state, failed_did).get('retry_of') and startup_retry_taken(state, park_key):
                    state['babysit'][repo].pop(str(number), None)
                    log_bits.append('verifier_startup_retry=%s' % number)
                else:
                    reason = ('verifier failed at startup twice' if worker_startup_failed(failed_row)
                              else 'verifier ended twice with no Verdict')
                    lines.append(_babysit_line(repo, number, head, 'skip', 'start-failed'))
                    if park_failure(state, park_key, reason, config, repo=repo, pr=number, head=head):
                        notices.append(park_notice('verifier', '%s#%s' % (repo, number), reason, None))
                    if persist_state:
                        persist_state()
                    continue
            else:
                lines.append(_babysit_line(repo, number, head, 'skip', 'already'))
                continue
        root = roots.get(repo) if isinstance(roots.get(repo), str) else ''
        repo_root = root if root and os.path.isdir(root) else None
        try:
            owner = owner_check(pr_row, repo_root=repo_root)
        except TypeError:
            owner = owner_check(pr_row)
        if owner == 'error':
            lines.append(_babysit_line(repo, number, head, 'skip', 'owner-check-error'))
            log_bits.append('owner_check_error=%s' % number)
            continue
        if owner and not reported:
            # Report once per head, then fall through: the Verdict is still needed, only ship waits for the owner.
            lines.append(_babysit_line(repo, number, head, 'report', owner))
            notices.append(Urgent(
                'owner-only path on %s#%s (%s); verify only, ship waits for the owner' % (repo, number, owner)
            ))
            log_bits.append('report=%s' % number)
            if not dry_run:
                babysit_mark(state, repo, number, head, 'report')
                if persist_state:
                    persist_state()
        status = head_checks_status(pr_row)
        needs_fix = rework_needed_at_head(pr_row, None, repo, repo_root=repo_root)
        ready = (
            status == 'SUCCESS'
            and not needs_fix
            and pr_row.get('mergeable') not in ('CONFLICTING', 'UNKNOWN')
            and pr_checks_all_success(pr_row)
            and pr_verdict_valid_for_head(pr_row, repo_root=repo_root)
        )
        if (status == 'SUCCESS' and not verdict_posted_for_head(pr_row) and not needs_fix
                and review_gate_open(pr_row, repo)):
            if tier0_ship_pending(config, state, repo, pr_row):
                lines.append(_babysit_line(repo, number, head, 'skip', 'tier0-ship'))
                continue
            kind, role = 'verifier', 'qa-sdet'
        elif needs_fix:
            if release_idle_rework_verifier(
                pr_row, workers, state, repo, now, term_times, release_worker,
            ):
                lines.append(_babysit_line(repo, number, head, 'skip', 'verifier-released'))
                if not dry_run and persist_state:
                    persist_state()
            else:
                lines.append(_babysit_line(repo, number, head, 'skip', 'needs-fix'))
            continue
        elif ready or (status == 'SUCCESS' and verdict_posted_for_head(pr_row)):
            detail = 'ready' if ready else 'has-verdict'
            lines.append(_babysit_line(repo, number, head, 'skip', detail))
            continue
        else:
            lines.append(_babysit_line(repo, number, head, 'skip', 'pending'))
            continue
        if kind == 'verifier' and body_gate_blocks_verifier(
            pr_row, workers, state, repo, dry_run, notify_worker, lines, head, log_bits,
        ):
            if not dry_run and persist_state:
                persist_state()
            continue
        if not run_id or not from_terminal or not root:
            lines.append(_babysit_line(repo, number, head, 'skip', 'no-root'))
            log_bits.append('skip_root=%s' % number)
            continue
        if kind == 'verifier' and live_verifier_for_pr(pr_row, workers, state, repo):
            route = route_rework_head(
                pr_row, workers, state, repo, now, term_times, release_worker, notify_worker,
            )
            detail = {'sticky': 'verifier-sticky', 'released': 'verifier-released'}.get(route, 'verifier-live')
            lines.append(_babysit_line(repo, number, head, 'skip', detail))
            if route in ('sticky', 'released', 'recorded') and not dry_run and persist_state:
                persist_state()
            continue
        park_key = park_id('verifier', repo, number, head)
        if park_is_active(state, park_key, config):
            lines.append(_babysit_line(repo, number, head, 'skip', 'parked'))
            continue
        # A tier 1 verifier is outside the per pass cap (#1730).
        step = 0 if kind == 'verifier' and pr_tier(pr_row) == 1 else 1
        if started >= cap and step:
            lines.append(_babysit_line(repo, number, head, 'skip', 'cap'))
            log_bits.append('cap')
            count_refused('host_cap')
            continue
        builder = builder_pair(pr_row, workers)
        if builder and kind == 'verifier' and not builder_pair_from_body(pr_row):
            log_bits.append('builder_from_dispatch=%s:%s/%s' % (number, builder[0], builder[1]))
            if not dry_run:
                log_fleet_watch('%s#%s head %s: no Builder line in the PR body, builder taken from its dispatch: agent=%s model=%s'
                                % (repo, number, head[:8], builder[0], builder[1]))
        avoid = builder if kind == 'verifier' else None
        avoid_fam = _avoid_family(avoid) if avoid else None
        if kind == 'verifier' and not avoid_fam:
            lines.append(_babysit_line(repo, number, head, 'skip', 'unknown-builder-family'))
            log_bits.append('unknown_builder=%s' % number)
            count_refused('builder')
            if not dry_run and unknown_builder_refused(state, repo, number, head):
                notices.append(Urgent(
                    '%s#%s head %s: no builder agent and model, so no verifier family can be chosen; '
                    'skipped until the head changes (add a Builder: line to the PR body and push)' % (repo, number, head[:8])))
                if persist_state:
                    persist_state()
            continue
        # A PR whose Grok verifier failed or stalled takes the next family (ADR 0003).
        no_grok = 'grok' if kind == 'verifier' and (grok_taken or grok_fell_back(state, repo, number)) else None
        picked = cached_pick(role, avoid_fam, no_grok)
        chosen = choose_pick(picked, avoid=avoid)
        if not chosen:
            why = pick_failure_reason(picked, avoid)
            lines.append(_babysit_line(repo, number, head, 'skip', 'no-pick'))
            log_bits.append('pick_fail=%s:%s' % (number, why))
            count_refused('builder' if why == 'builder' else 'usage_gate')
            continue
        agent, model, tag = chosen
        detail = 'agent=%s model=%s' % (agent, model)
        if tag:
            detail = '%s %s' % (detail, tag)
        action = 'verifier' if kind == 'verifier' else 'fixer'
        if dry_run:
            grok_taken = grok_taken or (kind == 'verifier' and agent == 'grok')
            lines.append(_babysit_line(repo, number, head, action, detail))
            started += step
            continue
        if not start_fits_pass(agent_start_cost(agent)):
            lines.append(_babysit_line(repo, number, head, 'skip', 'deadline'))
            log_bits.append('start_deadline=%s' % number)
            continue
        if kind == 'verifier':
            # The pass list can be minutes old and may be cached, so read the open list again just before the start (#1706).
            live_state = pr_open_now(repo, number, pr_state_fetch or pr_fetch)
            if live_state != 'OPEN':
                lines.append(_babysit_line(repo, number, head, 'skip', 'not-open' if live_state else 'state-unknown'))
                log_bits.append('not_open=%s' % number)
                continue
        headroom = _pick_headroom(picked)
        if kind == 'verifier' and standing_cfg['enabled'] and agent == 'antigravity' \
                and (repo, number) not in standing_failed:
            routed = standing_route(
                config, state, workers, repo, pr_row, builder, tag, open_prs, standing_io, start_worker,
                release_worker, now, term_times, log_bits, headroom,
            )
            if routed in ('assigned', 'started'):
                babysit_mark(state, repo, number, head, action)
                started += step if routed == 'started' else 0
                if routed == 'started':
                    count_worker_started()
                else:
                    count_started()
                lines.append(_babysit_line(repo, number, head, action, detail + ' standing=' + routed))
                log_bits.append('standing_%s=%s' % (routed, number))
                if persist_state:
                    persist_state()
                continue
        # A verifier for a Review PASS head may take one seat over work_order.max_workers, so merges are not blocked (#1957).
        if kind == 'verifier' and at_max_workers(config, workers, slack=1 if review_passed_at_head(pr_row) else 0):
            lines.append(_babysit_line(repo, number, head, 'skip', 'max-workers'))
            log_bits.append('max_workers=%s' % number)
            count_refused(MAX_WORKERS_REASON)
            continue
        command = build_babysit_command(config, repo, pr_row, kind, agent, model, builder, tag)
        if command is None:
            lines.append(_babysit_line(repo, number, head, 'skip', 'no-root'))
            continue
        # No start_allowed hold here: a verifier starts on Review PASS within the usage gate and host caps (owner 2026-11-25, #1838).
        # start_fits_pass above still holds a start that would end past PASS_HARD_END (#1820).
        started_worker = start_worker(command)
        code, reason = start_result_parts(started_worker)
        # An Orca fence on fleet-watch's own terminal (#1170) is not a Grok fault: it parks and hands off as before.
        grok_verifier = kind == 'verifier' and agent == 'grok' and 'consumer_fenced' not in (reason or '')
        if (code != 0 and code not in BABYSIT_DEFERRED_EXITS and not grok_verifier and startup_failure_text(reason)
                and startup_retry_taken(state, park_key)):
            log_bits.append('startup_retry=%s' % number)
            started_worker = start_worker(command)
            code, reason = start_result_parts(started_worker)
        if code != 0:
            suffix = ':' + reason if reason else ''
            if grok_verifier:
                # No park: the next pass starts this PR on the next family. A deferred start files no issue.
                grok_fallback(state, repo, number, None if code in BABYSIT_DEFERRED_EXITS else reason or 'start failed',
                              file_issue)
                lines.append(_babysit_line(repo, number, head, 'skip', 'grok-fallback'))
                log_bits.append('grok_fallback=%s%s' % (number, suffix))
                if persist_state:
                    persist_state()
                continue
            if code in BABYSIT_DEFERRED_EXITS:
                # The usage gate or host placement said wait. That is not a failed start, so the next pass retries.
                lines.append(_babysit_line(repo, number, head, 'skip', 'start-deferred'))
                log_bits.append('start_deferred=%s%s' % (number, suffix))
                continue
            lines.append(_babysit_line(repo, number, head, 'skip', 'start-failed'))
            log_bits.append('start_fail=%s%s' % (number, suffix))
            if standing_cfg['enabled'] and action == 'verifier':
                trial_event('start_fail', 'fresh', now=now, repo=repo, pr=number, head=head, reason=reason)
            if park_failure(state, park_key, reason, config, repo=repo, pr=number, head=head):
                notices.append(park_notice('verifier', '%s#%s' % (repo, number), reason, command))
            continue
        # The cached pick was read before this start, so the rest of the pass counts the Grok slot as taken.
        grok_taken = grok_taken or (kind == 'verifier' and agent == 'grok')
        babysit_mark(state, repo, number, head, action)
        if action == 'verifier':
            remember_started_dispatch(state, started_worker, 'verifier', repo)
            own = _own_row(state, dispatch_id_from_start(started_worker))
            if own is not None:
                own.update(repo=repo, pr=number, head=head, agent=agent)
            _verifier_head_bucket(state, repo)[str(number)] = head
            if standing_cfg['enabled']:
                did = dispatch_id_from_start(started_worker)
                state.setdefault('fresh_verifiers', {})[did or '%s#%s@%s' % (repo, number, head)] = {
                    'repo': repo, 'pr': number, 'head': head, 'started_at': now, 'headroom': headroom,
                }
                trial_event('start', 'fresh', now=now, dispatch_id=did, repo=repo, pr=number, head=head,
                            headroom_pct='' if headroom is None else headroom)
        started += step
        count_worker_started()
        gap = review_to_verifier_s(pr_row, head, now) if action == 'verifier' else None
        lines.append(_babysit_line(repo, number, head, action, detail if gap is None else '%s review_to_verifier_s=%d' % (detail, gap)))
        log_bits.append('%s=%s' % (action, number))
        if gap is not None:
            log_bits.append('review_to_verifier_s=%d' % gap)
        if persist_state:
            persist_state()
    return notices, lines, log_bits


FAILURE_STREAK_PASSES = 3


def failure_streak_notices(state, key, failing, text):
    """One notice when `key` fails for 3 passes in a row; none again until a pass clears it."""
    streaks = state.setdefault('failure_streaks', {})
    if not failing:
        streaks.pop(key, None)
        return []
    entry = streaks.setdefault(key, {'passes': 0, 'notified': False})
    entry['passes'] += 1
    if entry['passes'] >= FAILURE_STREAK_PASSES and not entry['notified']:
        entry['notified'] = True
        return [Urgent('%s (%d passes in a row)' % (text, entry['passes']))]
    return []


ISSUE_DEFER_ESCALATE_PASSES = 3  # owner 2026-11-24 (#1778): the same deferral reason for 3 passes goes to elon
ISSUE_DEFER_GAP_SECONDS = 1800  # a longer gap between two deferrals starts the pass count over
PR_UNOWNED_SECONDS = 3600  # a PR with no live owner worker and no progress this long goes to elon


def _is_dotfiles_repo(repo):
    return str(repo).rsplit('/', 1)[-1] == 'dotfiles'


def defer_issue(state, now, repo, number, reason, deferred, notices, log_bits, persist_state=None):
    """Record that a ready issue was not started this pass (#1778).

    Counts consecutive passes with the same reason and escalates to elon on the third. A dotfiles
    issue is also written to state['dotfiles_deferred'], which worker-startup reads so that a
    dotfiles issue that cannot start does not hold back other repos."""
    reason = re.sub(r'[,;\s]+', ' ', str(reason or 'unknown')).strip()[:80] or 'unknown'
    deferred.append(reason)
    log_bits.append('issue_deferred=%d:%s' % (number, reason))
    book = state.setdefault('issue_scan_deferred', {})
    repo_book = book.setdefault(repo, {})
    for key in [k for k, e in repo_book.items() if now - float(e.get('at', 0)) > ISSUE_DEFER_GAP_SECONDS]:
        repo_book.pop(key)
    entry = repo_book.get(str(number))
    if entry and entry.get('reason') == reason:
        if entry.get('at') != now:
            entry['passes'] = int(entry.get('passes', 1)) + 1
        entry['at'] = now
    else:
        entry = repo_book[str(number)] = {'reason': reason, 'passes': 1, 'at': now}
    # Waiting at max_workers is the ceiling working, not a stuck start, so it never escalates (#1957).
    if entry['passes'] >= ISSUE_DEFER_ESCALATE_PASSES and not entry.get('notified') and reason != MAX_WORKERS_REASON:
        entry['notified'] = True
        notices.append(Urgent('%s #%d deferred %d passes in a row (%s): elon resolves it this wake' % (
            repo, number, entry['passes'], reason)))
    if _is_dotfiles_repo(repo):
        state.setdefault('dotfiles_deferred', {})[str(number)] = now
    if persist_state:
        persist_state()


def clear_issue_deferral(state, repo, number):
    state.get('issue_scan_deferred', {}).get(repo, {}).pop(str(number), None)
    state.get('dotfiles_deferred', {}).pop(str(number), None)


def pr_has_owner_worker(workers, pr_row):
    """A live non verifier worker on the PR: its number or branch, or a `#<issue>|` title for an issue the PR closes or refs (#1778)."""
    number = pr_row.get('number')
    body = pr_row.get('body') or ''
    branch = pr_row.get('headRefName') or ''
    issues = set(re.findall(r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\s*:?\s+(?:[\w.-]+/[\w.-]+)?#(\d+)', body, re.I))
    issues |= set(re.findall(r'(?<!\d)(\d{2,})(?!\d)', branch))
    for w in workers or ():
        if not isinstance(w, dict) or not worker_row_is_live(w) or _worker_titled_verifier(w):
            continue
        title = str(w.get('_task_title') or w.get('title') or '')
        match = re.match(r'#(\d+)\|', title)
        if match and (match.group(1) in issues or match.group(1) == str(number)):
            return True
    return pr_has_live_fix_worker([w for w in workers or () if isinstance(w, dict) and not _worker_titled_verifier(w)], pr_row)


def pr_unowned_notice(state, now, repo, pr_row, workers):
    """An Urgent line once per head for a PR with no live owner worker and no progress for 60 minutes, else None (#1778)."""
    updated = _iso_epoch(pr_row.get('updatedAt'))
    if updated is None or now - updated < PR_UNOWNED_SECONDS:
        return None
    if pr_has_owner_worker(workers, pr_row):
        return None
    head = pr_row.get('headRefOid') or ''
    noted = state.setdefault('issue_scan_pr_unowned', {}).setdefault(repo, {})
    key = str(pr_row['number'])
    if noted.get(key) == head:
        return None
    noted[key] = head
    return Urgent('%s #%d has no live owner worker and no progress for %d minutes: elon resolves it this wake' % (
        repo, pr_row['number'], int((now - updated) // 60)))


def fill_gap_notice(config, now, workers, log_bits, deferred):
    """`fill gap: L of T live, K ready not started (reasons)` when starts were refused below target_workers, else None (#1778)."""
    order = work_order_settings(config)
    if order is None or not deferred:
        return None
    cap = work_order_max_workers(config)
    if cap is not None and MAX_WORKERS_REASON in deferred:
        return 'fill gap: %d of %d live, %d ready issue(s) not started (%s), at max_workers %d' % (
            fleet_live_count(workers), order[1], len(deferred), _deferred_reasons(deferred), cap)
    started = sum(1 for bit in log_bits if bit.startswith(('issue_start=', 'rework_start=', 'supply_start=')))
    live = active_worker_count(workers) + started
    if live >= order[1]:
        return None
    return 'fill gap: %d of %d live, %d ready issue(s) not started (%s), elon tops up by hand' % (
        live, order[1], len(deferred), _deferred_reasons(deferred))


def _deferred_reasons(deferred):
    reasons = {}
    for reason in deferred:
        reasons[reason] = reasons.get(reason, 0) + 1
    return ', '.join('%s x%d' % (r, n) for r, n in sorted(reasons.items()))


def issue_scan_pass(config, state, now, workers, *args, **kwargs):
    """The pass of `_issue_scan_pass`, plus one fill-gap line when starts fell short of target_workers (#1778)."""
    deferred = []
    notices, log_bits = _issue_scan_pass(config, state, now, workers, *args, deferred=deferred, **kwargs)
    gap = fill_gap_notice(config, now, workers, log_bits, deferred)
    if gap:
        notices.append(gap)
    return notices, log_bits


def _issue_scan_pass(
    config, state, now, workers, list_issues=None, pr_fetch=None,
    gate_check=None, admit_fn=None, start_worker=None,
    inventory_ok=True, persist_state=None, act=None,
    start_detached=None, checks_lock_live=None, workflow_watch_prior=None,
    babysit_repos=None, repo_id_lookup=None, pick_fn=None, list_backlog=None, red_gates=None,
    issue_state=None,
    deferred=None, list_claimed=None, count_open=None, list_blocked=None, ref_state=None,
):
    """Start every eligible ready issue the host caps and the usage gate allow, and one rework worker per new failing review head."""
    notices = []
    log_bits = []
    deferred = [] if deferred is None else deferred
    babysit_owned = set(babysit_repos or ())
    scan = config.get('issue_scan') or {}
    if not scan.get('enabled'):
        return notices, ['issue_scan_off']

    if not inventory_ok:
        log_bits.append('issue_scan_inventory_failed')
        return notices, log_bits

    if gate_check is None:
        gate_check = default_issue_scan_gate
    if admit_fn is None:
        admit_fn = admit
    if start_worker is None:
        start_worker = default_issue_scan_start
    start_worker = with_coordinator_handle(config, start_worker)
    if act is None:
        act = run_gh
    if start_detached is None:
        start_detached = default_detached_start

    host = scan.get('host') or 'local'
    seen_refusals = len(USAGE_GATE_REFUSALS)
    if not gate_check(config):
        fresh = USAGE_GATE_REFUSALS[seen_refusals:]
        reason = one_line_reason(fresh[-1].get('reason') if fresh else 'unknown')
        count_refused('usage_gate')
        return notices, ['issue_scan_gate=%s' % reason]
    admission = admit_fn(host, config, workers)
    refused = not admission.get('admitted')
    reason = re.sub(r'[,;\s]+', ' ', str(admission.get('reason') or 'unknown')).strip()
    notices += failure_streak_notices(
        state, 'issue_scan_refused', refused, 'issue scan refused on %s: %s' % (host, reason))
    # Hosts a ready issue may spill to when the local cap is full, even when local admission passed (#2012).
    spill_hosts = [h for h in (config.get('host_caps') or {}) if not _is_local_coordinator_host(h, config) and h != host]
    remote_hosts = []
    if refused:
        log_bits = ['issue_scan_load', 'issue_scan_refused=%s' % reason]
        count_refused(refusal_token(reason))
        remote_hosts = list(spill_hosts)
    extra_starts = 0
    repos = scan.get('repos') or []
    if pr_fetch is None:
        pr_fetch = fetch_prs
    pr_repos = scan.get('pr_repos') or repos
    needs_elon = (config.get('worker_stall') or {}).get('needs_elon_label', 'needs-elon')
    needs_redesign = (config.get('worker_stall') or {}).get('needs_redesign_label', 'needs-redesign')
    ship_heads = state.setdefault('issue_scan_ship', {})
    rework_heads = state.setdefault('issue_scan_rework', {})
    rework_pending = state.setdefault('issue_scan_rework_pending', {})
    rework_rounds = state.setdefault('issue_scan_rework_rounds', {})
    rework_escalated = state.setdefault('issue_scan_rework_escalated', {})
    if workflow_watch_prior is None:
        workflow_watch_prior = state.get('workflow_watch') or {}

    listed = {}
    for repo in pr_repos:
        if deadline_hit(log_bits, 'issue_scan_deadline'):
            break
        prs = pr_fetch(repo)
        listed[repo] = prs
        if prs is None:
            continue
        root = _issue_scan_repo_root(config, repo)
        shipped = ship_heads.setdefault(repo, {})
        seen = rework_heads.setdefault(repo, {})
        pending = rework_pending.setdefault(repo, {})
        rounds = rework_rounds.setdefault(repo, {})
        escalated = rework_escalated.setdefault(repo, {})
        fail_noted = state.setdefault('issue_scan_fail_noted', {}).setdefault(repo, {})
        for pr_row in prs:
            if deadline_hit(log_bits, 'issue_scan_deadline'):
                break
            if not pr_open_for_dispatch(pr_row) or pr_row.get('isDraft'):
                continue
            if pr_has_label(pr_row, needs_elon) or pr_has_label(pr_row, needs_redesign):
                continue
            head = pr_row.get('headRefOid') or ''
            if not head:
                continue
            pr_num = pr_row['number']
            unowned = pr_unowned_notice(state, now, repo, pr_row, workers)
            if unowned:
                notices.append(unowned)
                log_bits.append('pr_unowned=%d' % pr_num)
                if persist_state:
                    persist_state()
            needs_head_checks = (
                bool(root)
                and not checks_receipt_at_head(pr_row)
                and not checks_pass_at_head(pr_row)
                and not review_failed_at_head(pr_row)
                and not pr_checks_all_success(pr_row)
            )
            if needs_head_checks:
                held = red_gate_hold(pr_row, lambda repo=repo: (red_gates or fetch_red_gate_numbers)(repo))
                if held:
                    needs_head_checks = False
                    log_bits.append('head_checks_red_gate=%s#%d' % (head[:8], held))
            if needs_head_checks and checks_infra_runs(pr_row) > head_checks_infra_cap(config):
                needs_head_checks = False
                capped = state.setdefault('head_checks_infra_capped', {}).setdefault(repo, {})
                if not capped.get(head):
                    capped[head] = True
                    notices.append('head checks INFRA on %s#%s at %s, rerun cap %d reached, no more reruns' % (
                        repo, pr_num, head[:8], head_checks_infra_cap(config)))
                    if persist_state:
                        persist_state()
            if needs_head_checks and refused:
                log_bits.append('head_checks_held=%s' % head[:8])
            elif needs_head_checks:
                hc_key = park_id('head_checks', repo, pr_num, head)
                if park_is_active(state, hc_key, config):
                    log_bits.append('head_checks_parked=%s' % head[:8])
                elif not head_checks_lock_live(root, lock_live=checks_lock_live):
                    command = build_head_checks_command(config, repo, pr_row)
                    if command:
                        code, reason = start_result_parts(start_detached(command))
                        if code == 0:
                            log_bits.append('head_checks_start=%s' % head[:8])
                            count_started()
                            if persist_state:
                                persist_state()
                        else:
                            if park_failure(state, hc_key, reason, config, repo=repo, pr=pr_num, head=head):
                                notices.append(park_notice('head checks', '%s#%s' % (repo, pr_num), reason))
                            if persist_state:
                                persist_state()
                            suffix = ':%s' % reason if reason else ''
                            log_bits.append('head_checks_fail=%s%s' % (head[:8], suffix))
            if repo in babysit_owned:
                owner_reason = pr_owner_only_reason(
                    pr_row, repo_root=root if root and os.path.isdir(root) else None,
                )
                if owner_reason and owner_reason != 'error':
                    log_bits.append('babysit_owner_skip=%d' % pr_num)
                    continue
            pr_class = classify_open_pr(pr_row, workflow_watch_prior, repo, repo_root=root)
            if pr_class == 'ready':
                if shipped.get(head):
                    continue
                # The verifier ships right after its PASS (#1679). This fallback waits 15 minutes for it.
                if verdict_age_seconds(pr_row, now) < SHIP_FALLBACK_AFTER:
                    log_bits.append('ship_wait=%d' % pr_num)
                    continue
                command = build_ship_command(repo, pr_row, root)
                if not start_allowed(start_cost(command)):
                    log_bits.append('ship_budget=%d' % pr_num)
                    continue
                shipped[head] = True
                if persist_state:
                    persist_state()
                code, reason = start_result_parts(start_worker(command))
                if code == 0:
                    notices.append('ship %s #%d %s' % (repo, pr_num, head[:8]))
                    log_bits.append('ship_start=%s' % head[:8])
                    count_started()
                else:
                    # Once per head: shipped[head] is already set, so there is no retry loop.
                    notices.append('ship refused %s #%d %s: %s' % (repo, pr_num, head[:8], reason or 'exit %d' % code))
                    log_bits.append('ship_fail=%d' % pr_num)
                    count_failed()
                continue
            if pr_class != 'needs_fix':
                continue
            if (checks_fail_is_host_fault(pr_row)
                    and not pr_has_conflict(pr_row, repo_root=root)
                    and not pr_has_unresolved_threads(pr_row)
                    and not review_failed_at_head(pr_row)):
                noticed = state.setdefault('checks_rerun_noticed', {}).setdefault(repo, {})
                if not noticed.get(head):
                    noticed[head] = True
                    rerun = build_head_checks_command(config, repo, pr_row)
                    notices.append(Urgent('rerun checks %s#%d at %s: host fault, the code was not judged, not a rework%s' % (
                        repo, pr_num, head[:8], (': ' + shlex.join(rerun)) if rerun else '')))
                    if persist_state:
                        persist_state()
                log_bits.append('checks_rerun_only=%d' % pr_num)
                continue
            if seen.get(head) or pending.get(head):
                continue
            if review_failed_at_head(pr_row):
                # A FAIL goes to architect-pm for redesign first, never to an automatic builder (#1209).
                if not fail_noted.get(head):
                    fail_noted[head] = True
                    notices.append('FAIL: send to architect-pm: %s #%d %s' % (repo, pr_num, head[:8]))
                    if persist_state:
                        persist_state()
                log_bits.append('rework_fail_digest=%d' % pr_num)
                continue
            if pr_has_live_fix_worker(workers, pr_row):
                log_bits.append('rework_live=%d' % pr_num)
                continue
            pr_key = str(pr_num)
            if escalated.get(pr_key):
                continue
            if rounds.get(pr_key, 0) >= 2:
                if act(['gh', 'pr', 'edit', str(pr_num), '--repo', repo, '--add-label', needs_redesign]) != 0:
                    log_bits.append('rework_cap_label_fail=%d' % pr_num)
                escalated[pr_key] = True
                notices.append(Urgent('%s #%d needs redesign' % (repo, pr_num)))
                log_bits.append('rework_cap=%d' % pr_num)
                if persist_state:
                    persist_state()
                continue
            park_key = park_id('rework', repo, pr_num, head, int(rounds.get(pr_key, 0)) + 1)
            if park_is_active(state, park_key, config):
                log_bits.append('rework_parked=%d' % pr_num)
                continue
            if at_max_workers(config, workers):
                log_bits.append('rework_max_workers=%d' % pr_num)
                count_refused(MAX_WORKERS_REASON)
                continue
            if not _issue_scan_has_slot(host, config, admission, extra_starts):
                count_refused('host_cap')
                continue
            route = None
            if rework_needs_strong(repo, pr_row, int(rounds.get(pr_key, 0))):
                route = choose_pick((pick_fn or pick_role)('fullstack-dev', tier='strong'))
                log_bits.append('rework_strong=%d:%s' % (pr_num, route[1] if route else 'none'))
            command = build_rework_start_command(config, repo, pr_row, route)
            if command is None:
                log_bits.append('rework_skip=%d' % pr_num)
                continue
            if live_start_title(command, workers):
                log_bits.append('rework_live=%d' % pr_num)
                continue
            if not start_allowed(start_cost(command)):
                log_bits.append('rework_budget=%d' % pr_num)
                continue
            pending[head] = True
            if persist_state:
                persist_state()
            started_worker = start_worker(command)
            code, reason = start_result_parts(started_worker)
            if code in BABYSIT_DEFERRED_EXITS:
                pending.pop(head, None)
                if persist_state:
                    persist_state()
                suffix = ':%s' % reason if reason else ''
                log_bits.append('rework_deferred=%d%s' % (pr_num, suffix))
                continue
            if code == 0:
                remember_started_dispatch(state, started_worker, 'rework', repo)
                seen[head] = True
                pending.pop(head, None)
                conflict_only = (
                    pr_has_conflict(pr_row, repo_root=root)
                    and not pr_has_unresolved_threads(pr_row)
                    and not review_failed_at_head(pr_row)
                    and not pr_red_check_in_diff(pr_row, workflow_watch_prior, repo)
                )
                if not conflict_only:
                    rounds[pr_key] = rounds.get(pr_key, 0) + 1
                extra_starts += 1
                notices.append('rework %s #%d %s' % (repo, pr_num, head[:8]))
                log_bits.append('rework_start=%s' % head[:8])
                count_worker_started()
                if persist_state:
                    persist_state()
            else:
                pending.pop(head, None)
                if park_failure(state, park_key, reason, config, repo=repo, pr=pr_num, head=head):
                    notices.append(park_notice('rework', '%s#%s' % (repo, pr_num), reason, command))
                if persist_state:
                    persist_state()
                suffix = ':%s' % reason if reason else ''
                log_bits.append('rework_fail=%d%s' % (pr_num, suffix))

    prune_closed_maps(state, listed, {})

    if list_claimed is None:
        # A caller that injects the ready list (tests) gets no claimed list unless it injects one too.
        list_claimed = fetch_claimed_issues if list_issues is None else (lambda _repo: [])
    if list_issues is not None:
        # A caller that injects the ready list (tests) sees no open issue and no blocked issue unless it injects them (#1876).
        count_open = count_open or (lambda _repo: 0)
        list_blocked = list_blocked or (lambda _repo: [])
    if list_issues is None:
        list_issues = fetch_ready_issues
    if issue_state is None:
        # A Blocked by ref may be a PR, which `gh issue view` refuses (#2027).
        issue_state = fetch_ref_state
    blocker_states = {}

    started = state.setdefault('issue_scan_started', {})
    issue_pending = state.setdefault('issue_scan_pending', {})

    def issue_already_claimed(repo, number):
        return number in issue_pending.get(repo, [])

    started_at = state.setdefault('issue_scan_started_at', {})

    def started_is_stale(repo, number):
        # A start this recent may not show in the worker inventory or the label yet, so it still blocks (#1216).
        # An entry from before #1811 has no time and counts as stale.
        at = started_at.get(repo, {}).get(str(number))
        return at is None or now - float(at) >= ISSUE_RESTART_GRACE_SECONDS

    def restart_started(repo, number, why):
        # A started issue with no live worker and no open PR starts again (#1811).
        started[repo].remove(number)
        started_at.get(repo, {}).pop(str(number), None)
        log_bits.append('issue_restart=%d:%s' % (number, why))
        notices.append('issue %s #%d restarted: no open PR and no live worker' % (repo, number))
        if persist_state:
            persist_state()

    candidates = []
    ready_queue_count = 0
    list_failed = False
    for repo in repos:
        if deadline_hit(log_bits, 'issue_scan_deadline'):
            break
        issues = list_issues(repo)
        if issues is None:
            log_bits.append('issue_scan_list_failed')
            list_failed = True
            continue
        ready_queue_count += len(issues)
        for row in issues:
            live_ref = issue_live_ref(workers, row)
            if live_ref is not None:
                log_bits.append('issue_live=%d' % row['number'] + ('' if live_ref == row['number'] else ':ref=%d' % live_ref))
                continue
            if not issue_scan_eligible(row):
                continue
            if issue_already_claimed(repo, row['number']):
                continue
            if repo not in listed:
                listed[repo] = pr_fetch(repo)
            if open_pr_for_issue(listed[repo], row['number']):
                log_bits.append('issue_open_pr=%d' % row['number'])
                continue
            restart = row['number'] in started.get(repo, [])
            if restart and listed[repo] is None:
                # An unreadable PR list could hide the PR this start opened, so it still blocks.
                log_bits.append('issue_restart_skipped=%d:pr_list' % row['number'])
                continue
            if restart and not started_is_stale(repo, row['number']):
                continue
            open_blockers, unknown_blockers = issue_open_blockers(row, repo, issue_state, blocker_states)
            if open_blockers or unknown_blockers:
                # Not ready work, so it does not count as supply either (#1788).
                ready_queue_count -= 1
                if open_blockers:
                    log_bits.append('issue_blocked=%d:by=%s' % (
                        row['number'], ','.join(_blocker_label(ref, repo) for ref in open_blockers)))
                if unknown_blockers:
                    log_bits.append('issue_blocker_unknown=%d:by=%s' % (
                        row['number'], ','.join(_blocker_label(ref, repo) for ref in unknown_blockers)))
                continue
            updated = row.get('updatedAt') or ''
            if park_is_active(state, park_id('issue', repo, row['number'], updated), config):
                log_bits.append('issue_parked=%d' % row['number'])
                continue
            if overlap_hold(state, repo, row, listed[repo]):
                # check-issue-overlap refused this brief against these PRs: no start time until either changes (#2062).
                defer_issue(state, now, repo, row['number'], 'overlap_held', deferred, notices, log_bits, persist_state)
                continue
            if restart:
                restart_started(repo, row['number'], 'ready')
            candidates.append((repo, row))
        listed_numbers = {r['number'] for r in issues}
        if started.get(repo):
            for claimed in list_claimed(repo) or []:
                number = claimed.get('number')
                if number not in started[repo] or number in listed_numbers or not started_is_stale(repo, number):
                    continue
                if issue_has_live_dispatch(workers, number) or number in issue_pending.get(repo, []):
                    continue
                if repo not in listed:
                    listed[repo] = pr_fetch(repo)
                if listed[repo] is None:
                    log_bits.append('issue_restart_skipped=%d:pr_list' % number)
                    continue
                if open_pr_for_issue(listed[repo], number):
                    continue
                # The claim took ready-for-agent off, so put it back: the next pass lists and starts the issue (#1811).
                # A failed edit keeps the issue in started, so a later pass tries again.
                if act(['gh', 'issue', 'edit', str(number), '--repo', repo,
                        '--add-label', 'ready-for-agent', '--remove-label', ISSUE_CLAIM_LABEL]) == 0:
                    restart_started(repo, number, 'orphaned')

    supply_line = None if list_failed else work_order_supply_line(config, now, workers, len(candidates), host, admission, waiting_on_coordinator(state, workers))
    if supply_line:
        notices.append(supply_line)

    def pr_list_for(repo):
        if repo not in listed:
            listed[repo] = pr_fetch(repo)
        return listed[repo]

    def try_supply(reserved):
        if list_failed:
            return 0
        state['work_order_last_supply'] = len(candidates)  # the next pass's early supply step reads it (#1904)
        if state.get('work_order_supply_first_at') == now:
            # The early step of this pass already tried supply (#1904); a start there still takes a seat here.
            log_bits.append('supply_ran_first')
            return 1 if state.get('work_order_supply_at') == now else 0
        bits, used = work_order_try_supply(
            config, state, now, repos, len(candidates), host, admission, extra_starts, reserved, workers,
            start_worker, pick_fn, persist_state, count_open,
            lambda rs: clear_stale_blocked(rs, list_blocked, ref_state, act),
            lambda rs: stale_claimed_issues(state, now, workers, list_claimed, rs, pr_list_for),
        )
        log_bits.extend(bits)
        return used

    if refused and not remote_hosts:
        # Local admission refused and no other host exists: every ready issue is deferred, and elon hears the gap (#1778).
        for repo, row in candidates:
            defer_issue(state, now, repo, row['number'], refusal_token(reason) or 'host_cap', deferred, notices, log_bits, persist_state)
        return notices, log_bits

    if not candidates and remote_hosts:
        log_bits.append('issue_scan_none')
        return notices, log_bits
    if not candidates:
        supply_used = try_supply(0)
        extra_starts += supply_used
        if supply_used:
            triage_bits, triage_used = ['triage_skip_supply'], 0  # the supply brief triages too (#1689)
        else:
            triage_bits, triage_used = ([], 0) if list_failed else issue_scan_try_triage(
                config, state, now, repos, host, admission, extra_starts, workers,
                start_worker, list_backlog, pick_fn, persist_state, notices,
            )
        log_bits.extend(triage_bits)
        no_work = None if list_failed else work_order_no_work_notice(config, state, now, workers, ready_queue_count)
        if no_work:
            notices.append(no_work)
        extra_starts += triage_used
        queue_count = None if list_failed else ready_queue_count
        sweep_bits = ['backlog_sweep_max_workers'] if at_max_workers(config, workers) else issue_scan_try_backlog_sweep(
            config, state, now, repos, queue_count, host, admission, extra_starts, workers,
            start_worker, persist_state,
        )
        log_bits.extend(sweep_bits)
        if not any(bit.startswith('backlog_sweep_start=') for bit in sweep_bits):
            log_bits.append('issue_scan_none')
        return notices, log_bits

    candidates.sort(key=lambda pair: issue_scan_queue_key(*pair))
    if at_max_workers(config, workers):
        count_refused(MAX_WORKERS_REASON)
        for repo, row in candidates:
            defer_issue(state, now, repo, row['number'], MAX_WORKERS_REASON, deferred, notices, log_bits, persist_state)
        return notices, log_bits
    if not spill_hosts and not _issue_scan_has_slot(host, config, admission, extra_starts):
        count_refused('host_cap')
        for repo, row in candidates:
            defer_issue(state, now, repo, row['number'], 'host_cap', deferred, notices, log_bits, persist_state)
        return notices, log_bits

    if not remote_hosts:
        extra_starts += try_supply(len(candidates))
    lookup = repo_id_lookup or default_repo_id_lookup
    # The workers inventory is a snapshot from before this pass, so count this pass's starts per host.
    pass_starts = {}
    attempts = 0
    for index, (repo, row) in enumerate(candidates):
        if deadline_hit(log_bits, 'issue_scan_deadline'):
            break
        placement = None

        def defer_rest(reason, first=index):
            for rest_repo, rest_row in candidates[first:]:
                defer_issue(state, now, rest_repo, rest_row['number'], reason, deferred, notices, log_bits, persist_state)

        if at_max_workers(config, workers):
            count_refused(MAX_WORKERS_REASON)
            defer_rest(MAX_WORKERS_REASON)
            break
        # The local cap is full when local admission passed but this pass's starts and the occupied seats reach it (#2012).
        local_full = not remote_hosts and not _issue_scan_has_slot(host, config, admission, extra_starts)
        if local_full and not spill_hosts:
            count_refused('host_cap')
            defer_rest('host_cap')
            break
        # The route comes first so placement knows the agent and skips a host signed out of agy (#1966).
        route = None
        labelled = issue_scan_route(row)
        if labelled:
            if labelled[1] == 'qa-sdet' and (row.get('title') or '').startswith(TIER0_AUDIT_PREFIX):
                chosen = tier0_audit_pick(row, pick_fn or pick_role)
            else:
                chosen = choose_pick((pick_fn or pick_role)(labelled[1], tier=labelled[2]))
            if not chosen:
                log_bits.append('issue_route_blocked=%d:%s' % (row['number'], labelled[1]))
                continue
            route = (labelled[0], chosen[0], chosen[1], chosen[2])
        start_agent = route[1] if route else scan.get('agent') or 'claude'
        if remote_hosts or local_full:
            placed = False
            unmapped = agy_out = 0
            for candidate in (remote_hosts or spill_hosts):
                receipt = admit_fn(candidate, config, workers)
                if not receipt.get('admitted'):
                    why = re.sub(r'[,;\s]+', ' ', str(receipt.get('reason') or 'unknown')).strip()
                    log_bits.append('issue_scan_refused_%s=%s' % (candidate, why))
                    count_refused(refusal_token(why))
                    continue
                host_cap = receipt.get('cap')
                if host_cap is None:
                    host_cap = config.get('host_caps', {}).get(candidate, 4)
                if (receipt.get('occupied') or 0) + pass_starts.get(candidate, 0) >= host_cap:
                    log_bits.append('issue_scan_full_%s' % candidate)
                    count_refused('host_cap')
                    continue
                if not _agy_signin().usable(start_agent, candidate, config):
                    log_bits.append('issue_scan_agy_%s' % candidate)
                    agy_out += 1
                    continue
                if not _host_maps_repo(config, candidate, repo):
                    log_bits.append('issue_scan_no_repo_%s' % candidate)
                    unmapped += 1
                    continue
                repo_id = lookup(candidate, repo)
                if not repo_id:
                    log_bits.append('issue_scan_no_repo_%s' % candidate)
                    unmapped += 1
                    continue
                placement = (candidate, repo_id)
                log_bits.append('issue_scan_placed=%s' % candidate)
                placed = True
                break
            if not placed:
                # A repo no free host maps defers only this issue: the rest of the queue still starts (#1778).
                # When every host was refused or full, nothing else fits either.
                if unmapped:
                    defer_issue(state, now, repo, row['number'], 'placement', deferred, notices, log_bits, persist_state)
                    continue
                # Hosts signed out of agy refuse only antigravity starts: a later issue on another agent may still start.
                if agy_out:
                    defer_issue(state, now, repo, row['number'], 'agy_signin', deferred, notices, log_bits, persist_state)
                    continue
                defer_rest('host_cap')
                return notices, log_bits
        command = build_issue_start_command(config, repo, row, placement, route)
        if command is None:
            log_bits.append('issue_scan_skip')
            continue
        if live_start_title(command, workers):
            log_bits.append('issue_live=%d' % row['number'])
            continue
        spec_path = command[command.index('--spec') + 1]
        missing = brief_lint_missing(spec_path)
        if missing:
            issue_key = str(row['number'])
            body_head = hashlib.sha256(issue_scan_brief_text(row).encode('utf-8')).hexdigest()
            lint_state = state.setdefault('issue_scan_brief_lint', {}).setdefault(repo, {})
            comment_head = 'brief-lint: %s' % ', '.join(missing)
            comment_body = comment_head + '\n' + '\n'.join('brief-lint: missing %s' % m for m in missing)
            already = lint_state.get(issue_key) == body_head or any(
                (c.get('body') or '').splitlines()[:1] == [comment_head]
                for c in (row.get('comments') or []) if isinstance(c, dict)
            )
            act([
                'gh', 'issue', 'edit', issue_key, '--repo', repo,
                '--add-label', 'needs-triage', '--remove-label', 'ready-for-agent',
            ])
            if not already:
                act(['gh', 'issue', 'comment', issue_key, '--repo', repo, '--body', comment_body])
                lint_state[issue_key] = body_head
                if persist_state:
                    persist_state()
            log_bits.append(('issue_lint_stuck=%d' if already else 'issue_needs_triage=%d') % row['number'])
            continue
        if attempts:
            seen_gate = len(USAGE_GATE_REFUSALS)
            if not gate_check(config):
                fresh = USAGE_GATE_REFUSALS[seen_gate:]
                gate_reason = one_line_reason(fresh[-1].get('reason') if fresh else 'unknown')
                count_refused('usage_gate')
                log_bits.append('issue_scan_gate=%s' % gate_reason)
                break
        # PASS_HARD_END, not START_FINISH_BY: the notice, PR and scan steps before this use about 110 s, so no start
        # fit 140 s and the fleet filled at 0 or 1 per pass (#2009). Supply made the same change (#1889).
        if not start_fits_pass(start_cost(command)):
            log_bits.append('issue_start_budget=%d' % row['number'])
            continue
        attempts += 1
        issue_pending.setdefault(repo, []).append(row['number'])
        if persist_state:
            persist_state()
        with agy_signin_exit_env():
            started_worker = start_worker(command)
        code, reason = start_result_parts(started_worker)
        pending_list = issue_pending.setdefault(repo, [])
        if row['number'] in pending_list:
            pending_list.remove(row['number'])
        suffix = ':%s' % reason if reason else ''
        if code == AGY_SIGNIN_HELD_EXIT:
            # The antigravity start was signed out and worker-startup undid it: the host is marked, the dispatch stopped and
            # released, the labels back, the worktree gone. Nothing here changes, so the next pass starts the issue on claude (#1832).
            held_host, notify = agy_signin_held(reason)
            log_bits.append('issue_start_agy_signin=%d' % row['number'])
            if notify:
                notices.append(Urgent(
                    _agy_signin_line(held_host)))
            if persist_state:
                persist_state()
            continue
        delivered = start_delivered_refusal(reason) if code != 0 else None
        if delivered:
            # Refused as already delivered: elon closes the issue or starts it with --allow-delivered (#1811).
            log_bits.append('issue_start_delivered=%d' % row['number'])
            defer_issue(state, now, repo, row['number'], delivered, deferred, notices, log_bits, persist_state)
            continue
        if code in BABYSIT_DEFERRED_EXITS or (code != 0 and (refusal_token(reason) == 'usage_gate' or start_gate_refusal(reason))):
            if persist_state:
                persist_state()
            log_bits.append('issue_start_deferred=%d%s' % (row['number'], suffix))
            if 'overlaps other work in flight' in str(reason or '').lower():
                state.setdefault('issue_scan_overlap', {}).setdefault(repo, {})[str(row['number'])] = {
                    'fp': overlap_fingerprint(row, listed.get(repo)), 'passes': 0}
                if persist_state:
                    persist_state()
            defer_issue(state, now, repo, row['number'], reason or 'start_deferred', deferred, notices, log_bits, persist_state)
            continue
        if code == 0:
            state.get('issue_scan_overlap', {}).get(repo, {}).pop(str(row['number']), None)
            clear_issue_deferral(state, repo, row['number'])
            remember_started_dispatch(state, started_worker, 'issue', repo)
            if placement:
                pass_starts[placement[0]] = pass_starts.get(placement[0], 0) + 1
            else:
                extra_starts += 1
            started.setdefault(repo, []).append(row['number'])
            started_at.setdefault(repo, {})[str(row['number'])] = now
            act(['gh', 'issue', 'edit', str(row['number']), '--repo', repo, '--remove-label', 'ready-for-agent'])
            notices.append('issue %s #%d' % (repo, row['number']))
            log_bits.append('issue_start=%d' % row['number'])
            count_worker_started()
            if persist_state:
                persist_state()
        else:
            updated = row.get('updatedAt') or ''
            park_key = park_id('issue', repo, row['number'], updated)
            if park_failure(state, park_key, reason, config, repo=repo, issue=row['number']):
                notices.append(park_notice('issue', '%s#%s' % (repo, row['number']), reason, command))
            act([
                'gh', 'issue', 'edit', str(row['number']), '--repo', repo,
                '--add-label', 'needs-triage', '--remove-label', 'ready-for-agent',
            ])
            if persist_state:
                persist_state()
            log_bits.append('issue_start_fail=%d%s' % (row['number'], suffix))
    return notices, log_bits


def workflow_notices(config, state, now, fetch=None, act=None):
    """Rerun one failed workflow once per head. Never open a failed-twice issue.

    A head that is still red on a later pass is rework input via workflow_watch.
    Red checks on main stay with main_red_notices. A repo whose fetch failed keeps its state.
    """
    if fetch is None:
        fetch = fetch_failed_runs
    if act is None:
        act = run_gh
    watch = config.get('pr_watch') or {}
    if not watch.get('repos'):
        return []
    workflows = watch.get('workflows') or []
    workflow_filter = set(workflows) if workflows else None
    handled = state.setdefault('workflow_watch', {})
    spent = state.setdefault('workflow_head_rerun', {})
    for repo in watch['repos']:
        runs = fetch(repo)
        if runs is None:
            continue
        old = handled.get(repo, {})
        spent_heads = spent.setdefault(repo, {})
        done = {}
        fresh = []
        for run in runs:
            created = calendar.timegm(time.strptime(run['createdAt'], '%Y-%m-%dT%H:%M:%SZ'))
            if workflow_filter is not None and run['workflowName'] not in workflow_filter:
                continue
            if now - created > RUN_WINDOW:
                continue
            key = str(run['databaseId'])
            head = run.get('headSha') or ''
            step = old.get(key)
            already = step in ('rerun', 'issue') or run['attempt'] >= 2 or (head and head in spent_heads)
            if already:
                done[key] = 'issue' if step == 'issue' else 'rerun'
                if head and head not in spent_heads:
                    spent_heads[head] = key
                continue
            fresh.append(run)
        for run in fresh:
            key = str(run['databaseId'])
            head = run.get('headSha') or ''
            if head and head in spent_heads:
                done[key] = 'rerun'
                continue
            act(['gh', 'run', 'rerun', key, '--repo', repo, '--failed'])
            done[key] = 'rerun'
            if head:
                spent_heads[head] = key
        handled[repo] = done
    return []


MAIN_RED_TITLE_PREFIX = 'main red: '
RED_GATE_TITLE_PREFIX = 'red gate: '  # red-gate.py files these; the issue scan starts their fixer first (#1746)


def main_red_failing_step(repo, run_id, run=subprocess.run):
    """'job / step' of the first failed step of a run, '' when gh cannot say."""
    try:
        out = run(['gh', 'run', 'view', str(run_id), '--repo', repo, '--json', 'jobs'],
                  capture_output=True, text=True, timeout=30, check=True)
        for job in json.loads(out.stdout).get('jobs') or []:
            for step in job.get('steps') or []:
                if step.get('conclusion') == 'failure':
                    return '%s / %s' % (job.get('name'), step.get('name'))
    except (subprocess.SubprocessError, OSError, ValueError, AttributeError):
        pass
    return ''


def main_red_find_issue(repo, title, run=subprocess.run):
    """Number of an open issue with this exact title, else None."""
    try:
        out = run(['gh', 'issue', 'list', '--repo', repo, '--state', 'open', '--search',
                   '"%s" in:title' % title, '--json', 'number,title', '--limit', '20'],
                  capture_output=True, text=True, timeout=30, check=True)
        for row in json.loads(out.stdout):
            if row.get('title') == title:
                return row.get('number')
    except (subprocess.SubprocessError, OSError, ValueError, AttributeError):
        pass
    return None


def main_red_create_issue(repo, title, body, run=subprocess.run, labels=('P1', 'ready-for-agent')):
    """Number of the new issue, None when gh fails."""
    try:
        out = run(['gh', 'issue', 'create', '--repo', repo, '--title', title, '--body', body,
                   *[arg for label in labels for arg in ('--label', label)]],
                  capture_output=True, text=True, timeout=30, check=True)
        return int(out.stdout.strip().rsplit('/', 1)[-1])
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def main_red_issue_body(run_id, url, step):
    return (
        'Checks on main failed in run %s: %s\n\nFailing step: %s\n\n'
        '## Acceptance\n'
        '- [ ] Checks on main is green again; the fix names the failing step above.\n'
        '- [ ] The PR body has the line `Fixes main: %s`.\n'
        '- [ ] bash script/checks-local.sh exits 0.\n\n'
        '## Out of scope\n'
        'Other failures and unrelated cleanup.\n'
    ) % (run_id, url, step or 'unknown (read the run log)', run_id)


def main_red_url_is_github(url):
    """True only for a run URL on github.com. Anything else is fixture or foreign data, never filed (#1737)."""
    try:
        return (urllib.parse.urlparse(str(url or '')).hostname or '').lower() == 'github.com'
    except ValueError:
        return False


def main_red_notices(config, state, now, fetch=None, find_issue=None, create_issue=None, failing_step=None):
    """Tell the coordinator once per run id when the latest Checks run on main is not success.

    Once per run id it also files or reuses a P1 issue 'main red: <run id>' that the issue scan starts ahead of
    the queue (#1677). A failed create is retried on the next pass."""
    if fetch is None:
        fetch = fetch_main_checks_run
    find_issue = find_issue or main_red_find_issue
    create_issue = create_issue or main_red_create_issue
    failing_step = failing_step or main_red_failing_step
    notices = []
    told = state.setdefault('main_red', {})
    filed = state.setdefault('main_red_issue', {})
    for repo in (config.get('pr_watch') or {}).get('repos') or []:
        run = fetch(repo)
        if run is None:
            continue
        run_id = str(run.get('databaseId') or '')
        if not run_id or run.get('conclusion') == 'success':
            told.pop(repo, None)
            filed.pop(repo, None)
            continue
        number = None
        if filed.get(repo) != run_id and main_red_url_is_github(run.get('url')):
            title = '%s%s' % (MAIN_RED_TITLE_PREFIX, run_id)
            number = find_issue(repo, title)
            if number is None:
                number = create_issue(repo, title, main_red_issue_body(
                    run_id, run.get('url'), failing_step(repo, run_id)))
            if number is not None:
                filed[repo] = run_id
        if told.get(repo) != run_id:
            told[repo] = run_id
            where = ', fixer issue #%s' % number if number is not None else ', fixer issue not filed'
            notices.append(Urgent(f"{repo}: Checks on main is {run.get('conclusion')}, ship.sh refuses until fixed: {run.get('url')}{where}"))
    return notices


def backup_age_seconds(config, now, stamp_time=os.path.getmtime):
    """Age of backup stamp file in seconds, or None when missing/unconfigured."""
    backup = config.get('backup')
    if not backup or 'stamp' not in backup:
        return None
    try:
        return now - stamp_time(backup['stamp'])
    except OSError:
        return None


def backup_notices(config, state, now, stamp_time=os.path.getmtime, act=None, backup_issue_exists=None):
    """Open one issue per outage when the last good backup is over 30 minutes old."""
    if act is None:
        act = run_gh
    if backup_issue_exists is None:
        backup_issue_exists = open_backup_issue_exists
    backup = config.get('backup')
    if not backup:
        return []
    age = backup_age_seconds(config, now, stamp_time)
    if age is None:
        age = BACKUP_LIMIT + 1
    if age <= BACKUP_LIMIT:
        state.pop('backup_issue', None)
        return []
    if state.get('backup_issue'):
        return []
    exists = backup_issue_exists(backup['issue_repo'])
    if exists is None:
        return []
    if exists:
        state['backup_issue'] = True
        return []
    title = AGENT_STATE_BACKUP_STALE_TITLE
    if act(['gh', 'issue', 'create', '--repo', backup['issue_repo'], '--title', title,
            '--body', 'Read the sync log on the coordinator. `scan.sh` may have refused a file.']):
        return [f'{title}, issue not opened']
    state['backup_issue'] = True
    return [title]


def usage_notices(config, run=subprocess.run):
    hosts = config.get('usage_hosts')
    if not hosts:
        return []
    command = [sys.executable, str(Path(__file__).with_name('usage-gate.py')), 'publish']
    for host in hosts:
        command += ['--host', host]
    code = run(command, capture_output=True, timeout=240).returncode
    return [f'usage reading not published: exit {code}'] if code else []


def ssh_reachable(name):
    """True when a quick ssh to the coordinator succeeds."""
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', name, 'true']
    try:
        return subprocess.run(command, capture_output=True, timeout=10).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def run_alert(command, text):
    """Run the private alert command with the text as its last argument."""
    if not command:
        return True
    try:
        return subprocess.run(list(command) + [text], capture_output=True, timeout=30).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def this_host():
    return subprocess.run(['hostname', '-s'], capture_output=True, text=True, timeout=5).stdout.strip()


def parse_coordinator_name(text):
    """The name on the first `coordinator <name>` line, or None."""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == 'coordinator':
            return parts[1]
    return None


_REMOTE_READ_FAILED = object()


def coordinator_name_local(state_dir):
    try:
        text = (Path(state_dir) / 'coordinator.conf').read_text()
    except OSError:
        return None
    return parse_coordinator_name(text)


def read_coordinator_name_from_remote(state_dir):
    try:
        fetch = subprocess.run(['git', '-C', str(state_dir), 'fetch', '-q', 'origin'],
                               capture_output=True, timeout=10)
        if fetch.returncode != 0:
            return _REMOTE_READ_FAILED
        show = subprocess.run(['git', '-C', str(state_dir), 'show', 'origin/main:coordinator.conf'],
                              capture_output=True, text=True, timeout=10)
        if show.returncode != 0:
            return _REMOTE_READ_FAILED
        return parse_coordinator_name(show.stdout)
    except (subprocess.SubprocessError, OSError):
        return _REMOTE_READ_FAILED


def coordinator_name_from_state_dir(state_dir):
    """Prefer origin/main coordinator.conf; fall back to the local file only on git failure."""
    remote = read_coordinator_name_from_remote(state_dir)
    if remote is _REMOTE_READ_FAILED:
        return coordinator_name_local(state_dir)
    return remote


def coordinator_notices(config, state, now, reachable=ssh_reachable, alert=run_alert, host=None,
                        name_reader=coordinator_name_from_state_dir):
    """Alert only: tell the owner a coordinator is offline. Runs on a backup host."""
    watch = config.get('coordinator_watch')
    if not watch:
        return []
    name = name_reader(watch['state_dir'])
    if not name or name.lower() == (host or this_host()).lower():
        state.pop('coordinator_watch', None)
        return []
    command = watch.get('alert_command') or []
    timer = state.get('coordinator_watch')
    if timer and timer.get('host') != name:
        timer = None
    if reachable(name):
        state.pop('coordinator_watch', None)
        if timer and timer['alerted']:
            text = 'coordinator %s back' % name
            alert(command, text)
            return [text]
        return []
    timer = state['coordinator_watch'] = timer or {'host': name, 'since': now, 'alerted': False}
    if timer['alerted'] or now - timer['since'] < watch.get('offline_minutes', 10) * 60:
        return []
    text = 'coordinator %s offline for %d minutes; failover is manual, ask the owner' % (name, (now - timer['since']) // 60)
    if not alert(command, text):
        return [text]
    timer['alerted'] = True
    return [text]


def acquire_pass_lock(state_path):
    """Hold an exclusive lock beside the state file for the life of the process, or return None when another pass has it.

    The loop, the 5 minute automation and a manual run all load state at their start. Without the lock two of them
    see no record for a PR head and each start a verifier (#1706). The OS drops the lock when the process dies.
    """
    import fcntl
    state_path = Path(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(str(state_path) + '.lock', 'w')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(path)


DRAIN_LOG_DEFAULT = os.path.expanduser('~/.claude/state/coordinator-drain.log')


def owning_lead(author):
    """The lead terminal in the owner record for an author dispatch, or None."""
    if not author or not re.fullmatch(r'[A-Za-z0-9_-]+', author):
        return None
    owners = os.environ.get('WORKER_DONE_OWNER_DIR') or os.path.expanduser('~/.claude/state/dispatch-owners')
    try:
        lines = (Path(owners) / author).read_text().splitlines()
    except OSError:
        return None
    return lines[0].strip() or None if lines else None


def digest_routes(runs):
    """(run:<id>, sender terminal) for each untyped run. The sender is the identity fleet watch already uses."""
    routes = []
    for run in runs or []:
        if not isinstance(run, dict) or run.get('typed'):
            continue
        rid = run.get('id')
        term = run.get('terminal')
        if not isinstance(rid, str) or not rid.strip():
            continue
        if not isinstance(term, str) or not term.strip():
            continue
        routes.append(('run:' + rid.strip(), term.strip()))
    return routes


def fleet_watch_sender(runs):
    """Sender terminal fleet watch already passes as --from on worker-start."""
    for run in runs or []:
        if not isinstance(run, dict):
            continue
        term = run.get('terminal')
        if isinstance(term, str) and term.strip():
            return term.strip()
    return ''


def migrate_notice_addresses(state, runs):
    """Digests used to be keyed by the run terminal. They are now keyed by run:<id>."""
    terminal_to_address = {sender: address for address, sender in digest_routes(runs)}
    queue = state.get('notice_queue')
    if isinstance(queue, dict):
        for term, address in terminal_to_address.items():
            if term not in queue:
                continue
            items = queue.pop(term)
            dest = queue.setdefault(address, [])
            if not isinstance(items, list):
                continue
            for item in items:
                if isinstance(item, dict):
                    item.setdefault('sender', term)
                    dest.append(item)
    sent_at = state.get('notice_sent_at')
    if isinstance(sent_at, dict):
        for term, address in terminal_to_address.items():
            if term in sent_at and address not in sent_at:
                sent_at[address] = sent_at.pop(term)


def queue_notice(queue, address, text, urgent, now, sender):
    items = queue.setdefault(address, [])
    for item in items:
        if item.get('text') == text:
            item['urgent'] = item.get('urgent') or urgent
            if sender and not item.get('sender'):
                item['sender'] = sender
            return
    items.append({'text': text, 'urgent': urgent, 'queued_at': now, 'sender': sender})


def notice_expired(item, now):
    queued_at = item.get('queued_at') if isinstance(item, dict) else None
    if isinstance(queued_at, bool) or not isinstance(queued_at, (int, float)):
        if isinstance(item, dict):
            item['queued_at'] = now
        return False
    return now - float(queued_at) >= NOTICE_MAX_AGE_SECONDS


def drop_expired_notices(items, now, address):
    kept = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if notice_expired(item, now):
            print('fleet-watch: giving up notice %r after 24 hours, missing %s' % (item.get('text'), address), file=sys.stderr)
            continue
        kept.append(item)
    return kept


def notice_sender(items):
    for item in items:
        sender = item.get('sender') if isinstance(item, dict) else None
        if isinstance(sender, str) and sender.strip():
            return sender.strip()
    return ''


def log_send_ok():
    count_sent()
    n = _PASS.sent if _PASS is not None else 1
    log_fleet_watch('sent=%d' % n)


def log_send_failed(address, error):
    count_send_failed()
    line = 'fleet-watch: send failed for %s: %s' % (address, orchestration_failure_log_code(error))
    print(line, file=sys.stderr)
    log_fleet_watch(line)


def _spawn_oserror(error):
    """The OSError when the orca process never ran (bare, or anywhere in rpc's cause chain), else None.
    A timeout may have landed, so it is not one."""
    seen = 0
    while error is not None and seen < 5:
        if isinstance(error, OSError):
            return error
        error, seen = error.__cause__, seen + 1
    return None


def send_once_more_on_oserror(rpc_call, address, *command):
    """Run one send; when the orca process could not start, log a retry line and try once more (#1843)."""
    try:
        return rpc_call(*command)
    except SEND_ERRORS as error:
        cause = _spawn_oserror(error)
        if cause is None:
            raise
        line = 'fleet-watch: send retry for %s after %s' % (address, type(cause).__name__)
        print(line, file=sys.stderr)
        log_fleet_watch(line)
    return rpc_call(*command)


def send_digest(rpc_call, address, sender, body):
    """Address run:<id> or a lead. --from is fleet watch's sender, not a copy of the receiver."""
    command = ['orchestration', 'send', '--to', address]
    if sender:
        command += ['--from', sender]
    command += ['--subject', 'fleet-watch digest', '--body', body]
    send_once_more_on_oserror(rpc_call, address, *command)


def flush_queue(state, now, rpc_call, fallback_sender=''):
    """One orchestration send per address: at once when urgent, else at most every DIGEST_SECONDS.

    A queued item with no sender goes out --from fallback_sender (config), since a scheduled pass has no
    ORCA_TERMINAL_HANDLE and Orca then refuses with no_active_sender_terminal (#1843)."""
    queue = state.setdefault('notice_queue', {})
    sent_at = state.setdefault('notice_sent_at', {})
    for address in list(queue):
        items = queue[address]
        if not items:
            del queue[address]
            continue
        items = drop_expired_notices(items, now, address)
        if not items:
            del queue[address]
            continue
        queue[address] = items
        if not any(item.get('urgent') for item in items) and address in sent_at and now - sent_at[address] < DIGEST_SECONDS:
            continue
        try:
            send_digest(rpc_call, address, notice_sender(items) or fallback_sender, '\n'.join(item['text'] for item in items))
        except SEND_ERRORS as error:
            log_send_failed(address, error)
            continue
        log_send_ok()
        sent_at[address] = now
        del queue[address]


def drain_notices(config, path=None, keep=False):
    """One digest line counting lead stops coordinator-drain.sh dropped since the last pass, per lead."""
    path = Path(path or os.environ.get('COORDINATOR_DRAIN_STATE') or DRAIN_LOG_DEFAULT)
    claimed = path.with_name(path.name + '.claimed')
    try:
        if path.exists():
            with open(claimed, 'a') as out, open(path) as source:
                out.write(source.read())
            path.unlink()
        handles = claimed.read_text().split()
    except OSError:
        return []
    if not keep:
        claimed.unlink(missing_ok=True)
    counts = {}
    for handle in handles:
        counts[handle] = counts.get(handle, 0) + 1
    if not counts:
        return []
    names = {lead['terminal']: lead['name'] for lead in config.get('leads', [])}
    return ['lead stops dropped from the coordinator inbox: ' + ', '.join('%s %d' % (names.get(h, h), n) for h, n in counts.items())]


def deliver_typed_notices(typed_runs, state, new_notices, rpc_call, now):
    """Runs with ``typed``: true receive notices via terminal send (legacy path)."""
    if not typed_runs:
        return
    delivery = state.setdefault('typed_notice_delivery', {})
    if not new_notices and not delivery:
        return
    terminals = [run['terminal'] for run in typed_runs]
    texts = [str(notice) for notice in new_notices]
    failed = set()
    for line in dict.fromkeys(texts + list(delivery)):
        entry = delivery.setdefault(line, {'sent': [], 'since': now})
        since = entry.get('since')
        if isinstance(since, bool) or not isinstance(since, (int, float)):
            entry['since'] = now
            since = now
        for term in terminals:
            if term in entry['sent'] or term in failed:
                continue
            try:
                send_once_more_on_oserror(rpc_call, term, 'terminal', 'send', '--terminal', term, '--text', line, '--enter')
                entry['sent'].append(term)
                log_send_ok()
            except SEND_ERRORS as error:
                log_send_failed(term, error)
                failed.add(term)
        missing = [term for term in terminals if term not in entry['sent']]
        expired = now - since >= NOTICE_MAX_AGE_SECONDS
        if missing and expired:
            print('fleet-watch: giving up notice %r after 24 hours, missing %s' % (line, ', '.join(missing)), file=sys.stderr)
        if not missing or expired:
            del delivery[line]


def deliver_notices(config, state, new_notices, rpc_call=rpc, now=None, owner_of=owning_lead):
    """Queue notices per run and send what is due. Typed runs still get terminal send."""
    now = time.time() if now is None else now
    runs = config.get('runs', [])
    routes = digest_routes(runs)
    typed_runs = [run for run in runs if isinstance(run, dict) and run.get('typed')]
    sender = fleet_watch_sender(runs) or babysit_settings(config)[2]
    migrate_notice_addresses(state, runs)
    queue = state.setdefault('notice_queue', {})
    live = {address for address, _sender in routes}
    live.update(run['terminal'] for run in typed_runs if run.get('terminal'))
    live.update(lead['terminal'] for lead in config.get('leads', []) if lead.get('terminal'))
    for notice in new_notices:
        targets, urgent = list(routes), isinstance(notice, Urgent)
        if isinstance(notice, Verdict):
            lead = owner_of(notice.author)
            if lead:
                targets, urgent = [(lead, sender)], True
        text = str(notice)
        for address, from_terminal in targets:
            live.add(address)
            queue_notice(queue, address, text, urgent, now, from_terminal)
    for address in list(queue):
        if address not in live:
            print('fleet-watch: dropping %d notice(s) for %s, not in runs' % (len(queue[address]), address), file=sys.stderr)
            del queue[address]
    flush_queue(state, now, rpc_call, sender)
    deliver_typed_notices(typed_runs, state, new_notices, rpc_call, now)


def coordinator_stage(config, state, state_path):
    """First step of a pass. Saves state at once, and ends a pass on a host without Orca."""
    notices = coordinator_notices(config, state, time.time())
    if not config.get('coordinator_watch'):
        return notices, False
    save_state(state_path, state)
    if config.get('runs'):
        return notices, False
    if notices:
        print('fleet-watch: ' + '; '.join(notices))
    return notices, True


def _message_payload(message):
    value = message.get('payload') if isinstance(message, dict) else None
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def _message_outcome(message, payload, worker=None):
    for source in (message, payload):
        if not isinstance(source, dict):
            continue
        outcome = source.get('outcome')
        if isinstance(outcome, str) and outcome.strip():
            return outcome.strip().lower()
    # The concise inbox view omits outcome, so the matched worker row settles it (#1858).
    settled = worker_settled_kind(worker)
    return settled if settled in ('succeeded', 'failed') else ''


_NEW_TITLE_RE = re.compile(r'^#(\d+)\|([a-z][a-z-]*)(?:\|.*)?$', re.I)


def _builder_role(worker):
    title = str(worker.get('_task_title') or worker.get('title') or '').strip()
    new_form = _NEW_TITLE_RE.match(title)
    if new_form:
        return new_form.group(2).lower()
    if ' - ' in title:
        return title.split(' - ', 1)[0].strip().lower()
    proj = worker.get('projection') or {}
    return str((proj.get('role') if isinstance(proj, dict) else '') or worker.get('role') or '').strip().lower()


def fetch_pr_body(repo, number, run=subprocess.run):
    try:
        output = run(
            ['gh', 'pr', 'view', str(number), '--repo', repo, '--json', 'body'],
            capture_output=True, text=True, timeout=30, check=True,
        )
        data = json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    body = data.get('body')
    return body if isinstance(body, str) else ''


def _mark_worker_released(worker):
    """The seat drops on the next admit once Orca has released the terminal."""
    worker['released'] = True
    worker['terminalState'] = 'released'
    evidence = worker.get('evidence')
    if isinstance(evidence, dict):
        evidence['released'] = True
    projection = worker.get('projection')
    if isinstance(projection, dict):
        projection['released'] = True


def remote_environment(worker):
    """Environment id or name to pass as --environment for a remote worker row."""
    server = (worker or {}).get('server')
    if isinstance(server, str) and server.strip():
        return server.strip()
    if isinstance(server, dict):
        for key in ('environmentId', 'name', 'id'):
            value = server.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    host = projection_host_id(worker)
    return '' if host == 'local' else host


def worker_is_remote(worker, config):
    if _remote_server_row(worker):
        return True
    return projection_host_id(worker) != 'local' and not worker_on_local_machine(worker, config, {})


def worker_is_settled_remote(worker):
    """A remote row whose dispatch has settled. It holds no seat on the remote host."""
    w = worker or {}
    return bool(_remote_server_row(w)
                and (worker_settled_kind(w) is not None or worker_inventory_status(w) == 'completed')
                and w.get('pushed') is not False)


_REJECTED_DONE_BODIES = (
    'Orca rejected this worker_done: worker_done references unknown dispatch',
    'Orca rejected this worker_done: worker_done references unknown task',
)
_REJECTED_DONE_CODES = ('unknown_dispatch', 'unknown_task')


def worker_done_rejected(message):
    """True for the copy of a relayed worker_done that the coordinator's Orca rejected as unknown_dispatch or unknown_task (#1228, #1269).

    The full inbox view carries _orcaLifecycleRejection in the payload; the concise view keeps only ids,
    so the rejection shows only in the body Orca writes.
    """
    if not isinstance(message, dict) or message.get('type') != 'worker_done':
        return False
    rejection = _message_payload(message).get('_orcaLifecycleRejection')
    if isinstance(rejection, dict):
        return rejection.get('code') in _REJECTED_DONE_CODES
    return str(message.get('body') or '').startswith(_REJECTED_DONE_BODIES)


def _shown_remote_worker(dispatch, rpc_call):
    """Row for a dispatch missing from worker-list, read from worker-show. None when it cannot be read."""
    try:
        shown = rpc_call('orchestration', 'worker-show', '--dispatch', dispatch)
    except SEND_ERRORS:
        return None
    if isinstance(shown, dict) and isinstance(shown.get('worker'), dict):
        shown = shown['worker']
    if not isinstance(shown, dict) or not shown:
        return None
    row = dict(shown)
    row['dispatchId'] = dispatch
    if 'workerState' not in row and row.get('state'):
        row['workerState'] = row['state']
    if 'dispatchStatus' not in row and row.get('status'):
        row['dispatchStatus'] = row['status']
    return row


# A worker_done whose body names ~/agent-state/... counts only once that path is on the coordinator (#1849).
# The path may be written ~/..., $HOME/... or with a home folder (/Users/<name>/..., /home/<name>/...).
_AGENT_STATE_PATH_RE = re.compile(r'(?:~|\$HOME|/(?:Users|home)/[^/\s]+)/agent-state/([^\s`\'"(),;<>]+)')
_HEX_SHA_RE = re.compile(r'\b[0-9a-f]{7,40}\b')
_TRUNCATED_SUFFIX = '(truncated; --full)'
_ORIGINAL_BODY = 'Original body:'
AGENT_STATE_DIR = os.path.expanduser('~/agent-state')


def _agent_state_sha_exists(sha):
    try:
        proc = subprocess.run(['git', '-C', AGENT_STATE_DIR, 'cat-file', '-e', sha + '^{commit}'],
                              capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def _done_text(message):
    """The worker's own done text. A rejected remote copy keeps it after "Original body:" in both inbox views."""
    body = str(message.get('body') or '')
    if body.startswith('Orca rejected this worker_done') and _ORIGINAL_BODY in body:
        body = body.split(_ORIGINAL_BODY, 1)[1]
    extra = _message_payload(message).get('body')
    return body + ('\n' + extra if isinstance(extra, str) else '')


def agent_state_hold(message, path_exists=None, sha_exists=None):
    """Why this worker_done does not count yet, or '' when it does.

    It holds when the body names an ~/agent-state path that is missing on this machine, unless the body
    also names a commit sha that exists in ~/agent-state.
    """
    path_exists = path_exists or os.path.exists
    text = _done_text(message)
    missing = []
    for match in _AGENT_STATE_PATH_RE.finditer(text):
        rel = match.group(1).rstrip('.:')
        if not rel or any(c in rel for c in '*{}…'):
            continue
        name = '~/agent-state/' + rel
        if not path_exists(os.path.join(AGENT_STATE_DIR, rel)) and name not in missing:
            missing.append(name)
    if not missing:
        return ''
    sha_exists = sha_exists or _agent_state_sha_exists
    if any(sha_exists(sha) for sha in list(dict.fromkeys(_HEX_SHA_RE.findall(text)))[:10]):
        return ''
    more = ' (and %d more)' % (len(missing) - 1) if len(missing) > 1 else ''
    return 'it names %s%s, which is not on the coordinator' % (missing[0], more)


def release_held(state, dispatch):
    """The one release gate: True while the dispatch's last worker_done names an agent-state path that is missing."""
    holds = state.get('done_hold')
    return isinstance(holds, dict) and dispatch in holds


def update_done_holds(state, messages, workers, now, read_full=None, path_exists=None, sha_exists=None):
    """Set or clear state['done_hold'][dispatch] from each dispatch's newest worker_done. Runs once per pass.

    Only a dispatch with a release still ahead is judged, so old mail raises no hold. The inbox lists the
    newest message first. Its concise view cuts a body at 200 characters, so a cut body is read once from
    read_full (message id to full body); a body that cannot be read holds with no notice until a later pass.
    """
    holds = state.get('done_hold')
    if not isinstance(holds, dict):
        holds = state['done_hold'] = {}
    texts = state.get('done_hold_text')
    if not isinstance(texts, dict):
        texts = state['done_hold_text'] = {}
    rows = {w.get('dispatchId'): w for w in workers or [] if isinstance(w, dict) and w.get('dispatchId')}
    finished = set(state.get('auto_released') or ()) | set(state.get('remote_reconciled') or ())
    newest = {}
    for message in messages or []:
        if not isinstance(message, dict) or message.get('type') != 'worker_done':
            continue
        dispatch = _message_payload(message).get('dispatchId')
        if not isinstance(dispatch, str) or not dispatch or dispatch in newest or dispatch in finished:
            continue
        # A rejected remote copy still has a reconcile release ahead, even when its row reads as released.
        rejected = worker_done_rejected(message)
        row = rows.get(dispatch)
        if row is not None and worker_terminal_released(row) and not rejected:
            continue
        if row is None and not rejected:
            continue
        newest[dispatch] = message
    full = {}

    def full_body(message_id):
        if 'read' not in full:
            try:
                full['read'] = read_full() if read_full else None
            except SEND_ERRORS:
                full['read'] = None
        return (full['read'] or {}).get(message_id)

    present = {m.get('id') for m in messages or [] if isinstance(m, dict)}
    for message_id in list(texts):
        if message_id not in present:
            del texts[message_id]
    for dispatch, message in newest.items():
        message_id = message.get('id')
        body = str(message.get('body') or '')
        unread = False
        if body.endswith(_TRUNCATED_SUFFIX):
            if message_id not in texts:
                text = full_body(message_id)
                if isinstance(text, str):
                    texts[message_id] = text if 'agent-state' in text else ''
            if message_id in texts:
                message = dict(message, body=texts[message_id])
            else:
                unread = True
        reason = 'its full body could not be read' if unread else agent_state_hold(message, path_exists, sha_exists)
        if not reason:
            holds.pop(dispatch, None)
            continue
        old = holds.get(dispatch) if isinstance(holds.get(dispatch), dict) else {}
        holds[dispatch] = dict(old, reason=reason, message_id=message_id, since=old.get('since', now), unread=unread)
    for dispatch in list(holds):
        if dispatch not in newest:
            del holds[dispatch]
    return holds


def send_done_hold_notices(state, workers, config, now, rpc_call):
    """Tell each held worker once why its worker_done does not count; return the coordinator's notice lines.

    A notice is latched only on a confirmed send: a terminal handle, --environment for a remote row, and no
    send error. Otherwise it is tried again next pass, and the coordinator hears once per message id.
    A hold with no passing resend after one stall window is reported once; fleet-watch never releases it.
    """
    holds = state.get('done_hold')
    if not isinstance(holds, dict) or not holds:
        return []
    notified = state.setdefault('done_hold_notified', [])
    undelivered = state.setdefault('done_hold_undelivered', [])
    rows = {w.get('dispatchId'): w for w in workers or [] if isinstance(w, dict) and w.get('dispatchId')}
    stall_limit = stall_idle_limit_seconds(config)
    lines = []
    for dispatch, hold in sorted(holds.items()):
        if not isinstance(hold, dict) or hold.get('unread'):
            continue
        message_id = hold.get('message_id')
        if message_id not in notified:
            row = rows.get(dispatch) or {}
            term = worker_terminal_handle(row)
            remote = bool(row) and worker_is_remote(row, config)
            environment = remote_environment(row) if remote else ''
            sent = False
            if term and (environment or not remote):
                text = ('Your worker_done for %s does not count yet: %s. Push it to agent-state (or name the '
                        'agent-state commit sha) and send worker_done again.' % (dispatch, hold.get('reason')))
                try:
                    rpc_call('terminal', 'send', '--terminal', term, '--text', text, '--enter',
                             *(('--environment', environment) if environment else ()))
                    sent = True
                except SEND_ERRORS as error:
                    log_send_failed(term, error)
            if sent:
                notified.append(message_id)
            elif message_id not in undelivered:
                undelivered.append(message_id)
                lines.append('hold on %s: notice not delivered (%s)' % (dispatch, hold.get('reason')))
        if not hold.get('overdue') and stall_limit > 0 and now - float(hold.get('since') or now) >= stall_limit:
            hold['overdue'] = True
            lines.append(Urgent('hold on %s: no passing worker_done after one stall window (%s); fleet-watch '
                                'will not release it' % (dispatch, hold.get('reason'))))
    del notified[:-500]
    del undelivered[:-500]
    return lines


def reconcile_remote_completions(config, state, workers, messages, rpc_call):
    """Turn a settled remote worker into the worker_done the coordinator server rejected (#1220, #1228).

    The remote host accepts worker_done, but the coordinator reconciles the relayed mail against local
    dispatches only and answers unknown_dispatch (inside Orca, so not fixable here). The rejected copy is
    not an accepted worker_done, so a settled remote row with no accepted one gets one synthesized here,
    once per dispatch. A task with no PR, or a failed one, is released at once and announced in one line.
    A succeeded PR task is left to release_green_successes.
    Returns the notice lines.
    """
    done = state.setdefault('remote_reconciled', [])
    if not isinstance(done, list):
        done = []
        state['remote_reconciled'] = done
    seen = set(done)
    arrived, rejected = set(), set()
    for message in messages or []:
        if isinstance(message, dict) and message.get('type') == 'worker_done':
            dispatch = _message_payload(message).get('dispatchId')
            if isinstance(dispatch, str):
                (rejected if worker_done_rejected(message) else arrived).add(dispatch)
    notices = []
    candidates = list(workers or [])
    listed = {w.get('dispatchId') for w in candidates if isinstance(w, dict)}
    for dispatch in sorted(rejected - listed - seen):
        shown = _shown_remote_worker(dispatch, rpc_call)
        if shown is not None:
            _set_row_host(shown, config, state)
            candidates.append(shown)
            if isinstance(workers, list) and worker_is_remote(shown, config):
                workers.append(shown)
    auto_released = set(state.get('auto_released') or ())
    present = {m.get('id') for m in messages or [] if isinstance(m, dict)}
    for worker in candidates:
        if not isinstance(worker, dict) or not worker_is_remote(worker, config):
            continue
        settled = worker_settled_kind(worker)
        if settled is None and worker_inventory_status(worker) != 'completed':
            continue
        dispatch = worker.get('dispatchId')
        if not isinstance(dispatch, str) or not dispatch or release_held(state, dispatch):
            continue
        outcome = 'succeeded' if settled in (None, 'succeeded') else 'failed'
        synthesized = {
            'id': 'remote-reconciled:' + dispatch,
            'type': 'worker_done',
            'payload': {'dispatchId': dispatch, 'outcome': outcome, 'synthesized': True},
        }
        if dispatch in seen:
            if (dispatch not in arrived and outcome == 'succeeded' and worker_pr_number(worker)
                    and dispatch not in auto_released and not worker_terminal_released(worker)
                    and synthesized['id'] not in present):
                messages.append(synthesized)
                present.add(synthesized['id'])
            continue
        seen.add(dispatch)
        done.append(dispatch)
        if dispatch in arrived:
            continue
        messages.append(synthesized)
        present.add(synthesized['id'])
        if outcome == 'succeeded' and worker_pr_number(worker):
            continue
        if '_host' not in worker:
            _set_row_host(worker, config, state)
        release_worker(rpc_call, worker)
        if dispatch in rejected:
            notices.append('remote worker %s finished %s; its rejected worker_done is settled '
                           'and released, no hand release needed' % (dispatch, outcome))
        else:
            notices.append('remote worker %s finished %s' % (dispatch, outcome))
    return notices


# release_worker results that count as released for the auto_released and followup_released books (#1958).
RELEASE_BOOKED = ('closed', 'kept:no_handle')


def release_green_successes(messages, workers, config, state, release, pr_of, set_status=None):
    """Release a worker once when worker_done succeeded and its PR checks are green.

    The in-memory row is marked released so this pass stops counting the seat. When the PR has
    already merged, the card moves to completed; an open PR leaves it in in-review (#1842).
    """
    released_ids = state.setdefault('auto_released', [])
    if not isinstance(released_ids, list):
        released_ids = []
        state['auto_released'] = released_ids
    seen = set(released_ids)
    by_dispatch = {}
    for worker in workers or []:
        if not isinstance(worker, dict):
            continue
        dispatch = worker.get('dispatchId') or worker.get('dispatch_id')
        if isinstance(dispatch, str) and dispatch:
            by_dispatch[dispatch] = worker
    done = []
    for message in messages or []:
        if not isinstance(message, dict) or message.get('type') != 'worker_done' or worker_done_rejected(message):
            continue
        payload = _message_payload(message)
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        if not isinstance(dispatch, str) or not dispatch or dispatch in seen or release_held(state, dispatch):
            continue
        worker = by_dispatch.get(dispatch)
        if _message_outcome(message, payload, worker) != 'succeeded':
            continue
        if worker is None or worker_terminal_released(worker):
            continue
        number = worker_pr_number(worker)
        repo = repo_for_worker(worker, config)
        if not number or not repo:
            continue
        pr_row = pr_of(repo, number)
        if not isinstance(pr_row, dict) or not pr_checks_all_success(pr_row):
            continue
        if release(worker) not in RELEASE_BOOKED:
            continue
        if set_status is not None and (pr_row.get('state') or '').upper() == 'MERGED':
            set_status(worker, 'completed')
        released_ids.append(dispatch)
        seen.add(dispatch)
        done.append(dispatch)
    return done


def _followup_parent(worker):
    w = worker or {}
    proj = w.get('projection') if isinstance(w.get('projection'), dict) else {}
    for source in (w, proj):
        for key in ('follow_up_of_dispatch_id', 'followUpOfDispatchId'):
            value = source.get(key)
            if isinstance(value, str) and value:
                return value
    return ''


def release_dead_followups(workers, state, release):
    """Release a "New messages" follow-up that failed on the dead terminal of a worker that already succeeded (#1221).

    Orca opens it when mail reaches a worker as it finishes. The parent's work is done, so there is nothing to retry.
    """
    released = state.setdefault('followup_released', [])
    if not isinstance(released, list):
        released = []
        state['followup_released'] = released
    by_dispatch = {w.get('dispatchId'): w for w in workers or [] if isinstance(w, dict)}
    done = []
    for worker in workers or []:
        if not isinstance(worker, dict):
            continue
        dispatch = worker.get('dispatchId')
        parent = by_dispatch.get(_followup_parent(worker))
        if not dispatch or dispatch in released or parent is None:
            continue
        if worker_inventory_status(worker) != 'failed' or worker_terminal_released(worker):
            continue
        if not (worker_startup_failed(worker) or worker_liveness_verdict(worker) == 'exited'):
            continue
        if worker_settled_kind(parent) != 'succeeded' and worker_inventory_status(parent) != 'completed':
            continue
        if release(worker) not in RELEASE_BOOKED:
            continue
        released.append(dispatch)
        done.append(dispatch)
    return done


_WORKER_ISSUE_TITLE_RE = re.compile(
    r'^(?!rework\b)(?:[a-z0-9-]+)\s+-\s+#([0-9]+)\b|\bissue-([0-9]+)\b', re.I
)


def _worker_issue_number(worker):
    w = worker or {}
    for key in ('_task_title', 'title', 'name'):
        text = w.get(key)
        if not isinstance(text, str) or not text:
            continue
        new_form = _NEW_TITLE_RE.match(text.strip())
        if new_form:
            # A rework, fix or verify worker also carries "#<PR>|role": its name tells it apart from an issue builder.
            if re.match(r'^(rework|fix|verify)-', str(w.get('name') or '')):
                continue
            if new_form.group(1) != '0':
                return int(new_form.group(1))
            continue
        match = _WORKER_ISSUE_TITLE_RE.search(text.strip())
        if match:
            return int(match.group(1) or match.group(2))
    return None


_NEEDS_OWNER_RE = re.compile(r'needs[ -]owner', re.I)


def answered_owner_asks(messages, workers, state, config, run=subprocess.run):
    """Notice lines for "needs owner" issues in a PM worker_done that the owner already answered (#1298).

    Runs script/owner-decisions.sh for each #N in the message. Exit 0 means a recorded answer: the line
    tells the coordinator "already answered" so it applies the answer instead of asking. Any other exit
    stays silent (the coordinator's own check still runs). Each (message, issue) is told once.
    """
    lines = []
    told = state.setdefault('owner_answered', [])
    if not isinstance(told, list):
        told = []
        state['owner_answered'] = told
    by_dispatch = {}
    for worker in workers or []:
        if isinstance(worker, dict):
            dispatch = worker.get('dispatchId') or worker.get('dispatch_id')
            if isinstance(dispatch, str) and dispatch:
                by_dispatch[dispatch] = worker
    script = str(Path(__file__).resolve().parent / 'owner-decisions.sh')
    for message in messages or []:
        if not isinstance(message, dict) or message.get('type') != 'worker_done' or worker_done_rejected(message):
            continue
        message_id = message.get('id')
        if not isinstance(message_id, str) or not message_id:
            continue
        payload = _message_payload(message)
        text = ' '.join(str(v) for v in (message.get('subject'), message.get('body'), payload.get('body')) if v)
        if not _NEEDS_OWNER_RE.search(text):
            continue
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        worker = by_dispatch.get(dispatch)
        if worker is None or _builder_role(worker) != 'architect-pm':
            continue
        repo = repo_for_worker(worker, config)
        if not repo:
            continue
        for number in sorted({int(n) for n in re.findall(r'(?:^|[^A-Za-z0-9/])#(\d+)', text)}):
            key = '%s:%s' % (message_id, number)
            if key in told:
                continue
            try:
                result = run([script, repo, str(number)], capture_output=True, text=True, timeout=60)
            except (subprocess.SubprocessError, OSError):
                continue
            if result.returncode != 0:
                continue
            told.append(key)
            first = (result.stdout.strip().splitlines() or [''])[0][:160]
            lines.append('already answered: %s#%s has a recorded owner answer, apply it and do not ask the owner (%s)'
                         % (repo, number, first))
    return lines


def fetch_pr_diff(repo, number, run=subprocess.run):
    """The PR diff, or None when it cannot be read (the Readers: rule then stays off)."""
    try:
        output = run(['gh', 'pr', 'diff', str(number), '--repo', repo],
                     capture_output=True, text=True, timeout=60, check=True)
    except (subprocess.SubprocessError, OSError):
        return None
    return output.stdout


def _dispatch_asked(messages, dispatch, worker):
    """True when the inbox holds an ask (question or escalation) from this dispatch or its terminal. False only when
    there is none and the inbox was not cut at its limit; None (unknown) otherwise (#1882)."""
    handle = worker_terminal_handle(worker)
    for m in messages:
        if not isinstance(m, dict) or m.get('type') not in ASK_TYPES:
            continue
        if _message_payload(m).get('dispatchId') == dispatch or (handle and m.get('from') == handle):
            return True
    return False if len(messages) < INBOX_LIMIT else None


def _perf_conf_dir(config, repo, worker):
    """Checkout whose head-checks.conf names the repo's perf paths: the configured root, else the worker's
    checkout. '' (rule off) when neither is on this host, so fleet-watch's own cwd is never read (#2070)."""
    roots = [((config or {}).get(block) or {}).get('repo_roots') or {} for block in ('issue_scan', 'babysit')]
    for path in [r.get(repo) for r in roots if isinstance(r, dict)] + [worker_checkout_path(worker)]:
        if isinstance(path, str) and path and Path(path).is_dir():
            return path
    return ''


def bounce_builder_dones(messages, workers, body_of, notify, state, config, diff_of=None):
    """Tell a builder its worker_done does not count when the PR body fails the finish gate.

    diff_of(repo, number) gives the PR diff for the Readers: rule, and the dispatch's ask record turns on the
    Decisions: rule (#1882)."""
    lines = []
    bounced = state.setdefault('bounced_done', [])
    if not isinstance(bounced, list):
        bounced = []
        state['bounced_done'] = bounced
    seen = set(bounced)
    by_dispatch = {}
    for worker in workers or []:
        if not isinstance(worker, dict):
            continue
        dispatch = worker.get('dispatchId') or worker.get('dispatch_id')
        if isinstance(dispatch, str) and dispatch:
            by_dispatch[dispatch] = worker
    gate = _sibling('pr_body_gate', 'pr-body-gate.py')
    for message in messages or []:
        if not isinstance(message, dict) or message.get('type') != 'worker_done' or worker_done_rejected(message):
            continue
        message_id = message.get('id')
        if not isinstance(message_id, str) or not message_id or message_id in seen:
            continue
        payload = _message_payload(message)
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        if not isinstance(dispatch, str) or dispatch not in by_dispatch:
            continue
        worker = by_dispatch[dispatch]
        if _message_outcome(message, payload, worker) in ('failed', 'failure'):
            continue
        role = _builder_role(worker)
        if role in ('qa', 'qa-sdet', 'reviewer', 'verifier') or _worker_is_verifier(worker):
            continue
        number = worker_pr_number(worker)
        repo = repo_for_worker(worker, config)
        if not number or not repo:
            continue
        body = body_of(repo, number)
        if body is None:
            continue
        reason = gate.finish_block_reason(
            body, issue=_worker_issue_number(worker), diff=diff_of(repo, number) if diff_of else None,
            asked=_dispatch_asked(messages, dispatch, worker), repo_dir=_perf_conf_dir(config, repo, worker))
        if not reason:
            continue
        mail_worker(notify, worker, 'worker_done bounced: ' + reason, allow_settled=True)
        bounced.append(message_id)
        seen.add(message_id)
        lines.append('bounce %s#%s %s' % (repo, number, reason))
    return lines


def relay_done_board(messages, workers, config, state, board_of, set_status, pr_of):
    """Move the card of a worker that sent worker_done but left its board column alone.

    in-review while its PR is open, completed when it has no PR or the PR is closed (#1842).
    A card already in in-review, completed or archived is left as the worker set it.
    board_of returns None when the board cannot be read (retried next pass), 'absent' when it has no card.
    """
    handled = state.setdefault('board_done', [])
    if not isinstance(handled, list):
        handled = state['board_done'] = []
    bounced = set(state.get('bounced_done') or [])
    by_dispatch = {w.get('dispatchId'): w for w in workers or [] if isinstance(w, dict) and w.get('dispatchId')}
    moved = []
    for message in messages or []:
        if not isinstance(message, dict) or message.get('type') != 'worker_done' or worker_done_rejected(message):
            continue
        message_id = message.get('id')
        if not isinstance(message_id, str) or not message_id or message_id in handled or message_id in bounced:
            continue
        payload = _message_payload(message)
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        worker = by_dispatch.get(dispatch)
        if _message_outcome(message, payload, worker) in ('failed', 'failure'):
            continue
        # A held worker_done does not count, so the card stays until a passing resend (#1849).
        if worker is None or release_held(state, dispatch):
            continue
        current = board_of(worker)
        if current is None:
            continue
        target = None
        # 'absent': the board list read fine but has no card for this checkout, so there is nothing to move.
        if current not in ('in-review', 'completed', 'archived', 'absent'):
            number = worker_pr_number(worker)
            if number:
                repo = repo_for_worker(worker, config)
                row = pr_of(repo, number) if repo else None
                if not isinstance(row, dict):
                    continue
                target = 'in-review' if (row.get('state') or 'OPEN').upper() == 'OPEN' else 'completed'
            else:
                target = 'completed'
            if not set_status(worker, target):
                continue
            moved.append('%s:%s' % (dispatch, target))
        handled.append(message_id)
    del handled[:-200]
    return moved


def _agy_signin():
    return _sibling('agy_signin', 'agy-signin.py')


def _agy_signin_line(host):
    """The one coordinator line for a host signed out of agy (#1967)."""
    return Urgent('agy-signin: host=%s is not signed in to agy, skipping it for antigravity for 6 hours. '
                  'Sign in there with script/agy-signin-host.sh %s (not over ssh).' % (host, host))


def agy_signin_notices(config, workers, read=None, now=None, env_names=None):
    """Read the screen of each running antigravity worker. A sign-in screen marks its host agy-unavailable for 6 hours.

    One digest line per host per 6 hours. The line asks the coordinator for the one owner push (#1240).
    A plain `agy -p` probe over ssh cannot tell, so the worker screen is the check.
    """
    agy = _agy_signin()
    notices = []
    seen = set()
    for w in workers or []:
        if not isinstance(w, dict) or worker_agent_id(w) not in ('antigravity', 'agy'):
            continue
        if worker_settled_kind(w) is not None or worker_terminal_released(w):
            continue
        terminal = worker_terminal_handle(w)
        if not terminal:
            continue
        remote = worker_is_remote(w, config)
        env = remote_environment(w) if remote else ''
        if remote and env_names is None:
            env_names = environment_name_by_id()
        # The mark is keyed by host name, the key placement reads, never the environment id (#1967).
        host = host_cap_name(env, config, env_names) if remote else (config.get('local_host') or 'local')
        if not host or host in seen:
            continue
        try:
            if read is not None:
                screen = read(terminal, env)
            else:
                screen = json.dumps(rpc('terminal', 'read', '--terminal', terminal, '--screen',
                                        *(['--environment', env] if remote else [])))
        except SEND_ERRORS:
            continue
        if not agy.is_sign_in_screen(screen):
            continue
        seen.add(host)
        try:
            due = agy.mark(host, now=now, config=config)
        except OSError as error:
            print('fleet-watch: agy-unavailable record failed: %s' % (repr(error),), file=sys.stderr)
            continue
        if due:
            notices.append(_agy_signin_line(host))
    return notices


def persisted_released_ids(state_path):
    """Dispatch ids that earlier passes released (auto_released, remote_reconciled, followup_released) (#1273)."""
    state = _read_json_object(state_path) if state_path else None
    ids = set()
    for key in ('auto_released', 'remote_reconciled', 'followup_released'):
        rows = (state or {}).get(key)
        if isinstance(rows, list):
            ids.update(r for r in rows if isinstance(r, str))
    return ids


def _seat_worker(info, titles):
    evidence = info.get('evidence') if isinstance(info.get('evidence'), dict) else {}
    reason = 'release_unknown' if evidence.get('release_unknown') else str(evidence.get('status') or info.get('category') or '')
    return {'dispatchId': info.get('dispatchId'), 'title': titles.get(info.get('dispatchId'), ''),
            'role': info.get('role'), 'evidence': evidence, 'reason': reason}


def fleet_seat_report(config, config_path=None, state_path=None, workers=None):
    """Live and retained seats per host, with each retained worker named (#1273)."""
    config, _adopted = resolve_pass_config(config or {}, config_path or '')
    if workers is None:
        workers = fetch_workers(config)
    workers = deduplicate_workers(workers)
    titles = {w.get('dispatchId'): w.get('_task_title') or '' for w in workers if isinstance(w, dict)}
    released = persisted_released_ids(state_path)
    env_names = _resolve_env_names(workers, config, None)
    report = {}
    for host, cap in (config.get('host_caps') or {}).items():
        if cap <= 0:
            continue
        receipt = admit(host, config, workers=workers, env_names=env_names, released_ids=released)
        resources = receipt.get('resources') or []
        report[host] = {
            'cap': receipt.get('cap', cap),
            'occupied': receipt.get('occupied'),
            'live_count': receipt.get('live_count', 0),
            'retained_count': receipt.get('retained_count', 0),
            'live_workers': [_seat_worker(r, titles) for r in resources if r.get('category') == 'live'],
            'retained_workers': [_seat_worker(r, titles) for r in resources if r.get('category') != 'live'],
        }
    return report


def format_seat_report(report):
    lines = []
    for host, row in report.items():
        retained = ','.join('%s(%s,%s)' % (w['dispatchId'], w['title'] or w['role'], w['reason'])
                            for w in row['retained_workers']) or 'none'
        lines.append('%s: %s/%s live=%s retained=%s retained_workers=%s' % (
            host, row['occupied'], row['cap'], row['live_count'], row['retained_count'], retained))
    return '\n'.join(lines)


def main():
    # worker-startup.sh checks max_workers only on a hand start; this pass applies it itself (#1957).
    os.environ['FLEET_WATCH'] = '1'
    begin_pass_clock()
    try:
        return _main()
    finally:
        end_pass_clock()


def _main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=False, default=None)
    parser.add_argument('--state', type=Path, required=False)
    parser.add_argument('--admit', type=str, default=None, help='Check host admission under cap')
    parser.add_argument('--admit-local', action='store_true', help='Check coordinator load, memory, and cap admission')
    parser.add_argument('--seats', action='store_true', help='Print live and retained seats per host and exit')
    parser.add_argument('--metrics-digest', type=int, metavar='N', default=None,
                        help='Print the last N hourly metrics lines from the log and exit (#1957)')
    parser.add_argument('--json', action='store_true', help='Emit JSON output')
    parser.add_argument('--babysit-only', action='store_true', help='Run only the babysit dispatch pass')
    parser.add_argument('--babysit-dry-run', action='store_true', help='List babysit dispatches and start nothing')
    parser.add_argument('--sweep-dry-run', action='store_true',
                        help='List the idle orphan terminals the sweep would close and close nothing (#1963)')
    parser.add_argument('--workers-json', type=Path, default=None, help='Worker rows used to read a builder dispatch record')
    parser.add_argument('--next-issue', action='store_true', help='Print the ready issue to start next, in issue scan order, and exit')
    parser.add_argument('--release-worker', metavar='FRAGMENT', default=None,
                        help='Stop, release and close the terminal of the one worker whose id contains FRAGMENT')
    parser.add_argument('--live', action='store_true', help='With --release-worker, allow a live worker')
    parser.add_argument('--heavy-resources', choices=('list', 'teardown'), default=None,
                        help='On this host: list booted simulators, emulators, dev servers and heavy jobs, or with --worktree stop '
                             'the ones that belong to that worktree (#2068)')
    parser.add_argument('--worktree', default=None, help='With --heavy-resources teardown, the worktree path')
    parser.add_argument('--trial-summary', action='store_true', help='Print the standing vs fresh verifier trial report and exit')
    args = parser.parse_args()

    if args.heavy_resources:
        if args.heavy_resources == 'list':
            print('\n'.join(format_heavy_resources(heavy_resources_local())))
        else:
            print('\n'.join(teardown_heavy_resources(args.worktree or '')))
        return 0

    if args.metrics_digest is not None:
        for line in metrics_digest(read_log_tail(), args.metrics_digest):
            print(line)
        return 0

    if args.trial_summary:
        print(trial_summary(read_trial_rows()))
        return 0

    if args.release_worker is not None:
        cfg_path = args.config or Path(os.environ.get('FLEET_WATCH_CONFIG') or os.path.expanduser('~/.config/fleet-watch/config.json'))
        config = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        config, _adopted = resolve_pass_config(config, cfg_path)
        code, message = release_worker_by_fragment(args.release_worker, config, rpc, sweep_hosts(config), args.live)
        print('release-worker: ' + message, file=sys.stdout if code == 0 else sys.stderr)
        return code

    if args.next_issue:
        if args.config is not None:
            cfg_path = args.config
        else:
            cfg_path = Path(os.environ.get('FLEET_WATCH_CONFIG') or os.path.expanduser('~/.config/fleet-watch/config.json'))
        config = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        config, _adopted = resolve_pass_config(config, cfg_path)
        scan = config.get('issue_scan') or {}
        repos = scan.get('repos') or repos_from_roots(scan.get('repo_roots') or config.get('repo_roots'))[0]
        found = next_ready_issue(repos, fetch_ready_issues)
        if found is None:
            print('none')
            return 1
        print('%s#%s %s' % (found[0], found[1].get('number'), found[1].get('title') or ''))
        return 0

    if args.admit or args.admit_local or args.seats:
        if args.config is not None:
            cfg_path = args.config
            config = json.loads(args.config.read_text()) if args.config.exists() else {}
        else:
            cfg_env = os.environ.get('FLEET_WATCH_CONFIG') or os.path.expanduser('~/.config/fleet-watch/config.json')
            cfg_path = Path(cfg_env)
            config = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        if args.seats:
            report = fleet_seat_report(config, cfg_path, args.state)
            print(json.dumps(report, indent=2) if args.json else format_seat_report(report))
            return 0
        config, _adopted = resolve_pass_config(config, cfg_path)
        target = args.admit if args.admit else (config.get('local_host') or 'local')
        receipt = admit(target, config, released_ids=persisted_released_ids(args.state))
        print(json.dumps(receipt, indent=2))
        return 0 if receipt.get('admitted') else 1

    if not args.config:
        parser.error('--config is required')
    config = json.loads(args.config.read_text())
    config, adopted = resolve_pass_config(config, args.config)
    if adopted is not None:
        print('fleet-watch: using coordinator config %s' % adopted, file=sys.stderr)
    remember_config_mtime(config, adopted or args.config)

    if args.sweep_dry_run:
        # Read only: no state file needed, and no pass lock, so it never blocks or skips a real pass.
        state = json.loads(args.state.read_text()) if args.state and args.state.exists() else {}
        apply_active_run(config)
        try:
            workers = fetch_workers(config)
        except Exception as error:
            print('fleet-watch: Orca workers unavailable: %s' % (repr(error),), file=sys.stderr)
            return 1
        hosts = sweep_hosts(config)
        workers = fleet_rows(config, workers, hosts, rpc, state)
        protect_pass_terminals(config, workers)
        orphan_terminal_sweep(config, time.time(), rpc, hosts, workers, dry_run=print)
        return 0

    if not args.state:
        parser.error('--state is required when --admit is not specified')

    if not args.babysit_dry_run:
        pass_lock = acquire_pass_lock(args.state)
        if pass_lock is None:
            print('fleet-watch: another pass is running on %s; skipping this one' % args.state, file=sys.stderr)
            return 0

    state = json.loads(args.state.read_text()) if args.state.exists() else {}
    if args.babysit_only or args.babysit_dry_run:
        apply_active_run(config)
        workers = []
        if args.workers_json:
            loaded = json.loads(args.workers_json.read_text())
            workers = loaded if isinstance(loaded, list) else []
        else:
            try:
                workers = fetch_workers(config)
            except Exception as error:
                print('fleet-watch: Orca workers unavailable: %s' % (repr(error),), file=sys.stderr)
        dry = bool(args.babysit_dry_run)
        # The default release callback acts on these rows, so they carry their host like a full pass's (#1958).
        workers = fleet_rows(config, workers, [''] if args.workers_json else sweep_hosts(config), rpc, state)
        protect_pass_terminals(config, workers)

        def persist_babysit():
            save_state(args.state, state)

        _babysit_notices, babysit_lines, _babysit_log = babysit_pass(
            config, state, workers, dry_run=dry,
            persist_state=None if dry else persist_babysit,
        )
        for line in babysit_lines:
            print(line)
        if not dry:
            save_state(args.state, state)
        return 0
    begin_pass_counts()
    # A backup host has coordinator_watch and no runs. That path stays the one that
    # never calls Orca, including when this machine's Orca has other Runs.
    if config.get('coordinator_watch') and not config_runs(config):
        _coordinator, done = coordinator_stage(config, state, args.state)
        if done:
            finish_pass('coordinator watch')
            return 0
    status = bind_pass_config(config)
    if status == 'no-run':
        config['runs'] = []
        print('fleet-watch: ' + NO_COORDINATOR_RUN, file=sys.stderr)
        finish_pass(NO_COORDINATOR_RUN)
        if not config.get('coordinator_watch'):
            return 0
    apply_active_run(config)
    if not config_runs(config) and not config.get('coordinator_watch'):
        watched = adopted or args.config
        message = 'config %s has no runs; refusing this pass' % watched
        print('fleet-watch: ' + message, file=sys.stderr)
        finish_pass(message)
        return 1
    coordinator, done = coordinator_stage(config, state, args.state)
    if done:
        finish_pass('coordinator watch')
        return 0
    pass_start = time.time()
    now = pass_start

    def on_term(_signum, _frame):
        log_killed_pass(pass_start)
        os._exit(143)

    signal.signal(signal.SIGTERM, on_term)
    workers = []
    notices = []
    inventory_ok = True
    holds_ok = True
    pass_phase('inventory')
    try:
        inv = read_orca_inventory(config)
        # One row per dispatch, tagged with its host, read once; every later phase uses this list (#1958).
        workers = fleet_rows(config, inv['workers'], sweep_hosts(config), rpc, state)
        protect_pass_terminals(config, workers)
        notices = alerts(
            config, state, now,
            inv['messages'], workers, inv['alive'], inv['leads'],
        )
        state.pop('orca_inventory_skip_latched', None)
        try:
            notices += gone_remote_dispatch_notices(workers, state, rpc)
            notices += unanswered_ask_notices(state, now, inv['messages'], workers, answered=read_answered_asks())
            notices += take_ask_reply_lines(state)
            write_open_work(state, workers, config, now, open_work_path(args.state))
        except Exception as error:
            print('fleet-watch: live count check skipped: %s' % (repr(error),), file=sys.stderr)
        try:
            update_done_holds(state, inv['messages'], workers, now, read_full=read_full_inbox_bodies)
        except Exception as error:
            # Without fresh holds nothing may be released this pass.
            holds_ok = False
            print('fleet-watch: done hold check skipped: %s' % (repr(error),), file=sys.stderr)
        try:
            if holds_ok:
                notices += reconcile_remote_completions(config, state, workers, inv['messages'], rpc)
                notices += send_done_hold_notices(state, workers, config, now, rpc)
            for failed in workers:
                enrich_failed_worker_show(failed, state, rpc)
        except Exception as error:
            print('fleet-watch: remote reconcile skipped: %s' % (repr(error),), file=sys.stderr)
    except Exception as error:
        inventory_ok = False
        workers = []
        print('fleet-watch: Orca inventory unavailable: %s' % (repr(error),), file=sys.stderr)
        if not state.get('orca_inventory_skip_latched'):
            notices.append(ORCA_SKIP_NOTICE)
            state['orca_inventory_skip_latched'] = True
    if inventory_ok:
        def _notify_bounce(terminal, text):
            if not terminal:
                return
            try:
                rpc('terminal', 'send', '--terminal', terminal, '--text', text, '--enter')
            except SEND_ERRORS as error:
                log_send_failed(terminal, error)

        try:
            for line in bounce_builder_dones(
                inv['messages'], workers, fetch_pr_body, _notify_bounce, state, config, diff_of=fetch_pr_diff,
            ):
                print('fleet-watch: ' + line)
        except Exception as error:
            print('fleet-watch: builder bounce skipped: %s' % (repr(error),), file=sys.stderr)
        try:
            notices += answered_owner_asks(inv['messages'], workers, state, config)
        except Exception as error:
            print('fleet-watch: owner answer check skipped: %s' % (repr(error),), file=sys.stderr)
    term_times = {}
    term_branches = {}
    terminal_list_ok = True
    pass_phase('terminals')
    try:
        term_out = rpc('terminal', 'list', '--json')
        term_times = terminal_last_output_map(term_out)
        term_branches = terminal_branch_map(term_out)
    except SEND_ERRORS:
        terminal_list_ok = False
    pass_prs = {}

    def fetch_once(repo):
        if repo not in pass_prs:
            pass_prs[repo] = fetch_prs(repo)
        return pass_prs[repo]

    def closed_from_pass(repo):
        rows = fetch_once(repo)
        if not isinstance(rows, list):
            return None
        return [row for row in rows if _babysit_closed(row)]

    pass_phase('release')
    if inventory_ok and holds_ok:
        try:
            def pr_of(repo, number):
                return next(
                    (row for row in (fetch_once(repo) or []) if isinstance(row, dict) and row.get('number') == number),
                    None,
                )

            def board_status(worker, status):
                return set_board_status(rpc, worker, status, worker.get('_host') or '')

            boards = {}

            def board_of(worker):
                env = worker.get('_host') or ''
                if env not in boards:
                    try:
                        listed = rpc('worktree', 'list', *(('--environment', env) if env else ()))
                        boards[env] = {
                            (row.get('path') or '').rstrip('/'): row.get('workspaceStatus') or ''
                            for row in (listed or {}).get('worktrees') or [] if isinstance(row, dict)
                        }
                    except SEND_ERRORS:
                        boards[env] = None
                if boards[env] is None:
                    return None
                return boards[env].get(worker_checkout_path(worker).rstrip('/'), 'absent')

            try:
                for line in relay_done_board(inv['messages'], workers, config, state, board_of, board_status, pr_of):
                    print('fleet-watch: board %s' % line)
            except Exception as error:
                print('fleet-watch: board relay skipped: %s' % (repr(error),), file=sys.stderr)
            freed = release_green_successes(
                inv['messages'], workers, config, state, _release_row, pr_of, set_status=board_status,
            )
            freed += release_dead_followups(workers, state, _release_row)
            for dispatch_id in freed:
                print('fleet-watch: released %s' % dispatch_id)
        except Exception as error:
            print('fleet-watch: auto-release skipped: %s' % (repr(error),), file=sys.stderr)

    pass_phase('pr_notices')
    notices += pr_notices(config, state, now, fetch=fetch_once)
    pass_phase('notices')
    notices += usage_notices(config)
    workflow_watch_prior = copy.deepcopy(state.get('workflow_watch') or {})
    notices += workflow_notices(config, state, now)
    notices += main_red_notices(config, state, now)
    backup_age = backup_age_seconds(config, now)
    notices += backup_notices(config, state, now)
    heavy_extra, heavy_log = heavy_gate_notices(config, state, now)
    wrap_extra, wrap_log = wrap_up_notices(config, state, now)
    notices += heavy_extra + wrap_extra
    notices += stale_board_notices(config, state, now)
    notices += fleet_pull_after_ship_notices(config, state, now)
    notices += template_pin_notices(config, state, now)
    notices += template_sync_reconcile(config, state, now)
    notices += changelog_fragment_notices(config, state)
    notices += stale_worktree_notices(config, state, now)
    notices += orphan_reaper_notices(config)
    mailbox_log = run_phase('mailbox_alert', lambda: mailbox_alert_pass(config), [])

    def persist_scan_state():
        save_state(args.state, state)

    def idle_seat():
        if not (inventory_ok and terminal_list_ok):
            return [], []
        try:
            return idle_seat_pass(config, state, now, workers, term_times, inv['messages'], rpc)
        except Exception as error:
            print('fleet-watch: idle seat skipped: %s' % (repr(error),), file=sys.stderr)
            return [], []

    def agy_probe_phase():
        try:
            return agy_probe_notices(config, state, now)
        except Exception as error:
            print('fleet-watch: agy probe skipped: %s' % (repr(error),), file=sys.stderr)
            return []

    def heavy_jobs_phase():
        try:
            heavy_jobs_pass(config, state, now, workers, rpc)
        except Exception as error:
            print('fleet-watch: heavy job report skipped: %s' % (repr(error),), file=sys.stderr)
        return []

    def sim_stall_phase():
        try:
            return sim_stall_pass(config, state, now, workers, rpc)
        except Exception as error:
            print('fleet-watch: simulator stall check skipped: %s' % (repr(error),), file=sys.stderr)
            return []

    # Before the first phase that can start a worker, so a signed out host is marked first (#1968).
    notices += run_phase('agy_probe', agy_probe_phase, [])
    idle_extra, idle_log = run_phase('idle_seat', idle_seat, ([], []))
    notices += idle_extra
    if inventory_ok:
        # Without the pass rows every worker looks gone: no reap, no sweep, and the reaper book is kept.
        notices += run_phase('reap', lambda: start_unknown_reaper(config, state, now, workers, rpc, _release_row), [])
        swept = run_phase('sweep', lambda: orphan_terminal_sweep(config, now, rpc, sweep_hosts(config), workers), [])
        if swept:
            print('fleet-watch: closed %d orphan terminal(s): %s' % (len(swept), ' '.join(swept)))
        notices += supply_done_notices(inv['messages'], workers, state)

    def supply_first():
        if not inventory_ok:
            return []
        try:
            return issue_scan_supply_first(config, state, now, workers, persist_state=persist_scan_state, pr_fetch=fetch_once)
        except Exception as error:
            print('fleet-watch: early supply skipped: %s' % (repr(error),), file=sys.stderr)
            return []

    supply_first_log = run_phase('supply_first', supply_first, [])

    pass_phase('babysit')
    babysit_notices, babysit_lines, babysit_log = babysit_pass(
        config, state, workers, persist_state=persist_scan_state,
        now=now, term_times=term_times, pr_fetch=fetch_once, closed_fetch=closed_from_pass,
        pr_state_fetch=fetch_open_prs,
    )
    for line in babysit_lines:
        print(line)
    notices += babysit_notices
    def audit():
        try:
            audit_lines, audit_log = tier0_audit_pass(config, state, now, persist_state=persist_scan_state)
            for line in audit_lines:
                print(line)
            return audit_log
        except Exception as error:
            print('fleet-watch: tier 0 audit skipped: %s' % (repr(error),), file=sys.stderr)
            return []

    # From here each phase is skipped once the pass is PASS_HARD_END old; deliver and save always run (#1838).
    babysit_log = list(babysit_log) + run_phase('audit', audit, [])
    scan_extra, scan_log = run_phase('issue_scan', lambda: issue_scan_pass(
        config, state, now, workers,
        pr_fetch=fetch_once,
        inventory_ok=inventory_ok,
        persist_state=persist_scan_state,
        workflow_watch_prior=workflow_watch_prior,
        babysit_repos=babysit_dispatch_repos(config),
    ), ([], []))
    notices += scan_extra
    status = work_order_status_notice(config, state, now, workers, _PASS.started if _PASS is not None else 0)
    if status:
        notices.append(status)
    notices += usage_gate_notices(state, now)
    if inventory_ok:
        try:
            notices += agy_signin_notices(config, workers, now=now)
        except Exception as error:
            print('fleet-watch: agy sign-in check skipped: %s' % (repr(error),), file=sys.stderr)
    stall_extra, stall_log = run_phase('stall', lambda: worker_stall_pass(
        config, state, now, workers, term_times, rpc,
        terminal_list_ok=terminal_list_ok, terminal_branches=term_branches,
        inventory_ok=inventory_ok, pr_list=fetch_once,
        waiting=waiting_on_coordinator(state, workers), reaper=reaper_owned(state)), ([], []))
    notices += stall_extra
    if inventory_ok:
        notices += run_phase('sim_stall', sim_stall_phase, [])
        notices += run_phase('heavy_jobs', heavy_jobs_phase, [])
    signal_extra, signal_log = run_phase('signal', lambda: worker_signal_pass(
        config, state, now, workers, term_times, terminal_branches=term_branches,
        inventory_ok=inventory_ok, terminal_list_ok=terminal_list_ok), ([], []))
    notices += signal_extra

    def durations():
        if not inventory_ok:
            return [], []
        try:
            return worker_duration_pass(config, state, now, workers, inv['messages'])
        except Exception as error:
            print('fleet-watch: worker limit check skipped: %s' % (repr(error),), file=sys.stderr)
            return [], []

    def ci_hang():
        try:
            return ci_hang_pass(config, state, now, fetch=fetch_once)
        except Exception as error:
            print('fleet-watch: hung check pass skipped: %s' % (repr(error),), file=sys.stderr)
            return [], []

    limit_extra, limit_log = run_phase('limits', durations, ([], []))
    hang_extra, hang_log = run_phase('ci_hang', ci_hang, ([], []))
    notices += limit_extra + hang_extra

    def nudge():
        if not (inventory_ok and terminal_list_ok):
            return []
        try:
            return unread_nudge_pass(state, now, workers, term_times, inv['messages'], rpc)
        except Exception as error:
            print('fleet-watch: unread nudge skipped: %s' % (repr(error),), file=sys.stderr)
            return []

    nudge_log = run_phase('nudge', nudge, [])
    notices += coordinator
    notices += drain_notices(config)
    pass_phase('deliver')

    duration = time.time() - pass_start
    parts = []
    if duration > PASS_FAIL_LIMIT:
        parts.append('pass failed: %.1fs' % duration)
    else:
        parts.append('pass ok %.1fs' % duration)
    if pass_deadline_line():
        parts.append(pass_deadline_line())
    if not terminal_list_ok:
        parts.append('terminal_list_failed')
    if inventory_ok:
        parts.extend(pass_waste_parts(workers))  # read by the hourly metrics line (#1957)
    if backup_age is not None:
        parts.append('backup_age_s=%d' % int(backup_age))
        if backup_age > BACKUP_STALE_LOG:
            parts.append('backup_stale')
    if heavy_log:
        parts.extend(heavy_log)
    if wrap_log:
        parts.extend(wrap_log)
    parts.extend(mailbox_log)
    if stall_log:
        parts.append('stall ' + ','.join(stall_log))
    if signal_log:
        parts.append('signal ' + ','.join(signal_log))
    if limit_log:
        parts.append('limits ' + ','.join(limit_log))
    if hang_log:
        parts.append('ci ' + ','.join(hang_log))
    if nudge_log:
        parts.append('nudge ' + ','.join(nudge_log))
    if idle_log:
        parts.append('idle ' + ','.join(idle_log))
    if supply_first_log:
        parts.append('supply ' + ','.join(supply_first_log))
    if babysit_log:
        parts.append('babysit ' + ','.join(babysit_log))
    if scan_log:
        parts.append('scan ' + ','.join(scan_log))
    try:
        for repo in babysit_repos(config):
            if pass_deadline_reached():  # the next pass prunes; a fetch here could run past the timeout
                break
            if repo not in pass_prs and _state_tracks_repo(state, repo):
                pass_prs[repo] = fetch_prs(repo)
        prune_closed_maps(state, pass_prs, {})
        prune_closed_issues(state, fetch_closed_issue_rows)
        if not pass_deadline_reached():
            try:
                maybe_log_hourly_metrics(config, state, now)
            except Exception as error:
                print('fleet-watch: hourly metrics skipped: %s' % (repr(error),), file=sys.stderr)
        deliver_notices(config, state, notices, rpc, pass_start)
        if notices:
            print('fleet-watch: ' + '; '.join(str(notice) for notice in notices))
        save_state(args.state, state)
    finally:
        pass_phase(None)
        phases = pass_phases_line()
        # Counts go before the phases so the line ends with them (finish_pass appends counts that are missing).
        finish_pass('; '.join(parts + ([pass_counts_line(), phases] if phases else [])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
