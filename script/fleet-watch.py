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
import statistics
import subprocess
import sys
import tempfile
import time

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
        if worker.get('pushed') is False or evidence_dict.get('pushed') is False:
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'retained',
                'role': role or 'author',
                'evidence': {'status': status, 'pushed': False, 'released': True}
            }
            return True, info, False
        else:
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


def read_orca_inventory(config):
    """Read inbox, workers, lead terminals, and pgrep in one pass; validate JSON shapes. Raises OrcaReadError."""
    inbox = rpc('orchestration', 'inbox', '--limit', '5000')
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


def task_titles(run_id):
    """Map task id to title for a Run; empty when the task list cannot be read (worker rows then carry no title)."""
    try:
        result = rpc('orchestration', 'task-list', '--run', run_id)
    except Exception:
        return {}
    tasks = result.get('tasks') if isinstance(result, dict) else None
    return {t['id']: t['title'] for t in tasks or [] if isinstance(t, dict) and t.get('id') and t.get('title')}


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
        titles = task_titles(run_id)
        for result in list_pages('orchestration', 'worker-list', '--run', run_id, '--include-remote', '--full'):
            for w in result.get('workers', []):
                if isinstance(w, dict) and titles.get(worker_task_id(w)):
                    w['_task_title'] = titles[worker_task_id(w)]
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
    return any(placement.host_has_repo_mapping(config, host, local, sel) for sel in selectors)


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


def admit(host, config, workers=None, env_names=None, repo=None, repo_lookup=None):
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

    admitted = (occupied_count < cap)
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
        'reason': 'admitted' if admitted else ('host cap exceeded: %s %d/%d' % (host, occupied_count, cap)),
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
    """A failed dispatch that is already released or settled is not a new alert."""
    if worker_terminal_released(worker):
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

    for host, cap in config.get('host_caps', {}).items():
        if counts.get(host, 0) > cap:
            notices.append(Urgent('host cap exceeded: %s %d/%d (includes child dispatches)' % (host, counts[host], cap)))
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
    'reviewDecision,files,labels,comments,statusCheckRollup,mergeCommit,body'
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
                if not baseline:
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


def pass_counts_line():
    counts = _PASS if _PASS is not None else PassCounts()
    return counts.line()


def _pass_note(field):
    if _PASS is not None:
        setattr(_PASS, field, getattr(_PASS, field) + 1)


def count_started():
    _pass_note('started')


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


def worker_row_is_live(w):
    """True when this worker-list row is an in-progress supervised worker (both JSON shapes)."""
    w = w or {}
    if 'dispatchStatus' in w or 'projection' in w:
        proj = w.get('projection') or {}
        liv = proj.get('liveness') or {}
        ver = liv.get('verdict') if isinstance(liv, dict) else liv
        return (w.get('terminalState') in ('active', 'retained')
                and w.get('dispatchStatus') not in ('completed', 'failed', 'cancelled', 'abandoned')
                and (proj.get('outcome') or 'in_progress') == 'in_progress'
                and ver != 'exited')
    return (w.get('state') not in ('succeeded', 'completed', 'failed', 'cancelled', 'released', 'abandoned', 'stopped')
            and w.get('stage') != 'released' and w.get('terminalState') != 'released'
            and w.get('liveness') != 'exited')


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
    if not agent:
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


def record_own_dispatch(state, dispatch_id, kind, retry_of=None, restart_at=None, restarted=False):
    """Remember a dispatch fleet-watch started. Empty ids are ignored."""
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


def remember_started_dispatch(state, result, kind):
    """Record a verifier, rework worker, or scanned issue. Other starts are not ours to restart."""
    if kind not in ('verifier', 'rework', 'issue'):
        return
    record_own_dispatch(state, dispatch_id_from_start(result), kind)


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
        'stalled worker %s is not one fleet-watch started; coordinator recovers it with worker-watch.sh'
        % dispatch_id))


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


def worker_stall_pass(config, state, now, workers, term_times, rpc_call, act=None, terminal_list_ok=True,
                     terminal_branches=None, inventory_ok=True):
    """Restart our own silent workers once; report every other stalled worker once and do not stop it.

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

    def restart_own(w, did):
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
            rpc_call('orchestration', 'worker-stop', '--dispatch', did)
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

    local_handles = set(term_times.keys())
    for w in workers:
        did = w.get('dispatchId')
        if not isinstance(did, str) or not did:
            continue
        if not worker_row_is_live(w):
            continue
        term = worker_terminal_handle(w)
        if not term:
            continue
        host_id = worker_execution_host_id(w)
        last_s = _normalize_terminal_time_ms(term_times.get(term))
        is_stalled = worker_should_restart_for_terminal_stall(w, now, last_s, stall_limit)
        if host_id != 'local':
            if is_stalled:
                log_bits.append('remote_stall_unknown=%s' % did)
                if _own_row(state, did):
                    restart_own(w, did)
                else:
                    _report_foreign_stall(state, did, notices, log_bits)
            continue
        if term not in local_handles:
            continue
        if not is_stalled:
            continue
        if _own_row(state, did):
            restart_own(w, did)
        else:
            _report_foreign_stall(state, did, notices, log_bits)

    return notices, log_bits


_ISSUE_ACCEPTANCE_RE = re.compile(
    r'^(?:## (?:[0-9]+[.)] +)?(?:Acceptance(?: criteria)?|Done check)\b|\*\*Acceptance(?: criteria)?:\*\*)',
    re.I | re.M)


def issue_scan_has_acceptance(text):
    return bool(_ISSUE_ACCEPTANCE_RE.search(text or ''))


def issue_scan_brief_text(issue):
    """The newest comment with acceptance criteria (the triage Agent Brief), else the body."""
    comments = [entry.get('body') or '' for entry in (issue.get('comments') or []) if isinstance(entry, dict)]
    for text in reversed(comments):
        if issue_scan_has_acceptance(text):
            return text
    return issue.get('body') or ''


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


def issue_scan_eligible(issue):
    labels = {entry.get('name') for entry in (issue.get('labels') or []) if isinstance(entry, dict)}
    if 'ready-for-agent' not in labels:
        return False
    if issue_scan_blocked(issue):
        return False
    texts = [issue.get('body') or '']
    texts += [entry.get('body') or '' for entry in (issue.get('comments') or []) if isinstance(entry, dict)]
    return any(issue_scan_has_acceptance(text) for text in texts)


def issue_scan_priority(issue):
    labels = {entry.get('name') for entry in (issue.get('labels') or []) if isinstance(entry, dict)}
    if 'P0' in labels:
        return 0
    if 'P1' in labels:
        return 1
    return 2


def issue_scan_sort_key(issue):
    created = issue.get('createdAt') or ''
    return (issue_scan_priority(issue), created)


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
    r'(?: verifier=(?P<verifier>[A-Za-z0-9_-]+) author=(?P<author>[A-Za-z0-9_-]+))?$'
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
            and pr_verdict_valid_for_head(pr_row, repo_root=repo_root)):
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


def rework_failure_excerpt(pr_row):
    head = pr_row.get('headRefOid') or ''
    comments = pr_row.get('comments') or []
    comment = newest_comment_receipt(comments, 'Checks', head)
    if comment:
        first = _receipt_first_line(comment.get('body'))
        if first.startswith('Checks: FAIL'):
            return (comment.get('body') or '')[:8000]
    for label in ('Review', 'Verdict'):
        comment = newest_comment_receipt(comments, label, head)
        if comment and rs.newest_receipt_kind(comments, label, head) == 'FAIL':
            return (comment.get('body') or '')[:8000]
    for check in pr_row.get('statusCheckRollup') or []:
        if not isinstance(check, dict) or check.get('conclusion') != 'FAILURE':
            continue
        name = check.get('context') or check.get('name') or 'check'
        parts = ['statusCheckRollup FAILURE: %s' % name]
        summary = check.get('summary') or check.get('title')
        if summary:
            parts.append(summary)
        return '\n'.join(parts)
    return 'Rework after failure on head %s' % head


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
    lock = _repo_checks_lock_path(repo_root)
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


def build_ship_command(repo, pr_row):
    script = str(Path(__file__).with_name('ship.sh'))
    return ['bash', script, '--repo', repo, '--pr', str(pr_row['number'])]


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
    return rs.review_failed_at_head(pr)


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
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (subprocess.SubprocessError, OSError):
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


def default_repo_id_lookup(host, repo):
    """Orca repo id of owner/name on an environment, matched by git remote since paths differ per host."""
    try:
        result = rpc('repo', 'list', '--environment', host)
    except Exception:
        return None
    key = 'github.com/%s' % repo.lower()
    for row in (result.get('repos') if isinstance(result, dict) else None) or []:
        if not isinstance(row, dict) or not row.get('id'):
            continue
        identity = row.get('gitRemoteIdentity') or {}
        if str(identity.get('canonicalKey') or '').lower() == key:
            return row['id']
    return None


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


def build_issue_start_command(config, repo, issue_row, placement=None):
    """placement is (host, repo_id) to start on a remote host instead of the local checkout."""
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    verify = checks_local_verify_text(
        root, 'Run bash script/checks-local.sh and show the Done condition.')
    role = scan.get('role') or 'builder'
    spec_path = _write_issue_scan_spec(_with_preamble(
        'Refs %s#%d\n\n%s\n\n'
        '## Verify\n'
        '%s\n\n'
        '## Finish\n'
        'Self-review, push, open the PR, wait until gh pr checks <n> --watch --fail-fast (or gh run list --branch <branch> --limit 3) passes at the final head, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        % (repo, issue_row['number'], issue_scan_brief_text(issue_row).rstrip(), verify),
        role))
    title = '%s - #%d' % (role, issue_row['number'])
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', title,
        '--agent', scan.get('agent') or 'cursor',
        '--model', scan.get('model') or '',
        '--from', scan['from_terminal'],
        '--name', 'issue-%d' % issue_row['number'],
        '--repo', 'path:' + root,
    ]
    if placement:
        command[command.index('--repo') + 1] = 'id:' + placement[1]
        command += ['--on', placement[0]]
    return [part for part in command if part]


def build_rework_start_command(config, repo, pr_row):
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
    title = 'rework #%d' % pr_row['number']
    agent = scan.get('rework_agent') or scan.get('agent') or 'cursor'
    model = scan.get('rework_model') or scan.get('model') or ''
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', title,
        '--agent', agent,
        '--model', model,
        '--from', scan['from_terminal'],
        '--name', 'rework-%d' % pr_row['number'],
        '--repo', 'path:' + root,
    ]
    branch = pr_row.get('headRefName')
    if branch:
        command += ['--base-branch', pr_base_ref(root, branch)]
    return [part for part in command if part]


_BACKLOG_SWEEP_ROLES = ('architect-pm', 'sales-marketing')
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
    agent = scan.get('sweep_agent') or scan.get('agent') or 'cursor'
    model = scan.get('sweep_model') or scan.get('model') or ''
    command = [
        'bash', _issue_scan_startup_script(config),
        '--run', scan['run'],
        '--spec', spec_path,
        '--title', '%s backlog-sweep' % role,
        '--agent', agent,
        '--model', model,
        '--from', scan['from_terminal'],
        '--name', 'backlog-%s' % role,
        '--repo', 'path:' + root,
    ]
    return [part for part in command if part]


def issue_scan_backlog_sweep_roles_remaining(state):
    done = set(state.get('issue_scan_backlog_sweep_roles') or ())
    return [role for role in _BACKLOG_SWEEP_ROLES if role not in done]


def issue_scan_try_backlog_sweep(
    config, state, now, repos, ready_queue_count, host, admission, extra_starts,
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
    state['issue_scan_backlog_sweep_pending'] = True
    if persist_state:
        persist_state()
    started = 0
    for role in roles:
        command = build_backlog_sweep_command(config, repo, role)
        if command is None:
            log_bits.append('backlog_sweep_skip=%s' % role)
            continue
        if start_worker(command) == 0:
            started += 1
            log_bits.append('backlog_sweep_start=%s' % role)
            count_started()
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
    agent = scan.get('agent') or 'cursor'
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


def pr_owner_only_reason(pr, run=subprocess.run):
    """Refuse text from check_owner_only_paths, None when the PR is clear, or 'error'."""
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
    if proc.returncode == 0:
        return None
    if proc.returncode == 2:
        message = (proc.stderr or proc.stdout or '').strip()
        return message or 'owner-only path'
    return 'error'


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


def resolve_pass_config(config, config_path):
    """Use the coordinator file when the scheduled stub config has no runs."""
    if config_runs(config):
        return config, None
    stub = Path.home() / '.config' / 'fleet-watch' / 'config.json'
    try:
        given_is_stub = Path(config_path).resolve() == stub.resolve()
    except OSError:
        given_is_stub = False
    if not given_is_stub:
        return config, None
    path = coordinator_config_path()
    try:
        loaded = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return config, None
    if isinstance(loaded, dict) and config_runs(loaded):
        for key in ('host_caps', 'local_host', 'host_load_ceilings'):
            if key in config and key not in loaded:
                loaded[key] = config[key]
        return loaded, path
    return config, None


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
    return [repo for repo in (scan.get('repos') or []) if isinstance(repo, str) and repo]


def babysit_settings(config):
    scan = config.get('issue_scan') or {}
    block = config.get('babysit') or {}
    startup = (block.get('startup') or scan.get('startup') or '').strip()
    if not startup:
        startup = str(Path(__file__).with_name('worker-startup.sh'))
    run_id = (block.get('run') or scan.get('run') or '').strip()
    from_terminal = (block.get('from_terminal') or scan.get('from_terminal') or '').strip()
    roots = block.get('repo_roots') or scan.get('repo_roots') or {}
    if not isinstance(roots, dict):
        roots = {}
    return startup, run_id, from_terminal, roots


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
_TITLE_PR_RE = re.compile(r'(?:#|\bPR\s+)(\d+)', re.I)


def verifier_title_pr(worker):
    """PR number named by a verifier task title ("qa-sdet - verify PR #7" or "qa-sdet verify o/r#7"), else None.

    Real worker-list rows carry no role, PR number or branch, only a taskId; fetch_workers joins the task title.
    """
    match = _VERIFY_TITLE_RE.match(str(worker.get('_task_title') or '').strip())
    found = _TITLE_PR_RE.search(match.group(1)) if match else None
    return int(found.group(1)) if found else None


def live_verifier_worker(pr, workers):
    """The live verifier worker on this PR, hand dispatched or not, else None."""
    number = pr.get('number')
    for worker in workers or []:
        if not isinstance(worker, dict) or not worker_row_is_live(worker):
            continue
        if number is not None and verifier_title_pr(worker) == number:
            return worker
    return None


def live_verifier_for_pr(pr, workers):
    """True when a live verifier worker, hand dispatched or not, is already on this PR."""
    return live_verifier_worker(pr, workers) is not None


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
    if worker is None:
        return False
    release(worker.get('dispatchId') or '')
    _verifier_head_bucket(state, repo).pop(str(pr.get('number')), None)
    return True


def release_idle_rework_verifier(pr, workers, state, repo, now, term_times, release):
    """Release a verifier that has waited out a rework for an hour. True when released."""
    worker = live_verifier_worker(pr, workers)
    if worker is None or not rework_needed_at_head(pr):
        return False
    if verifier_idle_seconds(worker, term_times, now) < VERIFIER_REWORK_IDLE_SECONDS:
        return False
    release(worker.get('dispatchId') or '')
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
            release(worker.get('dispatchId') or '')
            bucket.pop(str(number), None)
            return 'released'
        notify(
            worker_terminal_handle(worker),
            'Rework head %s is on %s#%s. Recheck only your fix list and the brief search command.'
            % (head, repo, number),
        )
        bucket[str(number)] = head
        return 'sticky'
    if not tracked:
        bucket[str(number)] = head
        return 'recorded'
    return 'live'


def builder_pair(pr, workers=None):
    """Builder agent and model from the PR body, else a matching dispatch record."""
    found = None
    for line in (pr.get('body') or '').splitlines():
        match = _BUILDER_LINE_RE.match(line.strip())
        if match:
            found = (match.group(1), match.group(2))
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


def pick_role(role, run=subprocess.run, avoid_family=None):
    command = _usage_gate_argv() + ['pick', '--role', role, '--json', '--auto']
    if avoid_family:
        command += ['--avoid-family', avoid_family]
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


def _babysit_line(repo, number, head, action, detail=''):
    text = 'babysit %s#%s head=%s action=%s' % (repo, number, head, action)
    if detail:
        text += ' ' + detail
    return text


def build_babysit_spec(repo, pr_row, kind, builder, root, verdict_tag=''):
    number = pr_row['number']
    head = pr_row.get('headRefOid') or ''
    verify = checks_local_verify_text(root, 'bash script/checks-local.sh')
    if kind == 'verifier':
        if builder:
            who = 'The builder is agent=%s model=%s. Use a different agent and model.' % builder
        else:
            who = 'The builder agent and model were not recorded.'
        if verdict_tag:
            who += ' No other family has quota. Tag the Verdict %s.' % verdict_tag
        verify = (
            'GitHub Checks are green at head %s. Review the diff and run the live checks this brief names.'
            % head
        )
        text = (
            'Refs %s#%s\n\n'
            'Role: qa-sdet. Verify this open PR at head %s the way a user would, '
            'and post the Verdict with script/post-verdict.sh. %s\n\n'
            '## Acceptance\n'
            '- [ ] a Verdict for head %s is posted\n\n'
            '## Out of scope\n'
            'Merging. fleet-watch starts ship.sh for a ready head. Verdict format stays as it is.\n\n'
            '## Verify\n'
            '%s\n\n'
            '## Finish\n'
            'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        ) % (repo, number, head, who, head, verify)
        return _write_issue_scan_spec(_with_preamble(text, 'qa-sdet'))
    else:
        text = (
            'Refs %s#%s\n\n'
            'Role: fullstack-dev. Fix this PR. head-checks failed at head %s.\n\n'
            '## Acceptance\n'
            '- [ ] head-checks pass for the new head\n\n'
            '## Out of scope\n'
            'Merging. fleet-watch starts ship.sh for a ready head. Files outside this PR.\n\n'
            '## Verify\n'
            '%s\n\n'
            '## Finish\n'
            'Wait until gh pr checks <n> --watch --fail-fast (or gh run list --branch <branch> --limit 3) passes at the final head, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
        ) % (repo, number, head, verify)
        return _write_issue_scan_spec(_with_preamble(text, 'fullstack-dev'))


class BabysitStartResult(int):
    """A start exit code that also carries the failing command's last stderr line and dispatch id."""

    def __new__(cls, code, reason='', dispatch_id=''):
        self = super().__new__(cls, code)
        self.reason = reason
        self.dispatch_id = dispatch_id or ''
        return self


BABYSIT_DEFERRED_EXITS = (3, 4)  # worker-startup.sh: usage gate refused, host placement refused


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


def park_notice(kind, target, reason):
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
    )


def build_babysit_command(config, repo, pr_row, kind, agent, model, builder, verdict_tag=''):
    startup, run_id, from_terminal, roots = babysit_settings(config)
    root = roots.get(repo)
    if not startup or not run_id or not from_terminal or not isinstance(root, str) or not root:
        return None
    if not agent or not model:
        return None
    if kind == 'verifier':
        title = 'qa-sdet verify %s#%s' % (repo, pr_row['number'])
        name = 'verify-%s' % pr_row['number']
    else:
        title = 'fullstack-dev fix %s#%s' % (repo, pr_row['number'])
        name = 'fix-%s' % pr_row['number']
    command = [
        'bash', startup,
        '--run', run_id,
        '--spec', build_babysit_spec(repo, pr_row, kind, builder, root, verdict_tag),
        '--title', title,
        '--agent', agent,
        '--model', model,
        '--from', from_terminal,
        '--name', name,
        '--repo', 'path:' + root,
    ]
    branch = pr_row.get('headRefName') or ''
    if branch:
        command += ['--base-branch', pr_base_ref(root, branch)]
    return command


def _default_release_worker(dispatch_id):
    if not dispatch_id:
        return
    try:
        rpc('orchestration', 'worker-release', '--dispatch', dispatch_id)
    except SEND_ERRORS:
        return


def _default_notify_worker(terminal, text):
    if not terminal or not text:
        return
    try:
        rpc('terminal', 'send', '--terminal', terminal, '--text', text, '--enter')
    except SEND_ERRORS as error:
        log_send_failed(terminal, error)


def babysit_pass(
    config, state, workers=None, dry_run=False, persist_state=None,
    pr_fetch=None, start_worker=None, pick=None, owner_check=None,
    release_worker=None, notify_worker=None, now=None, term_times=None,
    closed_fetch=None,
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
    if pick is None:
        pick = pick_role
    if owner_check is None:
        owner_check = pr_owner_only_reason
    if release_worker is None:
        release_worker = _default_release_worker
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
    _startup, run_id, from_terminal, roots = babysit_settings(config)
    cap = babysit_cap(config)
    started = 0
    picks = {}

    def cached_pick(role, avoid_family=None):
        key = (role, avoid_family or '')
        if key not in picks:
            if avoid_family:
                try:
                    picks[key] = pick(role, avoid_family=avoid_family)
                except TypeError:
                    picks[key] = pick(role)
            else:
                picks[key] = pick(role)
        return picks[key]

    rows = []
    for index, repo in enumerate(repos):
        prs = pr_fetch(repo)
        if prs is None:
            log_bits.append('fetch_fail')
            prs = []
        seen = set()

        def note_closed(pr_row, repo_name=repo):
            number = pr_row.get('number')
            if number in seen:
                return
            seen.add(number)
            detail = 'closed'
            if not dry_run and release_closed_verifier(
                pr_row, workers, state, repo_name, release_worker,
            ):
                detail = 'verifier-released'
                if persist_state:
                    persist_state()
            lines.append(_babysit_line(
                repo_name, number or 0, pr_row.get('headRefOid') or '', 'skip', detail,
            ))

        for pr_row in prs:
            if not isinstance(pr_row, dict):
                continue
            if not pr_open_for_dispatch(pr_row):
                if _babysit_closed(pr_row):
                    note_closed(pr_row)
                continue
            seen.add(pr_row.get('number'))
            rows.append((index, pr_row.get('number') or 0, repo, pr_row))
        closed_rows = closed_fetch(repo)
        if isinstance(closed_rows, list):
            for pr_row in closed_rows:
                if isinstance(pr_row, dict) and _babysit_closed(pr_row):
                    note_closed(pr_row)
    rows.sort(key=lambda item: (item[0], item[1]))

    for _index, _number, repo, pr_row in rows:
        number = pr_row.get('number')
        head = pr_row.get('headRefOid') or ''
        if pr_row.get('isDraft'):
            lines.append(_babysit_line(repo, number, head, 'skip', 'draft'))
            continue
        if not re.fullmatch(r'[0-9a-f]{40}', head):
            lines.append(_babysit_line(repo, number, head, 'skip', 'bad-head'))
            continue
        record = babysit_record(state, repo, number)
        if record.get('head') == head and record.get('action'):
            lines.append(_babysit_line(repo, number, head, 'skip', 'already'))
            continue
        owner = owner_check(pr_row)
        if owner == 'error':
            lines.append(_babysit_line(repo, number, head, 'skip', 'owner-check-error'))
            log_bits.append('owner_check_error=%s' % number)
            continue
        if owner:
            lines.append(_babysit_line(repo, number, head, 'report', owner))
            notices.append(Urgent(
                'owner-only path on %s#%s (%s); not dispatched' % (repo, number, owner)
            ))
            log_bits.append('report=%s' % number)
            if not dry_run:
                babysit_mark(state, repo, number, head, 'report')
                if persist_state:
                    persist_state()
            continue
        status = head_checks_status(pr_row)
        root = roots.get(repo) if isinstance(roots.get(repo), str) else ''
        repo_root = root if root and os.path.isdir(root) else None
        needs_fix = rework_needed_at_head(pr_row, None, repo, repo_root=repo_root)
        ready = (
            status == 'SUCCESS'
            and not needs_fix
            and pr_row.get('mergeable') not in ('CONFLICTING', 'UNKNOWN')
            and pr_checks_all_success(pr_row)
            and pr_verdict_valid_for_head(pr_row, repo_root=repo_root)
        )
        if status == 'SUCCESS' and not verdict_posted_for_head(pr_row) and not needs_fix:
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
        if not run_id or not from_terminal or not root:
            lines.append(_babysit_line(repo, number, head, 'skip', 'no-root'))
            log_bits.append('skip_root=%s' % number)
            continue
        if kind == 'verifier' and live_verifier_for_pr(pr_row, workers):
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
        if started >= cap:
            lines.append(_babysit_line(repo, number, head, 'skip', 'cap'))
            log_bits.append('cap')
            count_refused('host_cap')
            continue
        builder = builder_pair(pr_row, workers)
        avoid = builder if kind == 'verifier' else None
        picked = cached_pick(role, _avoid_family(avoid) if avoid else None)
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
            lines.append(_babysit_line(repo, number, head, action, detail))
            started += 1
            continue
        command = build_babysit_command(config, repo, pr_row, kind, agent, model, builder, tag)
        if command is None:
            lines.append(_babysit_line(repo, number, head, 'skip', 'no-root'))
            continue
        started_worker = start_worker(command)
        code, reason = start_result_parts(started_worker)
        if code != 0:
            suffix = ':' + reason if reason else ''
            if code in BABYSIT_DEFERRED_EXITS:
                # The usage gate or host placement said wait. That is not a failed start, so the next pass retries.
                lines.append(_babysit_line(repo, number, head, 'skip', 'start-deferred'))
                log_bits.append('start_deferred=%s%s' % (number, suffix))
                continue
            lines.append(_babysit_line(repo, number, head, 'skip', 'start-failed'))
            log_bits.append('start_fail=%s%s' % (number, suffix))
            if park_failure(state, park_key, reason, config, repo=repo, pr=number, head=head):
                notices.append(park_notice('verifier', '%s#%s' % (repo, number), reason))
            continue
        babysit_mark(state, repo, number, head, action)
        if action == 'verifier':
            remember_started_dispatch(state, started_worker, 'verifier')
            _verifier_head_bucket(state, repo)[str(number)] = head
        started += 1
        count_started()
        lines.append(_babysit_line(repo, number, head, action, detail))
        log_bits.append('%s=%s' % (action, number))
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


def issue_scan_pass(
    config, state, now, workers, list_issues=None, pr_fetch=None,
    gate_check=None, admit_fn=None, start_worker=None,
    inventory_ok=True, persist_state=None, act=None,
    start_detached=None, checks_lock_live=None, workflow_watch_prior=None,
    babysit_repos=None, repo_id_lookup=None,
):
    """Start at most one eligible ready issue and one rework worker per new failing review head."""
    notices = []
    log_bits = []
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
    remote_hosts = []
    if refused:
        log_bits = ['issue_scan_load', 'issue_scan_refused=%s' % reason]
        count_refused(refusal_token(reason))
        remote_hosts = [h for h in (config.get('host_caps') or {}) if not _is_local_coordinator_host(h, config)]
        remote_hosts = [h for h in remote_hosts if h != host]
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
        for pr_row in prs:
            if not pr_open_for_dispatch(pr_row) or pr_row.get('isDraft'):
                continue
            if pr_has_label(pr_row, needs_elon) or pr_has_label(pr_row, needs_redesign):
                continue
            head = pr_row.get('headRefOid') or ''
            if not head:
                continue
            pr_num = pr_row['number']
            needs_head_checks = (
                bool(root)
                and not checks_receipt_at_head(pr_row)
                and not pr_checks_all_success(pr_row)
            )
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
                owner_reason = pr_owner_only_reason(pr_row)
                if owner_reason and owner_reason != 'error':
                    log_bits.append('babysit_owner_skip=%d' % pr_num)
                    continue
            pr_class = classify_open_pr(pr_row, workflow_watch_prior, repo, repo_root=root)
            if pr_class == 'ready':
                if shipped.get(head):
                    continue
                shipped[head] = True
                if persist_state:
                    persist_state()
                command = build_ship_command(repo, pr_row)
                if start_worker(command) == 0:
                    notices.append('ship %s #%d %s' % (repo, pr_num, head[:8]))
                    log_bits.append('ship_start=%s' % head[:8])
                    count_started()
                else:
                    log_bits.append('ship_fail=%d' % pr_num)
                    count_failed()
                continue
            if pr_class != 'needs_fix':
                continue
            if seen.get(head) or pending.get(head):
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
            if not _issue_scan_has_slot(host, config, admission, extra_starts):
                count_refused('host_cap')
                continue
            command = build_rework_start_command(config, repo, pr_row)
            if command is None:
                log_bits.append('rework_skip=%d' % pr_num)
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
                remember_started_dispatch(state, started_worker, 'rework')
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
                count_started()
                if persist_state:
                    persist_state()
            else:
                pending.pop(head, None)
                if park_failure(state, park_key, reason, config, repo=repo, pr=pr_num, head=head):
                    notices.append(park_notice('rework', '%s#%s' % (repo, pr_num), reason))
                if persist_state:
                    persist_state()
                suffix = ':%s' % reason if reason else ''
                log_bits.append('rework_fail=%d%s' % (pr_num, suffix))

    prune_closed_maps(state, listed, {})

    if refused and not remote_hosts:
        return notices, log_bits

    if list_issues is None:
        list_issues = fetch_ready_issues

    started = state.setdefault('issue_scan_started', {})
    issue_pending = state.setdefault('issue_scan_pending', {})

    def issue_already_claimed(repo, number):
        return (
            number in started.get(repo, [])
            or number in issue_pending.get(repo, [])
        )

    candidates = []
    ready_queue_count = 0
    list_failed = False
    for repo in repos:
        issues = list_issues(repo)
        if issues is None:
            log_bits.append('issue_scan_list_failed')
            list_failed = True
            continue
        ready_queue_count += len(issues)
        for row in issues:
            if not issue_scan_eligible(row):
                continue
            if issue_already_claimed(repo, row['number']):
                continue
            updated = row.get('updatedAt') or ''
            if park_is_active(state, park_id('issue', repo, row['number'], updated), config):
                log_bits.append('issue_parked=%d' % row['number'])
                continue
            candidates.append((repo, row))

    if not candidates and remote_hosts:
        log_bits.append('issue_scan_none')
        return notices, log_bits
    if not candidates:
        queue_count = None if list_failed else ready_queue_count
        sweep_bits = issue_scan_try_backlog_sweep(
            config, state, now, repos, queue_count, host, admission, extra_starts,
            start_worker, persist_state,
        )
        log_bits.extend(sweep_bits)
        if not any(bit.startswith('backlog_sweep_start=') for bit in sweep_bits):
            log_bits.append('issue_scan_none')
        return notices, log_bits

    if not remote_hosts and not _issue_scan_has_slot(host, config, admission, extra_starts):
        count_refused('host_cap')
        return notices, log_bits

    candidates.sort(key=lambda pair: issue_scan_sort_key(pair[1]))
    lookup = repo_id_lookup or default_repo_id_lookup
    for repo, row in candidates:
        placement = None
        if remote_hosts:
            placed = False
            for candidate in remote_hosts:
                receipt = admit_fn(candidate, config, workers)
                if not receipt.get('admitted'):
                    why = re.sub(r'[,;\s]+', ' ', str(receipt.get('reason') or 'unknown')).strip()
                    log_bits.append('issue_scan_refused_%s=%s' % (candidate, why))
                    count_refused(refusal_token(why))
                    continue
                if not _host_maps_repo(config, candidate, repo):
                    log_bits.append('issue_scan_no_repo_%s' % candidate)
                    continue
                repo_id = lookup(candidate, repo)
                if not repo_id:
                    log_bits.append('issue_scan_no_repo_%s' % candidate)
                    continue
                placement = (candidate, repo_id)
                log_bits.append('issue_scan_placed=%s' % candidate)
                placed = True
                break
            if not placed:
                return notices, log_bits
        command = build_issue_start_command(config, repo, row, placement)
        if command is None:
            log_bits.append('issue_scan_skip')
            return notices, log_bits
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
            if not already:
                act([
                    'gh', 'issue', 'edit', issue_key, '--repo', repo,
                    '--add-label', 'needs-triage', '--remove-label', 'ready-for-agent',
                ])
                act(['gh', 'issue', 'comment', issue_key, '--repo', repo, '--body', comment_body])
                lint_state[issue_key] = body_head
                if persist_state:
                    persist_state()
            log_bits.append('issue_needs_triage=%d' % row['number'])
            continue
        issue_pending.setdefault(repo, []).append(row['number'])
        if persist_state:
            persist_state()
        started_worker = start_worker(command)
        code, reason = start_result_parts(started_worker)
        pending_list = issue_pending.setdefault(repo, [])
        if row['number'] in pending_list:
            pending_list.remove(row['number'])
        suffix = ':%s' % reason if reason else ''
        if code in BABYSIT_DEFERRED_EXITS:
            if persist_state:
                persist_state()
            log_bits.append('issue_start_deferred=%d%s' % (row['number'], suffix))
            return notices, log_bits
        if code == 0:
            remember_started_dispatch(state, started_worker, 'issue')
            started.setdefault(repo, []).append(row['number'])
            notices.append('issue %s #%d' % (repo, row['number']))
            log_bits.append('issue_start=%d' % row['number'])
            count_started()
            if persist_state:
                persist_state()
        else:
            updated = row.get('updatedAt') or ''
            park_key = park_id('issue', repo, row['number'], updated)
            if park_failure(state, park_key, reason, config, repo=repo, issue=row['number']):
                notices.append(park_notice('issue', '%s#%s' % (repo, row['number']), reason))
            if persist_state:
                persist_state()
            log_bits.append('issue_start_fail=%d%s' % (row['number'], suffix))
        return notices, log_bits
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


def main_red_notices(config, state, now, fetch=None):
    """Tell the coordinator once per run id when the latest Checks run on main is not success."""
    if fetch is None:
        fetch = fetch_main_checks_run
    notices = []
    told = state.setdefault('main_red', {})
    for repo in (config.get('pr_watch') or {}).get('repos') or []:
        run = fetch(repo)
        if run is None:
            continue
        run_id = str(run.get('databaseId') or '')
        if not run_id or run.get('conclusion') == 'success':
            told.pop(repo, None)
            continue
        if told.get(repo) != run_id:
            told[repo] = run_id
            notices.append(Urgent(f"{repo}: Checks on main is {run.get('conclusion')}, ship.sh refuses until fixed: {run.get('url')}"))
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


def send_digest(rpc_call, address, sender, body):
    """Address run:<id> or a lead. --from is fleet watch's sender, not a copy of the receiver."""
    command = ['orchestration', 'send', '--to', address]
    if sender:
        command += ['--from', sender]
    command += ['--subject', 'fleet-watch digest', '--body', body]
    rpc_call(*command)


def flush_queue(state, now, rpc_call):
    """One orchestration send per address: at once when urgent, else at most every DIGEST_SECONDS."""
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
            send_digest(rpc_call, address, notice_sender(items), '\n'.join(item['text'] for item in items))
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
                rpc_call('terminal', 'send', '--terminal', term, '--text', line, '--enter')
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
    sender = fleet_watch_sender(runs)
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
    flush_queue(state, now, rpc_call)
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


def _message_outcome(message, payload):
    for source in (message, payload):
        if not isinstance(source, dict):
            continue
        outcome = source.get('outcome')
        if isinstance(outcome, str) and outcome.strip():
            return outcome.strip().lower()
    return ''


def _builder_role(worker):
    title = str(worker.get('_task_title') or worker.get('title') or '').strip()
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


def release_green_successes(messages, workers, config, state, release, pr_of):
    """Release a worker once when worker_done succeeded and its PR checks are green.

    The in-memory row is marked released so this pass stops counting the seat.
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
        if not isinstance(message, dict) or message.get('type') != 'worker_done':
            continue
        payload = _message_payload(message)
        if _message_outcome(message, payload) != 'succeeded':
            continue
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        if not isinstance(dispatch, str) or not dispatch or dispatch in seen:
            continue
        worker = by_dispatch.get(dispatch)
        if worker is None or worker_terminal_released(worker):
            continue
        number = worker_pr_number(worker)
        repo = repo_for_worker(worker, config)
        if not number or not repo:
            continue
        pr_row = pr_of(repo, number)
        if not isinstance(pr_row, dict) or not pr_checks_all_success(pr_row):
            continue
        release(dispatch)
        _mark_worker_released(worker)
        released_ids.append(dispatch)
        seen.add(dispatch)
        done.append(dispatch)
    return done


def bounce_builder_dones(messages, workers, body_of, notify, state, config):
    """Tell a builder its worker_done does not count when the PR body fails the finish gate."""
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
        if not isinstance(message, dict) or message.get('type') != 'worker_done':
            continue
        message_id = message.get('id')
        if not isinstance(message_id, str) or not message_id or message_id in seen:
            continue
        payload = _message_payload(message)
        if _message_outcome(message, payload) in ('failed', 'failure'):
            continue
        dispatch = payload.get('dispatchId') or payload.get('dispatch_id') or ''
        if not isinstance(dispatch, str) or dispatch not in by_dispatch:
            continue
        worker = by_dispatch[dispatch]
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
        reason = gate.finish_block_reason(body)
        if not reason:
            continue
        notify(worker_terminal_handle(worker), 'worker_done bounced: ' + reason)
        bounced.append(message_id)
        seen.add(message_id)
        lines.append('bounce %s#%s %s' % (repo, number, reason))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=False, default=None)
    parser.add_argument('--state', type=Path, required=False)
    parser.add_argument('--admit', type=str, default=None, help='Check host admission under cap')
    parser.add_argument('--admit-local', action='store_true', help='Check coordinator load, memory, and cap admission')
    parser.add_argument('--json', action='store_true', help='Emit JSON output')
    parser.add_argument('--babysit-only', action='store_true', help='Run only the babysit dispatch pass')
    parser.add_argument('--babysit-dry-run', action='store_true', help='List babysit dispatches and start nothing')
    parser.add_argument('--workers-json', type=Path, default=None, help='Worker rows used to read a builder dispatch record')
    args = parser.parse_args()

    if args.admit or args.admit_local:
        if args.config is not None:
            config = json.loads(args.config.read_text()) if args.config.exists() else {}
        else:
            cfg_env = os.environ.get('FLEET_WATCH_CONFIG') or os.path.expanduser('~/.config/fleet-watch/config.json')
            cfg_path = Path(cfg_env)
            config = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        target = args.admit if args.admit else (config.get('local_host') or 'local')
        receipt = admit(target, config)
        print(json.dumps(receipt, indent=2))
        return 0 if receipt.get('admitted') else 1

    if not args.config:
        parser.error('--config is required')
    config = json.loads(args.config.read_text())
    config, adopted = resolve_pass_config(config, args.config)
    if adopted is not None:
        print('fleet-watch: using coordinator config %s' % adopted, file=sys.stderr)
    remember_config_mtime(config, adopted or args.config)

    if not args.state:
        parser.error('--state is required when --admit is not specified')

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
    workers = []
    notices = []
    inventory_ok = True
    try:
        inv = read_orca_inventory(config)
        workers = inv['workers']
        notices = alerts(
            config, state, now,
            inv['messages'], workers, inv['alive'], inv['leads'],
        )
        state.pop('orca_inventory_skip_latched', None)
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
                inv['messages'], workers, fetch_pr_body, _notify_bounce, state, config,
            ):
                print('fleet-watch: ' + line)
        except Exception as error:
            print('fleet-watch: builder bounce skipped: %s' % (repr(error),), file=sys.stderr)
    term_times = {}
    term_branches = {}
    terminal_list_ok = True
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

    if inventory_ok:
        try:
            freed = release_green_successes(
                inv['messages'], workers, config, state, _default_release_worker,
                lambda repo, number: next(
                    (row for row in (fetch_once(repo) or []) if isinstance(row, dict) and row.get('number') == number),
                    None,
                ),
            )
            for dispatch_id in freed:
                print('fleet-watch: released %s' % dispatch_id)
        except Exception as error:
            print('fleet-watch: auto-release skipped: %s' % (repr(error),), file=sys.stderr)

    notices += pr_notices(config, state, now, fetch=fetch_once)
    notices += usage_notices(config)
    workflow_watch_prior = copy.deepcopy(state.get('workflow_watch') or {})
    notices += workflow_notices(config, state, now)
    notices += main_red_notices(config, state, now)
    backup_age = backup_age_seconds(config, now)
    notices += backup_notices(config, state, now)
    heavy_extra, heavy_log = heavy_gate_notices(config, state, now)
    wrap_extra, wrap_log = wrap_up_notices(config, state, now)
    notices += heavy_extra + wrap_extra

    def persist_scan_state():
        save_state(args.state, state)

    babysit_notices, babysit_lines, babysit_log = babysit_pass(
        config, state, workers, persist_state=persist_scan_state,
        now=now, term_times=term_times, closed_fetch=closed_from_pass,
    )
    for line in babysit_lines:
        print(line)
    notices += babysit_notices
    scan_extra, scan_log = issue_scan_pass(
        config, state, now, workers,
        pr_fetch=fetch_once,
        inventory_ok=inventory_ok,
        persist_state=persist_scan_state,
        workflow_watch_prior=workflow_watch_prior,
        babysit_repos=babysit_dispatch_repos(config),
    )
    notices += scan_extra
    notices += usage_gate_notices(state, now)
    stall_extra, stall_log = worker_stall_pass(
        config, state, now, workers, term_times, rpc,
        terminal_list_ok=terminal_list_ok, terminal_branches=term_branches,
        inventory_ok=inventory_ok)
    notices += stall_extra
    notices += coordinator
    notices += drain_notices(config)

    duration = time.time() - pass_start
    parts = []
    if duration > PASS_FAIL_LIMIT:
        parts.append('pass failed: %.1fs' % duration)
    else:
        parts.append('pass ok %.1fs' % duration)
    if not terminal_list_ok:
        parts.append('terminal_list_failed')
    if backup_age is not None:
        parts.append('backup_age_s=%d' % int(backup_age))
        if backup_age > BACKUP_STALE_LOG:
            parts.append('backup_stale')
    if heavy_log:
        parts.extend(heavy_log)
    if wrap_log:
        parts.extend(wrap_log)
    if stall_log:
        parts.append('stall ' + ','.join(stall_log))
    if babysit_log:
        parts.append('babysit ' + ','.join(babysit_log))
    if scan_log:
        parts.append('scan ' + ','.join(scan_log))
    try:
        for repo in babysit_repos(config):
            if repo not in pass_prs and _state_tracks_repo(state, repo):
                pass_prs[repo] = fetch_prs(repo)
        prune_closed_maps(state, pass_prs, {})
        prune_closed_issues(state, fetch_closed_issue_rows)
        deliver_notices(config, state, notices, rpc, pass_start)
        if notices:
            print('fleet-watch: ' + '; '.join(str(notice) for notice in notices))
        save_state(args.state, state)
    finally:
        finish_pass('; '.join(parts))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
