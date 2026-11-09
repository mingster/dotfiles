#!/usr/bin/env python3
"""One bounded watchdog pass; schedule every five minutes outside the coordinator.
Config: --config FILE containing runs [{id, terminal, waiter_pattern}], optional
host_caps {host: count}, leads [{name, terminal}] whose panes must stay alive,
pr_watch {repos: [owner/name], stuck_minutes} for PR merge, Verdict and stuck notices,
optional worker_stall {label_repo} for 30 minute idle restarts, optional backup {stamp, issue_repo},
optional heavy_gate {hosts, slot_roots, issue_repo} wait-log median and held-slot checks,
optional wrap_up {hosts, issue_repo}
round-log freshness, optional issue_scan (disabled unless enabled) to start ready issues and rework after review failure;
--state FILE persists missing-waiter timers and alerts.
Counts every active Dispatch, including descendants. May restart a stalled worker once per task.
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
NOTICE_PASS_LIMIT = 20
DIGEST_SECONDS = 600
ORCA_SKIP_NOTICE = 'Orca could not be read; skipping worker inbox alerts this run'


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
    return w.get('terminalState') == 'released' or w.get('stage') == 'released'


def worker_freed_by_terminal_exit(worker):
    """Worker-list row with exited liveness and a released terminal does not retain a slot.

    Full rows place liveness under projection.liveness.verdict; flat rows may set top-level liveness.
    """
    w = worker or {}
    return worker_liveness_verdict(w) == 'exited' and w.get('terminalState') == 'released'


def classify_worker(worker):
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

    if release_unknown:
        info = {
            'dispatchId': dispatch_id,
            'host': host,
            'category': 'retained',
            'role': role,
            'evidence': {'status': status, 'pushed': pushed, 'released': False, 'release_unknown': True}
        }
        return True, info, True

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

    if status == 'completed':
        if pushed and released:
            info = {
                'dispatchId': dispatch_id,
                'host': host,
                'category': 'freed',
                'role': role,
                'evidence': {'status': status, 'pushed': True, 'released': True}
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
        for result in list_pages('orchestration', 'worker-list', '--run', run_id, '--include-remote', '--full'):
            for w in result.get('workers', []):
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


def _first_admitted_overflow_host(host, config, workers):
    local_host = (config or {}).get('local_host')
    local_names = {'local', host}
    if isinstance(local_host, str) and local_host.strip():
        local_names.add(local_host.strip())
    for candidate in ((config or {}).get('host_caps') or {}):
        if candidate in local_names:
            continue
        remote_receipt = admit(candidate, config, workers=workers)
        if remote_receipt.get('admitted'):
            return candidate
    return None


def admit(host, config, workers=None):
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
    host_resources = []
    has_any_release_unknown = False
    live_count = 0
    retained_count = 0
    local_names = {'local', host}
    if is_local and isinstance(local_host, str) and local_host.strip():
        local_names.add(local_host.strip())

    for w in deduped:
        occupies, info, release_unk = classify_worker(w)
        if release_unk:
            has_any_release_unknown = True
        w_host = info.get('host')
        matches_host = (w_host in local_names) if is_local else (w_host == host)
        if matches_host and occupies:
            host_resources.append(info)
            if info.get('category') == 'live':
                live_count += 1
            else:
                retained_count += 1

    occupied_count = len(host_resources)

    if load_breached or mem_breached:
        overflow_host = _first_admitted_overflow_host(host, config, deduped)
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
    overflow_host = None if admitted else (_first_admitted_overflow_host(host, config, deduped) if is_local else None)
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
            if not baseline:
                notices.append(Urgent('failed dispatch ' + dispatch + '; inspect worker-show and provider capacity'))
            state['failed'].append(dispatch)

    deduped = deduplicate_workers(workers)
    for worker in deduped:
        occupies, info, _ = classify_worker(worker)
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


def fetch_prs(repo):
    """Recent PRs in one gh call, or None when gh fails."""
    fields = (
        'number,state,isDraft,headRefOid,headRefName,baseRefOid,mergeable,mergeStateStatus,'
        'reviewDecision,files,labels,comments,statusCheckRollup,mergeCommit'
    )
    command = ['gh', 'pr', 'list', '--repo', repo, '--state', 'all', '--limit', '50', '--json', fields]
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


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
    wid = (resource.get('worktreeId') or w.get('worktreeId')
           or (w.get('projection') or {}).get('workspace', {}).get('id'))
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


def worker_stall_pass(config, state, now, workers, term_times, rpc_call, act=None, terminal_list_ok=True,
                     terminal_branches=None, inventory_ok=True):
    """Detect no terminal output for stall idle limit; restart once per task; then label needs-elon."""
    if act is None:
        act = run_gh
    cfg = config.get('worker_stall') or {}
    label_repo = cfg.get('label_repo')
    if not label_repo:
        return [], []
    stall_limit = stall_idle_limit_seconds(config)
    label_name = cfg.get('needs_elon_label', 'needs-elon')
    cooldown = int(cfg.get('label_cooldown_seconds', 120))
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
    issue_keys = state.setdefault('stall_issue_keys', [])
    # One-restart state is keyed by task id only; it expires by age, never by worker-list membership.
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

    branches = terminal_branches or {}
    local_handles = set(term_times.keys())

    for skey, pend in list(pending.items()):
        if not isinstance(pend, dict) or pend.get('started'):
            continue
        row = pend.get('row_snapshot')
        old_dispatch = pend.get('old_dispatch')
        if not row or not old_dispatch:
            pending.pop(skey, None)
            continue
        run_for_start = run_id_for_stall_restart(
            row, pend.get('stall_restart_run_id') or '') or default_list_run_id(config)
        start_args = worker_stall_restart_start_args(row, old_dispatch, run_for_start, config)
        if not start_args:
            line = stall_restart_start_blocked_log(old_dispatch, config, row, run_for_start)
            if line:
                log_bits.append(line)
            continue
        try:
            rpc_call(*start_args)
            st = bucket.setdefault(skey, {'restarted': False, 'labeled': False, 'restart_at': None})
            st['restarted'] = True
            st['restart_at'] = now
            pending.pop(skey, None)
            log_bits.append('stall_restart=%s' % old_dispatch)
        except SEND_ERRORS as exc:
            log_bits.append('stall_restart_retry=%s:%s' % (old_dispatch, orchestration_failure_log_code(exc)))

    for w in workers:
        did = w.get('dispatchId')
        skey = stall_state_key(w)
        if not did or not skey:
            continue
        if not worker_row_is_live(w):
            continue

        host_id = worker_execution_host_id(w)
        term = worker_terminal_handle(w)
        if not term:
            continue

        if host_id != 'local':
            last_raw = term_times.get(term)
            last_s = _normalize_terminal_time_ms(last_raw)
            if worker_should_restart_for_terminal_stall(w, now, last_s, stall_limit):
                log_bits.append('remote_stall_unknown=%s' % did)
            continue

        if term not in local_handles:
            continue

        last_raw = term_times.get(term)
        last_s = _normalize_terminal_time_ms(last_raw)
        st = bucket.setdefault(skey, {'restarted': False, 'labeled': False, 'restart_at': None})

        is_stalled = worker_should_restart_for_terminal_stall(w, now, last_s, stall_limit)
        if not is_stalled:
            # Replacement recovered (fresh output) or agent is live.
            # One-restart records expire by age only (see loop above); keep restarted=True until TTL.
            if st.get('restarted'):
                pending.pop(skey, None)
                continue
            bucket.pop(skey, None)
            pending.pop(skey, None)
            continue

        if not st['restarted']:
            run_for_start = run_id_for_stall_restart(w, '') or default_list_run_id(config)
            start_args = worker_stall_restart_start_args(w, did, run_for_start, config)
            if start_args:
                try:
                    rpc_call('orchestration', 'worker-stop', '--dispatch', did)
                    state.setdefault('stall_stopped', {})[worker_task_id(w) or skey] = did
                    try:
                        rpc_call(*start_args)
                        st['restarted'] = True
                        st['restart_at'] = now
                        log_bits.append('stall_restart=%s' % did)
                        pending.pop(skey, None)
                    except SEND_ERRORS as exc:
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
                        }
                        st['restarted'] = False
                        log_bits.append('stall_stop_start_retry_next=%s:%s' % (did, orchestration_failure_log_code(exc)))
                except SEND_ERRORS as exc:
                    log_bits.append('stall_restart_fail=%s:%s' % (did, orchestration_failure_log_code(exc)))
                    title = 'Fleet-watch: restart failed for dispatch %s' % did
                    if title not in issue_keys:
                        if act(['gh', 'issue', 'create', '--repo', label_repo, '--title', title,
                                '--body', 'Fleet-watch could not restart this dispatch; inspect Orca and the worker terminal.']) == 0:
                            issue_keys.append(title)
                            notices.append(title)
                        else:
                            notices.append(title + ', issue not opened')
            else:
                line = stall_restart_start_blocked_log(did, config, w, run_for_start)
                if line.startswith('stall_no_sender_terminal='):
                    st['restarted'] = False
                else:
                    st['restarted'] = True
                    st['restart_at'] = now
                if line:
                    log_bits.append(line)
            continue

        if st.get('labeled'):
            continue
        if now - st.get('restart_at', 0) < cooldown:
            continue

        pr_num, pr_status = resolve_pr_number_for_worker(w, label_repo, act, branch_hint=branches.get(term, ''))
        if pr_status == 'lookup_failed':
            log_bits.append('stall_pr_lookup_failed=%s' % did)
            continue
        if pr_num:
            code = act(['gh', 'pr', 'edit', str(pr_num), '--repo', label_repo, '--add-label', label_name])
            if code == 0:
                st['labeled'] = True
                log_bits.append('stall_label_pr=%s:%s' % (did, pr_num))
            else:
                notices.append('needs-elon label failed for PR %s' % pr_num)
        else:
            title = 'Fleet-watch: stalled worker dispatch %s (no PR to label)' % did
            code = 1
            if title not in issue_keys:
                code = act(['gh', 'issue', 'create', '--repo', label_repo, '--title', title,
                            '--body', 'Dispatch is stalled with no linked PR number in worker-list; assign or label manually.'])
                if code == 0:
                    issue_keys.append(title)
            if code == 0:
                st['labeled'] = True
                log_bits.append('stall_no_pr=%s' % did)
                notices.append(title)
            else:
                notices.append(title + ', issue not opened')

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
    if (pr_row.get('mergeable') not in ('CONFLICTING', 'UNKNOWN')
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
        return 0
    except OSError:
        return 1


def review_failed_at_head(pr):
    return rs.review_failed_at_head(pr)


def fetch_ready_issues(repo, run=subprocess.run):
    command = [
        'gh', 'issue', 'list', '--repo', repo, '--label', 'ready-for-agent', '--state', 'open',
        '--limit', '100', '--json', 'number,title,body,labels,comments,createdAt,blockedBy',
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


def build_issue_start_command(config, repo, issue_row):
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    spec_path = _write_issue_scan_spec(
        'Refs %s#%d\n\n%s\n\n'
        '## Verify\n'
        'Run the tests the change touches and show the Done condition.\n\n'
        '## Finish\n'
        'Self-review, push, open the PR, then worker_done.\n'
        % (repo, issue_row['number'], issue_scan_brief_text(issue_row).rstrip()))
    role = scan.get('role') or 'builder'
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
    return [part for part in command if part]


def build_rework_start_command(config, repo, pr_row):
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    head = pr_row.get('headRefOid') or ''
    excerpt = rework_failure_excerpt(pr_row)
    spec_path = _write_issue_scan_spec(
        'Refs %s#%d\n'
        'Rework %s PR #%d head %s\n\n'
        '## Acceptance\n'
        '- [ ] the failing check passes\n\n'
        '%s\n\n'
        '## Out of scope\n'
        'files outside this PR\n\n'
        '## Verify\n'
        'the failing check:\n%s\n\n'
        '## Finish\n'
        'Self-review, then worker_done.\n'
        % (repo, pr_row['number'], repo, pr_row['number'], head, excerpt, excerpt))
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
        command += ['--base-branch', branch]
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
        'Role: %s (read .claude/agents/%s.md). Read-only team-grill-backlog sweep; no code.\n'
        % (role, role)
    )
    spec_path = _write_issue_scan_spec(spec)
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
        else:
            log_bits.append('backlog_sweep_fail=%s' % role)
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


def default_issue_scan_gate(config, run=subprocess.run):
    scan = config.get('issue_scan') or {}
    agent = scan.get('agent') or 'cursor'
    command = [sys.executable, str(Path(__file__).with_name('usage-gate.py')), 'check', '--provider', agent]
    model = scan.get('model')
    if model:
        command += ['--model', model]
    try:
        return run(command, capture_output=True, timeout=60).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def default_issue_scan_start(command, run=subprocess.run):
    try:
        return run(command, capture_output=True, text=True, timeout=180).returncode
    except (subprocess.SubprocessError, OSError):
        return 1


def _issue_scan_has_slot(host, config, admission, extra_starts):
    cap = config.get('host_caps', {}).get(host, 4)
    occupied = admission.get('occupied')
    if occupied is None:
        occupied = 0
    return extra_starts + occupied < cap


def issue_scan_pass(
    config, state, now, workers, list_issues=None, pr_fetch=None,
    gate_check=None, admit_fn=None, start_worker=None,
    inventory_ok=True, persist_state=None, act=None,
    start_detached=None, checks_lock_live=None, workflow_watch_prior=None,
):
    """Start at most one eligible ready issue and one rework worker per new failing review head."""
    notices = []
    log_bits = []
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
    if not gate_check(config):
        return notices, ['issue_scan_gate']
    admission = admit_fn(host, config, workers)
    if not admission.get('admitted'):
        return notices, ['issue_scan_load']

    extra_starts = 0
    repos = scan.get('repos') or []
    if pr_fetch is None:
        pr_fetch = fetch_prs
    pr_repos = scan.get('pr_repos') or repos
    needs_elon = (config.get('worker_stall') or {}).get('needs_elon_label', 'needs-elon')
    ship_heads = state.setdefault('issue_scan_ship', {})
    rework_heads = state.setdefault('issue_scan_rework', {})
    rework_pending = state.setdefault('issue_scan_rework_pending', {})
    rework_rounds = state.setdefault('issue_scan_rework_rounds', {})
    rework_escalated = state.setdefault('issue_scan_rework_escalated', {})
    if workflow_watch_prior is None:
        workflow_watch_prior = state.get('workflow_watch') or {}

    for repo in pr_repos:
        prs = pr_fetch(repo)
        if prs is None:
            continue
        root = _issue_scan_repo_root(config, repo)
        shipped = ship_heads.setdefault(repo, {})
        seen = rework_heads.setdefault(repo, {})
        pending = rework_pending.setdefault(repo, {})
        rounds = rework_rounds.setdefault(repo, {})
        escalated = rework_escalated.setdefault(repo, {})
        for pr_row in prs:
            if pr_row.get('state') != 'OPEN' or pr_row.get('isDraft'):
                continue
            if pr_has_label(pr_row, needs_elon):
                continue
            head = pr_row.get('headRefOid') or ''
            if not head:
                continue
            pr_num = pr_row['number']
            if root and not checks_receipt_at_head(pr_row) and not pr_checks_all_success(pr_row):
                if not head_checks_lock_live(root, lock_live=checks_lock_live):
                    command = build_head_checks_command(config, repo, pr_row)
                    if command and start_detached(command) == 0:
                        log_bits.append('head_checks_start=%s' % head[:8])
                        if persist_state:
                            persist_state()
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
                else:
                    log_bits.append('ship_fail=%d' % pr_num)
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
                if act(['gh', 'pr', 'edit', str(pr_num), '--repo', repo, '--add-label', needs_elon]) == 0:
                    escalated[pr_key] = True
                    notices.append(Urgent('%s #%d rework cap reached; needs-elon' % (repo, pr_num)))
                    log_bits.append('rework_cap=%d' % pr_num)
                    if persist_state:
                        persist_state()
                else:
                    log_bits.append('rework_cap_label_fail=%d' % pr_num)
                continue
            if not _issue_scan_has_slot(host, config, admission, extra_starts):
                continue
            command = build_rework_start_command(config, repo, pr_row)
            if command is None:
                log_bits.append('rework_skip=%d' % pr_num)
                continue
            pending[head] = True
            if persist_state:
                persist_state()
            if start_worker(command) == 0:
                seen[head] = True
                pending.pop(head, None)
                rounds[pr_key] = rounds.get(pr_key, 0) + 1
                extra_starts += 1
                notices.append('rework %s #%d %s' % (repo, pr_num, head[:8]))
                log_bits.append('rework_start=%s' % head[:8])
                if persist_state:
                    persist_state()
            else:
                pending.pop(head, None)
                if persist_state:
                    persist_state()
                log_bits.append('rework_fail=%d' % pr_num)

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
            candidates.append((repo, row))

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

    if not _issue_scan_has_slot(host, config, admission, extra_starts):
        return notices, log_bits

    candidates.sort(key=lambda pair: issue_scan_sort_key(pair[1]))
    repo, row = candidates[0]
    command = build_issue_start_command(config, repo, row)
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
            act(['gh', 'issue', 'edit', issue_key, '--repo', repo, '--add-label', 'needs-triage'])
            act(['gh', 'issue', 'comment', issue_key, '--repo', repo, '--body', comment_body])
            lint_state[issue_key] = body_head
            if persist_state:
                persist_state()
        log_bits.append('issue_needs_triage=%d' % row['number'])
        return notices, log_bits
    issue_pending.setdefault(repo, []).append(row['number'])
    if persist_state:
        persist_state()
    if start_worker(command) == 0:
        pending_list = issue_pending.setdefault(repo, [])
        if row['number'] in pending_list:
            pending_list.remove(row['number'])
        started.setdefault(repo, []).append(row['number'])
        notices.append('issue %s #%d' % (repo, row['number']))
        log_bits.append('issue_start=%d' % row['number'])
        if persist_state:
            persist_state()
    else:
        pending_list = issue_pending.setdefault(repo, [])
        if row['number'] in pending_list:
            pending_list.remove(row['number'])
        if persist_state:
            persist_state()
        log_bits.append('issue_start_fail=%d' % row['number'])
    return notices, log_bits


def workflow_notices(config, state, now, fetch=None, act=None):
    """Rerun a failed workflow once, then open one issue. A repo whose fetch failed keeps its state."""
    if fetch is None:
        fetch = fetch_failed_runs
    if act is None:
        act = run_gh
    watch = config.get('pr_watch') or {}
    if not watch.get('repos'):
        return []
    workflows = watch.get('workflows') or []
    workflow_filter = set(workflows) if workflows else None
    stall_cfg = config.get('worker_stall') or {}
    needs_elon = stall_cfg.get('needs_elon_label', 'needs-elon')
    notices = []
    handled = state.setdefault('workflow_watch', {})
    for repo in watch['repos']:
        runs = fetch(repo)
        if runs is None:
            continue
        old = handled.get(repo, {})
        done = {}
        for run in runs:
            created = calendar.timegm(time.strptime(run['createdAt'], '%Y-%m-%dT%H:%M:%SZ'))
            if workflow_filter is not None and run['workflowName'] not in workflow_filter:
                continue
            if now - created > RUN_WINDOW:
                continue
            key = str(run['databaseId'])
            step = old.get(key)
            if step == 'issue' or (step == 'rerun' and run['attempt'] < 2):
                done[key] = step
                continue
            if run['attempt'] < 2 and act(['gh', 'run', 'rerun', key, '--repo', repo, '--failed']) == 0:
                done[key] = 'rerun'
                continue
            title = f"{run['workflowName']} failed twice on {run['headSha'][:8]}"
            issue_cmd = ['gh', 'issue', 'create', '--repo', repo, '--title', title,
                         '--body', run['url'], '--label', needs_elon]
            if act(issue_cmd) == 0:
                done[key] = 'issue'
                notices.append(Urgent(f'{repo}: {title}'))
            else:
                notices.append(f'{repo}: {title}, issue not opened')
        handled[repo] = done
    return notices


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


def queue_notice(queue, term, text, urgent):
    items = queue.setdefault(term, [])
    for item in items:
        if item['text'] == text:
            item['urgent'] = item['urgent'] or urgent
            return
    items.append({'text': text, 'urgent': urgent, 'passes': 0})


def flush_queue(state, now, rpc_call):
    """One orchestration send per terminal: at once when urgent, else at most every DIGEST_SECONDS."""
    queue = state.setdefault('notice_queue', {})
    sent_at = state.setdefault('notice_sent_at', {})
    for term in list(queue):
        items = queue[term]
        if not items:
            del queue[term]
            continue
        if not any(item['urgent'] for item in items) and term in sent_at and now - sent_at[term] < DIGEST_SECONDS:
            continue
        try:
            rpc_call(
                'orchestration', 'send', '--to', term,
                '--subject', 'fleet-watch digest',
                '--body', '\n'.join(item['text'] for item in items),
            )
        except SEND_ERRORS as error:
            print('fleet-watch: send failed for %s: %s' % (term, (getattr(error, 'stderr', None) or '').strip() or repr(error)), file=sys.stderr)
            kept = []
            for item in items:
                item['passes'] += 1
                if item['passes'] >= NOTICE_PASS_LIMIT:
                    print('fleet-watch: giving up notice %r after %d passes, missing %s' % (item['text'], item['passes'], term), file=sys.stderr)
                else:
                    kept.append(item)
            queue[term] = kept
            continue
        sent_at[term] = now
        del queue[term]


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


def deliver_typed_notices(typed_runs, state, new_notices, rpc_call):
    """Runs with ``typed``: true receive notices via terminal send (legacy path)."""
    if not typed_runs or not new_notices:
        return
    delivery = state.setdefault('typed_notice_delivery', {})
    terminals = [run['terminal'] for run in typed_runs]
    texts = [str(notice) for notice in new_notices]
    failed = set()
    for line in dict.fromkeys(texts + list(delivery)):
        entry = delivery.setdefault(line, {'sent': [], 'passes': 0})
        for term in terminals:
            if term in entry['sent'] or term in failed:
                continue
            try:
                rpc_call('terminal', 'send', '--terminal', term, '--text', line, '--enter')
                entry['sent'].append(term)
            except SEND_ERRORS as error:
                failed.add(term)
                print('fleet-watch: terminal send failed for %s: %s' % (term, (getattr(error, 'stderr', None) or '').strip() or repr(error)), file=sys.stderr)
        entry['passes'] += 1
        missing = [term for term in terminals if term not in entry['sent']]
        if missing and entry['passes'] >= NOTICE_PASS_LIMIT:
            print('fleet-watch: giving up notice %r after %d passes, missing %s' % (line, entry['passes'], ', '.join(missing)), file=sys.stderr)
        if not missing or entry['passes'] >= NOTICE_PASS_LIMIT:
            del delivery[line]


def deliver_notices(config, state, new_notices, rpc_call=rpc, now=None, owner_of=owning_lead):
    """Queue notices per terminal and send what is due. Typed runs still get terminal send."""
    now = time.time() if now is None else now
    runs = config.get('runs', [])
    digest_terms = [run['terminal'] for run in runs if not run.get('typed')]
    typed_runs = [run for run in runs if run.get('typed')]
    queue = state.setdefault('notice_queue', {})
    for notice in new_notices:
        targets, urgent = digest_terms, isinstance(notice, Urgent)
        if isinstance(notice, Verdict):
            lead = owner_of(notice.author)
            if lead:
                targets, urgent = [lead], True
        text = str(notice)
        for term in targets:
            queue_notice(queue, term, text, urgent)
    flush_queue(state, now, rpc_call)
    deliver_typed_notices(typed_runs, state, new_notices, rpc_call)


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=False, default=None)
    parser.add_argument('--state', type=Path, required=False)
    parser.add_argument('--admit', type=str, default=None, help='Check host admission under cap')
    parser.add_argument('--admit-local', action='store_true', help='Check coordinator load, memory, and cap admission')
    parser.add_argument('--json', action='store_true', help='Emit JSON output')
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

    if not args.state:
        parser.error('--state is required when --admit is not specified')

    state = json.loads(args.state.read_text()) if args.state.exists() else {}
    coordinator, done = coordinator_stage(config, state, args.state)
    if done:
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
    term_times = {}
    term_branches = {}
    terminal_list_ok = True
    try:
        term_out = rpc('terminal', 'list', '--json')
        term_times = terminal_last_output_map(term_out)
        term_branches = terminal_branch_map(term_out)
    except SEND_ERRORS:
        terminal_list_ok = False
    notices += pr_notices(config, state, now)
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

    scan_extra, scan_log = issue_scan_pass(
        config, state, now, workers,
        inventory_ok=inventory_ok,
        persist_state=persist_scan_state,
        workflow_watch_prior=workflow_watch_prior,
    )
    notices += scan_extra
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
    if scan_log:
        parts.append('scan ' + ','.join(scan_log))
    log_fleet_watch('; '.join(parts))

    deliver_notices(config, state, notices, rpc, pass_start)
    if notices:
        print('fleet-watch: ' + '; '.join(str(notice) for notice in notices))
    save_state(args.state, state)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
