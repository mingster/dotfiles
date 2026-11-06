#!/usr/bin/env python3
"""One bounded watchdog pass; schedule every minute outside the coordinator.
Config: --config FILE containing runs [{id, terminal, waiter_pattern}], optional
host_caps {host: count}, leads [{name, terminal}] whose panes must stay alive,
pr_watch {repos: [owner/name], stuck_minutes} for PR merge, Verdict and stuck notices,
optional worker_stall {label_repo} for 30 minute idle restarts, optional backup {stamp, issue_repo};
--state FILE persists missing-waiter timers and alerts.
Counts every active Dispatch, including descendants. May restart a stalled worker once per dispatch.
"""
import argparse
import calendar
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time


SEND_ERRORS = (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError, OSError, ValueError, KeyError)
NOTICE_PASS_LIMIT = 20


def rpc(*args):
    command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
    output = subprocess.run(command + list(args) + ['--json'], capture_output=True, text=True, timeout=15, check=True)
    receipt = json.loads(output.stdout)
    if receipt.get('ok') is False:
        raise RuntimeError('Orca refused inventory')
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
        host = ((w.get('projection') or {}).get('host') or {}).get('id', 'local')

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
    host = (projection.get('host') or {}).get('id', 'local')
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
        yield result
        if 'page' in result:
            if result['page']['hasMore'] not in (True, False):
                raise ValueError('bad page')
            cursor = result['page'].get('nextCursor') if result['page']['hasMore'] else None
            if cursor is None and result['page']['hasMore']:
                raise ValueError('bad cursor')
        else:
            cursor = result.get('nextCursor')
        if cursor is None:
            return
        if not isinstance(cursor, str) or not cursor or cursor in seen:
            raise ValueError('bad cursor')
        seen.add(cursor)


def fetch_workers(config):
    """Retrieve and deduplicate workers across runs and pagination.

    worker-list without --run shows only the caller's Run, so without configured runs read every Run.
    """
    run_ids = [run['id'] for run in config.get('runs', [])]
    if not run_ids:
        run_ids = [run['id'] for page in list_pages('orchestration', 'run-list') for run in page['runs']]
    workers = []
    for run_id in run_ids:
        for result in list_pages('orchestration', 'worker-list', '--run', run_id, '--include-remote'):
            workers.extend(result.get('workers', []))
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


def pr_notices(config, state, now, fetch=fetch_prs):
    """A repo whose fetch failed keeps its state, so its events arrive on a later pass."""
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
STALL_IDLE_LIMIT = 30 * 60
PASS_FAIL_LIMIT = 4 * 60


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
    proj = w.get('projection') or {}
    for key in ('githubPullRequestNumber', 'pullRequestNumber', 'prNumber', 'number'):
        n = proj.get(key)
        if isinstance(n, int) and n > 0:
            return n
    return None


def terminal_last_output_map(result):
    """Map terminal handle -> lastOutputAt from terminal list result dict."""
    terminals = (result or {}).get('terminals') or []
    out = {}
    for t in terminals:
        h = t.get('handle')
        if h:
            out[h] = t.get('lastOutputAt')
    return out


def restart_stalled_dispatch(dispatch_id, rpc_call):
    """Stop once then start with --retry-of."""
    rpc_call('orchestration', 'worker-stop', '--dispatch', dispatch_id)
    rpc_call('orchestration', 'worker-start', '--retry-of', dispatch_id)


def worker_stall_pass(config, state, now, workers, term_times, rpc_call, act=None):
    """Detect no terminal output for STALL_IDLE_LIMIT; restart once; then label needs-elon."""
    if act is None:
        act = run_gh
    cfg = config.get('worker_stall') or {}
    label_repo = cfg.get('label_repo')
    if not label_repo:
        return [], []
    label_name = cfg.get('needs_elon_label', 'needs-elon')
    cooldown = int(cfg.get('label_cooldown_seconds', 120))
    notices = []
    log_bits = []
    bucket = state.setdefault('worker_stall', {})
    issue_keys = state.setdefault('stall_issue_keys', [])
    active = {w.get('dispatchId') for w in workers if w.get('dispatchId')}
    for stale_id in list(bucket.keys()):
        if stale_id not in active:
            bucket.pop(stale_id, None)

    for w in workers:
        did = w.get('dispatchId')
        if not did or not worker_row_is_live(w):
            bucket.pop(did, None)
            continue
        term = worker_terminal_handle(w)
        if not term:
            continue
        last_raw = term_times.get(term)
        last_s = _normalize_terminal_time_ms(last_raw)
        if last_s is None:
            continue
        idle = now - last_s
        if idle < STALL_IDLE_LIMIT:
            bucket.pop(did, None)
            continue

        st = bucket.setdefault(did, {'restarted': False, 'labeled': False})
        pr_num = worker_pr_number(w)

        if not st['restarted']:
            try:
                restart_stalled_dispatch(did, rpc_call)
                st['restarted'] = True
                st['restart_at'] = now
                log_bits.append('stall_restart=%s' % did)
            except SEND_ERRORS as exc:
                st['restarted'] = True
                st['restart_at'] = now
                log_bits.append('stall_restart_fail=%s:%s' % (did, type(exc).__name__))
                title = 'Fleet-watch: restart failed for dispatch %s' % did
                if title not in issue_keys:
                    if act(['gh', 'issue', 'create', '--repo', label_repo, '--title', title,
                            '--body', 'Fleet-watch could not restart this dispatch; inspect Orca and the worker terminal.']) == 0:
                        issue_keys.append(title)
                        notices.append(title)
                    else:
                        notices.append(title + ', issue not opened')
            continue

        if st.get('labeled'):
            continue
        if now - st.get('restart_at', 0) < cooldown:
            continue

        if pr_num:
            code = act(['gh', 'pr', 'edit', str(pr_num), '--repo', label_repo, '--add-label', label_name])
            st['labeled'] = True
            log_bits.append('stall_label_pr=%s:%s' % (did, pr_num))
            if code != 0:
                notices.append('needs-elon label failed for PR %s' % pr_num)
        else:
            st['labeled'] = True
            log_bits.append('stall_no_pr=%s' % did)
            title = 'Fleet-watch: stalled worker dispatch %s (no PR to label)' % did
            if title not in issue_keys:
                if act(['gh', 'issue', 'create', '--repo', label_repo, '--title', title,
                        '--body', 'Dispatch is stalled with no linked PR number in worker-list; assign or label manually.']) == 0:
                    issue_keys.append(title)
                    notices.append(title)
                else:
                    notices.append(title + ', issue not opened')

    return notices, log_bits


def workflow_notices(config, state, now, fetch=fetch_failed_runs, act=None):
    """Rerun a failed workflow once, then open one issue. A repo whose fetch failed keeps its state."""
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


def backup_notices(config, state, now, stamp_time=os.path.getmtime, act=None):
    """Open one issue per outage when the last good backup is over 30 minutes old."""
    if act is None:
        act = run_gh
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
    title = 'agent-state backup has not pushed for 30 minutes'
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
    inbox = rpc('orchestration', 'inbox', '--limit', '5000')
    workers = fetch_workers(config)
    term_times = {}
    try:
        term_times = terminal_last_output_map(rpc('terminal', 'list', '--json'))
    except SEND_ERRORS:
        pass
    # pgrep observes the dedicated waiter process; no process is stopped here.
    alive = {run['id']: subprocess.run(['pgrep', '-f', run['waiter_pattern']], capture_output=True, timeout=5).returncode == 0 for run in config['runs']}
    leads = {}
    for lead in config.get('leads', []):
        try:
            rpc('terminal', 'show', '--terminal', lead['terminal'])
            leads[lead['terminal']] = True
        except (subprocess.CalledProcessError, RuntimeError):
            leads[lead['terminal']] = False
    now = time.time()
    notices = alerts(config, state, now, inbox['messages'], workers, alive, leads)
    notices += pr_notices(config, state, now)
    notices += usage_notices(config)
    notices += workflow_notices(config, state, now)
    backup_age = backup_age_seconds(config, now)
    notices += backup_notices(config, state, now)
    stall_extra, stall_log = worker_stall_pass(config, state, now, workers, term_times, rpc)
    notices += stall_extra
    notices += coordinator

    duration = time.time() - pass_start
    parts = []
    if duration > PASS_FAIL_LIMIT:
        parts.append('pass failed: %.1fs' % duration)
    else:
        parts.append('pass ok %.1fs' % duration)
    if backup_age is not None:
        parts.append('backup_age_s=%d' % int(backup_age))
        if backup_age > BACKUP_STALE_LOG:
            parts.append('backup_stale')
    if stall_log:
        parts.append('stall ' + ','.join(stall_log))
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
