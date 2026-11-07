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
import datetime
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
    command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
    try:
        output = subprocess.run(
            command + list(args) + ['--json'], capture_output=True, text=True, timeout=15, check=False
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        raise OrcaReadError('orca CLI failed') from e

    if output.returncode != 0:
        receipt = _json_object_from_orca_process(output)
        if isinstance(receipt, dict) and _receipt_denies_terminal_show(args, receipt):
            raise TerminalNotFound('terminal_not_found') from subprocess.CalledProcessError(
                output.returncode, command + list(args) + ['--json'], output.stdout, output.stderr
            )
        code = _orca_failed_reply_error_code(receipt) if isinstance(receipt, dict) else None
        err = OrcaReadError(code or 'orca CLI failed')
        err.orca_error_code = code
        raise err from subprocess.CalledProcessError(
            output.returncode, command + list(args) + ['--json'], output.stdout, output.stderr
        )

    try:
        receipt = json.loads(output.stdout)
    except json.JSONDecodeError as e:
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
        status = w.get('dispatchStatus') or w.get('status')
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


def classify_worker(worker):
    """Classifies a worker and determines if it occupies a host slot with evidence.
    Returns: (occupies: bool, classification: dict, has_release_unknown: bool)
    """
    status = worker.get('dispatchStatus') or worker.get('status')
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

    released = bool(
        (status == 'released' and not release_unknown) or
        worker.get('released') is True or
        evidence_dict.get('released') is True or
        projection.get('released') is True or
        evidence_dict.get('release') in (True, 'confirmed')
    )

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


def admit(host, config, workers=None):
    """Evaluate host admission under its configured cap.
    Returns an admission receipt dict. Missing/failed remote inventory and release_unknown never authorize a start.
    """
    cap = config.get('host_caps', {}).get(host, 4)
    if workers is None:
        try:
            workers = fetch_workers(config)
        except Exception as e:
            return {
                'ok': False,
                'admitted': False,
                'host': host,
                'cap': cap,
                'occupied': None,
                'live_count': 0,
                'retained_count': 0,
                'resources': [],
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

    for w in deduped:
        occupies, info, release_unk = classify_worker(w)
        if release_unk:
            has_any_release_unknown = True
        if info.get('host') == host and occupies:
            host_resources.append(info)
            if info.get('category') == 'live':
                live_count += 1
            else:
                retained_count += 1

    occupied_count = len(host_resources)

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
            'reason': 'release_unknown never authorizes another start',
            'receipt': {
                'host': host,
                'admitted': False,
                'status': 'rejected',
                'error': 'release_unknown never authorizes another start'
            }
        }

    admitted = (occupied_count < cap)
    return {
        'ok': True,
        'admitted': admitted,
        'host': host,
        'cap': cap,
        'occupied': occupied_count,
        'live_count': live_count,
        'retained_count': retained_count,
        'resources': host_resources,
        'reason': 'admitted' if admitted else ('host cap exceeded: %s %d/%d' % (host, occupied_count, cap)),
        'receipt': {
            'host': host,
            'admitted': admitted,
            'status': 'admitted' if admitted else 'rejected',
            'cap': cap,
            'occupied': occupied_count,
            'live_count': live_count,
            'retained_count': retained_count
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
                notices.append('failed dispatch ' + dispatch + '; inspect worker-show and provider capacity')
            state['failed'].append(dispatch)

    deduped = deduplicate_workers(workers)
    for worker in deduped:
        occupies, info, _ = classify_worker(worker)
        if occupies:
            host = info['host']
            counts[host] = counts.get(host, 0) + 1

    for host, cap in config.get('host_caps', {}).items():
        if counts.get(host, 0) > cap:
            notices.append('host cap exceeded: %s %d/%d (includes child dispatches)' % (host, counts[host], cap))
    # A lead pane can vanish (terminal_not_found) while its merges silently stop.
    dead = state.setdefault('dead_leads', [])
    for lead in config.get('leads', []):
        handle = lead['terminal']
        if (lead_alive or {}).get(handle, True):
            if handle in dead:
                dead.remove(handle)
        elif handle not in dead:
            notices.append('lead pane gone: %s (%s); restart it or move its PRs to a live lead' % (lead['name'], handle))
            dead.append(handle)
    for run in config['runs']:
        key = run['id']
        pending = any(m.get('run_id') == key and not m.get('read') for m in messages)
        if waiter_alive[key] or not pending:
            state.pop(key, None)
            continue
        timer = state.setdefault(key, {'since': now, 'alerted': False})
        if now - timer['since'] >= 600 and not timer['alerted']:
            notices.append('inbox waiter absent for 10 minutes with unacked deliveries: ' + key)
            timer['alerted'] = True
    return notices


def fetch_prs(repo):
    """Recent PRs in one gh call, or None when gh fails."""
    fields = 'number,state,headRefOid,comments,statusCheckRollup,mergeCommit'
    command = ['gh', 'pr', 'list', '--repo', repo, '--state', 'all', '--limit', '50', '--json', fields]
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(output.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def failing(pr):
    """The latest Checks receipt at this head decides, unless a status check failed after it; otherwise any failed status check."""
    for comment in reversed(pr['comments']):
        first = comment['body'].split('\n')[0]
        if first.startswith('Checks: ') and 'head=' + pr['headRefOid'] in first:
            if first.startswith('Checks: FAIL'):
                return True
            receipt = comment.get('createdAt') or ''
            return any(check.get('conclusion') == 'FAILURE' and (check.get('completedAt') or '') > receipt
                       for check in pr['statusCheckRollup'])
    return any(check.get('conclusion') == 'FAILURE' for check in pr['statusCheckRollup'])


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
            if first.startswith('Verdict:') and comment['id'] not in verdicts:
                verdicts.append(comment['id'])
                if not baseline:
                    events.append('%s #%d %s' % (repo, number, first))
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
        'orchestration', 'worker-start', '--run', rid, '--task', tid,
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
    r'^## (?:[0-9]+[.)] +)?(?:Acceptance criteria|Done check)\b', re.I | re.M)


def issue_scan_has_acceptance(text):
    return bool(_ISSUE_ACCEPTANCE_RE.search(text or ''))


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
    for comment in reversed(pr.get('comments') or []):
        first = (comment.get('body') or '').split('\n')[0]
        if first.startswith('Checks: ') and 'head=' + head in first:
            return first.startswith('Checks: PASS')
    for check in pr.get('statusCheckRollup') or []:
        if not isinstance(check, dict):
            continue
        ctx = (check.get('context') or check.get('name') or '').lower()
        if 'head-checks' in ctx or ctx == 'checks':
            return check.get('conclusion') == 'SUCCESS'
    return False


def review_failed_at_head(pr):
    head = pr.get('headRefOid') or ''
    for comment in reversed(pr.get('comments') or []):
        first = (comment.get('body') or '').split('\n')[0]
        if 'head=' + head not in first or not first.startswith('Verdict:'):
            continue
        if first.startswith('Verdict: PASS'):
            return False
        if first.startswith('Verdict: FAIL'):
            return True
    saw_failure = False
    for check in pr.get('statusCheckRollup') or []:
        if not isinstance(check, dict):
            continue
        ctx = (check.get('context') or check.get('name') or '').lower()
        if ctx == 'review':
            conclusion = check.get('conclusion')
            if conclusion == 'SUCCESS':
                return False
            if conclusion == 'FAILURE':
                saw_failure = True
    return saw_failure


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


def build_issue_start_command(config, repo, issue_row):
    scan = config['issue_scan']
    root = _issue_scan_repo_root(config, repo)
    if not root:
        return None
    spec_path = _write_issue_scan_spec(
        '# %s#%d\n\n%s' % (repo, issue_row['number'], issue_row.get('body') or issue_row.get('title') or ''))
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
    spec_path = _write_issue_scan_spec('Rework after review failure on %s PR #%d head %s' % (repo, pr_row['number'], head))
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
    return [part for part in command if part]


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
    inventory_ok=True, persist_state=None,
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
    rework_heads = state.setdefault('issue_scan_rework', {})
    rework_pending = state.setdefault('issue_scan_rework_pending', {})

    for repo in pr_repos:
        prs = pr_fetch(repo)
        if prs is None:
            continue
        seen = rework_heads.setdefault(repo, {})
        pending = rework_pending.setdefault(repo, {})
        for pr_row in prs:
            if pr_row.get('state') != 'OPEN':
                continue
            if not checks_pass_at_head(pr_row) or not review_failed_at_head(pr_row):
                continue
            head = pr_row.get('headRefOid') or ''
            if not head or seen.get(head) or pending.get(head):
                continue
            if not _issue_scan_has_slot(host, config, admission, extra_starts):
                continue
            command = build_rework_start_command(config, repo, pr_row)
            if command is None:
                log_bits.append('rework_skip=%d' % pr_row['number'])
                continue
            pending[head] = True
            if persist_state:
                persist_state()
            if start_worker(command) == 0:
                seen[head] = True
                pending.pop(head, None)
                extra_starts += 1
                notices.append('rework %s #%d %s' % (repo, pr_row['number'], head[:8]))
                log_bits.append('rework_start=%s' % head[:8])
                if persist_state:
                    persist_state()
            else:
                pending.pop(head, None)
                if persist_state:
                    persist_state()
                log_bits.append('rework_fail=%d' % pr_row['number'])

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
    for repo in repos:
        issues = list_issues(repo)
        if issues is None:
            log_bits.append('issue_scan_list_failed')
            continue
        for row in issues:
            if not issue_scan_eligible(row):
                continue
            if issue_already_claimed(repo, row['number']):
                continue
            candidates.append((repo, row))

    if not candidates:
        if not log_bits:
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
    workflows = watch.get('workflows')
    if not workflows:
        return []
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
            if run['workflowName'] not in workflows or now - created > RUN_WINDOW:
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
            if act(['gh', 'issue', 'create', '--repo', repo, '--title', title, '--body', run['url']]) == 0:
                done[key] = 'issue'
                notices.append(f'{repo}: {title}')
            else:
                notices.append(f'{repo}: {title}, issue not opened')
        handled[repo] = done
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


def deliver_notices(config, state, new_lines, rpc_call=rpc):
    """Send each line to every run terminal that has not got it. A line is dropped once delivered or after 20 passes."""
    delivery = state.setdefault('notice_delivery', {})
    terminals = [run['terminal'] for run in config['runs']]
    failed = set()
    for line in dict.fromkeys(list(new_lines) + list(delivery)):
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
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=False)
    parser.add_argument('--admit', type=str, default=None, help='Check host admission under cap')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())

    if args.admit:
        receipt = admit(args.admit, config)
        print(json.dumps(receipt, indent=2))
        return 0 if receipt.get('admitted') else 1

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
    notices += workflow_notices(config, state, now)
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
    )
    notices += scan_extra
    stall_extra, stall_log = worker_stall_pass(
        config, state, now, workers, term_times, rpc,
        terminal_list_ok=terminal_list_ok, terminal_branches=term_branches,
        inventory_ok=inventory_ok)
    notices += stall_extra
    notices += coordinator

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

    lines = []
    if notices:
        lines.append('fleet-watch: ' + '; '.join(notices))
    deliver_notices(config, state, lines, rpc)
    if notices:
        print(lines[0])
    save_state(args.state, state)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
