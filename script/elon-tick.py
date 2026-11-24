#!/usr/bin/env python3
"""One coordinator tick (#1790): run every Wake loop check and every check in docs/agents/elon-mistakes.md,
print one numbered ACTION list or `OK nothing to do`. Read only: it starts, releases, labels and edits nothing.

Usage: elon-tick.sh --run <run_id> [--config <fleet-watch json>] [--state <fleet-watch state json>]

Config is the private fleet-watch config (FLEET_WATCH_CONFIG, default ~/.claude/state/fleet-watch-elon.json):
repos from pr_watch.repos, checkouts from repo_roots, target_workers from work_order. State defaults to
FLEET_WATCH_STATE, else the config path with .state.json. GitHub: one `gh pr list` and one `gh issue list` per
repo. A check whose input cannot be read prints a NOT CHECKED action, never OK.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PR_LIMIT = 200
ISSUE_LIMIT = 1000
ASK_SECONDS = 15 * 60
REF_RE = re.compile(r'(?:([\w.-]+/[\w.-]+))?#(\d+)\b')
CLOSING_RE = re.compile(r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\b:?\s+((?:[\w.-]+/[\w.-]+)?#\d+)', re.I)
BLOCKED_LINE_RE = re.compile(r'^\s*(?:[-*]\s+)?blocked by\b:?(?!\s+red gate\b)(.*)$', re.I)
BLOCKED_HEADING_RE = re.compile(r'^#{1,6}\s*blocked by\b:?(.*)$', re.I)
HEADING_RE = re.compile(r'^#{1,6}\s')
WAITING_RE = re.compile(r'^\s*waiting on:\s*(.+?)(?:\s+since\s+(\d{4}-\d{2}-\d{2}))?\s*$', re.I | re.M)
RECEIPT_RE = re.compile(r'^(Review|Verdict):\s+(PASS\+NOTES|PASS|FAIL)\b')


class Unreadable(Exception):
    pass


def run_json(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        raise Unreadable('%s: %s' % (' '.join(cmd[:3]), e)) from e
    if out.returncode != 0:
        raise Unreadable('%s exit %d: %s' % (' '.join(cmd[:3]), out.returncode, out.stderr.strip()[:200]))
    try:
        return json.loads(out.stdout)
    except ValueError as e:
        raise Unreadable('%s: not JSON' % ' '.join(cmd[:3])) from e


def orca(*args):
    reply = run_json(shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca')) + list(args) + ['--json'])
    if not isinstance(reply, dict) or reply.get('ok') is False or not isinstance(reply.get('result'), dict):
        raise Unreadable('orca %s: refused' % ' '.join(args[:2]))
    return reply['result']


def gh_list(kind, repo, fields, limit):
    rows = run_json(['gh', kind, 'list', '-R', repo, '--state', 'open', '--limit', str(limit), '--json', fields])
    if not isinstance(rows, list):
        raise Unreadable('gh %s list %s: not a list' % (kind, repo))
    if len(rows) >= limit:
        raise Unreadable('gh %s list %s: %d rows, list may be cut off' % (kind, repo, limit))
    return rows


# ---- gather ---------------------------------------------------------------------------------------------------

def gather(args, config):
    """Every outside read in one place. Each key holds data, or an Unreadable for a source that failed."""
    snap = {'run': args.run, 'now': time.time(), 'config': config, 'repos': {}}

    def attempt(key, fn):
        try:
            snap[key] = fn()
        except Unreadable as e:
            snap[key] = e

    repos = (config.get('pr_watch') or {}).get('repos') or (config.get('issue_scan') or {}).get('repos') or []
    for repo in repos:
        entry = {}
        try:
            entry['prs'] = gh_list('pr', repo, 'number,title,body,headRefName,isDraft,labels,comments', PR_LIMIT)
        except Unreadable as e:
            entry['prs'] = e
        try:
            entry['issues'] = gh_list('issue', repo, 'number,title,body,labels', ISSUE_LIMIT)
        except Unreadable as e:
            entry['issues'] = e
        snap['repos'][repo] = entry
    attempt('tasks', lambda: tasks(args.run))
    attempt('workers', lambda: workers(args.run))
    attempt('state', lambda: read_json(args.state))
    snap['loop'] = loop_status()
    snap['waiter'] = waiter_alive(args.run)
    attempt('watch', lambda: worker_watch(args.run))
    snap['mail'] = {}
    roots = config.get('repo_roots') or {}
    for repo, entry in snap['repos'].items():
        if isinstance(entry['issues'], Unreadable):
            continue
        for issue in entry['issues']:
            wait = WAITING_RE.search(issue.get('body') or '')
            if wait:
                snap['mail'][(repo, issue['number'])] = mailbox(roots.get(repo), wait.group(1), wait.group(2))
    return snap


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError) as e:
        raise Unreadable('%s: %s' % (path, e)) from e


def tasks(run):
    """Task id -> {title, spec}. Specs only for dispatched tasks (the full list of every task is large)."""
    out = {t['id']: {'title': t.get('title') or '', 'spec': ''}
           for t in orca('orchestration', 'task-list', '--run', run).get('tasks') or [] if t.get('id')}
    for t in orca('orchestration', 'task-list', '--run', run, '--status', 'dispatched', '--full').get('tasks') or []:
        if t.get('id'):
            out.setdefault(t['id'], {'title': t.get('task_title') or '', 'spec': ''})['spec'] = t.get('spec') or ''
    return out


def workers(run):
    """Unreleased worker rows on the coordinator host and every paired host (active and retained terminals)."""
    hosts = [None] + [e.get('name') for e in orca('environment', 'list').get('environments') or [] if e.get('name')]
    rows = []
    for host in hosts:
        for state in ('active', 'retained'):
            cmd = ['orchestration', 'worker-list', '--run', run, '--terminal-state', state, '--limit', '100']
            if host:
                cmd += ['--on', host]
            try:
                result = orca(*cmd)
            except Unreadable:
                if host is None:
                    raise
                rows.append({'_unreadable_host': host})
                break
            for w in result.get('workers') or []:
                if isinstance(w, dict) and w.get('dispatchId'):
                    rows.append(dict(w, _host=host or 'coordinator'))
    return rows


def loop_status():
    cmd = shlex.split(os.environ.get('ELON_TICK_LOOP_STATUS', '')) or ['bash', str(HERE / 'fleet-watch-loop.sh'), '--status']
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return out.returncode == 0


def waiter_alive(run):
    pattern = os.environ.get('ELON_TICK_WAITER_PATTERN') or ('orchestration check --run %s.*--wait' % re.escape(run))
    return subprocess.run(['pgrep', '-f', pattern], capture_output=True, check=False).returncode == 0


def worker_watch(run):
    script = os.environ.get('ELON_TICK_WORKER_WATCH') or str(HERE.parent / '.agents/skills/orca-team/worker-watch.sh')
    out = subprocess.run(['bash', script, run], capture_output=True, text=True, check=False)
    if out.returncode not in (0, 4):
        raise Unreadable('worker-watch.sh exit %d: %s' % (out.returncode, out.stderr.strip()[:200]))
    return [line.split(None, 2) for line in out.stdout.splitlines() if len(line.split(None, 2)) == 3]


def mailbox(root, sender, since):
    script = Path(root or '/nonexistent') / '.claude/bin/support-mailbox.sh'
    if not script.is_file():
        return Unreadable('no mailbox script in the repo checkout')
    cmd = ['bash', str(script), 'search', '--from', sender, '--limit', '10'] + (['--since', since] if since else [])
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if out.returncode != 0 or 'no credential' in out.stderr:
        return Unreadable((out.stderr.strip() or 'exit %d' % out.returncode)[:200])
    return [line for line in out.stdout.splitlines() if line.strip()]


# ---- model ----------------------------------------------------------------------------------------------------

def label_names(row):
    return {l.get('name') for l in row.get('labels') or [] if isinstance(l, dict)}


def worker_live(w):
    if w.get('outcome') not in (None, 'in_progress'):
        return False
    return w.get('terminalState') == 'active' and w.get('liveness') != 'exited'


def worker_numbers(w, task):
    """(repo name or '', numbers) a worker is on: its task title, the Refs and Role lines of its brief, its worktree."""
    text = [task.get('title') or '']
    for line in (task.get('spec') or '').splitlines():
        if re.match(r'^\s*(Refs|Role)\b', line):
            text.append(line)
    nums = {int(n) for _, n in REF_RE.findall('\n'.join(text))}
    nums |= {int(n) for n in re.findall(r'\bPRs?\s+(\d+)\b', '\n'.join(text))}
    ws = str(w.get('workspace') or '')
    base = ws.rstrip('/').rsplit('/', 1)[-1]
    m = re.search(r'(\d+)$', base)
    if m:
        nums.add(int(m.group(1)))
    repo = re.search(r'/workspaces/([^/]+)/', ws)
    return (repo.group(1) if repo else ''), nums


def pr_keys(pr):
    keys = {pr['number']}
    keys |= {int(n) for n in re.findall(r'#(\d+)', ' '.join(CLOSING_RE.findall(pr.get('body') or '')))}
    m = re.search(r'issue-(\d+)', pr.get('headRefName') or '')
    if m:
        keys.add(int(m.group(1)))
    return keys


def owners(repo, pr, workers_rows, task_map, live):
    """Dispatch ids of workers that own this PR (verifiers do not own one)."""
    name = repo.split('/')[-1]
    found = []
    for w in workers_rows:
        if '_unreadable_host' in w or worker_live(w) != live:
            continue
        task = task_map.get(w.get('taskId')) or {}
        if 'qa-sdet' in (task.get('title') or ''):
            continue
        wrepo, nums = worker_numbers(w, task)
        if wrepo and wrepo != name:
            continue
        if nums & pr_keys(pr):
            found.append(w['dispatchId'])
    return found


def blockers(body):
    refs, under = [], False
    for line in (body or '').splitlines():
        heading = BLOCKED_HEADING_RE.match(line)
        if heading:
            under = True
            refs += REF_RE.findall(heading.group(1))
            continue
        if HEADING_RE.match(line):
            under = False
            continue
        m = BLOCKED_LINE_RE.match(line)
        if m:
            refs += REF_RE.findall(m.group(1))
        elif under:
            refs += REF_RE.findall(line)
    return refs


# ---- checks ---------------------------------------------------------------------------------------------------
# Each check takes the snapshot and returns action lines. Ids match docs/agents/elon-mistakes.md.

def not_checked(check, err):
    return ['[%s] NOT CHECKED: %s' % (check, err)]


def open_numbers(snap, repo):
    """Open issue and PR numbers of a repo, or None when either list failed."""
    entry = snap['repos'].get(repo)
    if not entry or isinstance(entry['prs'], Unreadable) or isinstance(entry['issues'], Unreadable):
        return None
    return {p['number'] for p in entry['prs']} | {i['number'] for i in entry['issues']}


def each_pr(snap, check):
    for repo, entry in snap['repos'].items():
        if isinstance(entry['prs'], Unreadable):
            yield repo, None, entry['prs']
            continue
        for pr in entry['prs']:
            yield repo, pr, None


def orca_inputs(snap, check):
    for key in ('workers', 'tasks'):
        if isinstance(snap[key], Unreadable):
            return not_checked(check, snap[key])
    return [('[%s] NOT CHECKED: host %s worker list unreadable' % (check, w['_unreadable_host']))
            for w in snap['workers'] if '_unreadable_host' in w]


def check_m1(snap):
    """M1: every open PR has a live owner worker."""
    out = orca_inputs(snap, 'M1')
    if isinstance(snap['workers'], Unreadable) or isinstance(snap['tasks'], Unreadable):
        return out
    for repo, pr, err in each_pr(snap, 'M1'):
        if err:
            out += not_checked('M1', err)
        elif not owners(repo, pr, snap['workers'], snap['tasks'], live=True):
            out.append('[M1] ORPHAN PR %s#%d (%s): no live owner worker; dispatch a fullstack-dev PR owner'
                       % (repo, pr['number'], pr.get('title', '')[:60]))
    return out


def check_m2(snap):
    """M2: a finished, unreleased worker that owns an open PR is not released before the PR has a new owner."""
    if isinstance(snap['workers'], Unreadable) or isinstance(snap['tasks'], Unreadable):
        return not_checked('M2', snap['workers'] if isinstance(snap['workers'], Unreadable) else snap['tasks'])
    out = []
    for repo, pr, err in each_pr(snap, 'M2'):
        if err:
            out += not_checked('M2', err)
            continue
        for dispatch in owners(repo, pr, snap['workers'], snap['tasks'], live=False):
            out.append('[M2] do not release %s yet: it owns open PR %s#%d; hand the PR to a live owner first'
                       % (dispatch, repo, pr['number']))
    return out


def check_m3(snap):
    """M3: an issue waiting on a vendor (`Waiting on: <sender> since <date>`) gets a mailbox search each tick."""
    out = []
    for (repo, number), mail in sorted(snap['mail'].items()):
        if isinstance(mail, Unreadable):
            out += not_checked('M3', '%s#%d mailbox: %s' % (repo, number, mail))
        elif mail:
            out.append('[M3] %s#%d waits on a vendor and the mailbox has %d match(es): %s; read them and update the issue'
                       % (repo, number, len(mail), ' | '.join(mail[:3])[:300]))
    return out


def check_m4(snap):
    """M4: ready-for-agent issues with an open blocker; blocked issues whose blockers all closed."""
    out = []
    for repo, entry in snap['repos'].items():
        opened = open_numbers(snap, repo)
        if opened is None:
            out += not_checked('M4', '%s issue or PR list unreadable' % repo)
            continue
        for issue in entry['issues']:
            refs = blockers(issue.get('body'))
            local = [int(n) for r, n in refs if not r or r == repo]
            if not local or len(local) != len(refs):
                continue
            labels = label_names(issue)
            still = sorted(n for n in local if n in opened)
            if 'ready-for-agent' in labels and still:
                out.append('[M4] %s#%d is ready-for-agent but blocked by open #%s; relabel it blocked'
                           % (repo, issue['number'], ', #'.join(map(str, still))))
            elif 'blocked' in labels and not still:
                out.append('[M4] %s#%d is labeled blocked but every blocker closed; relabel it ready-for-agent'
                           % (repo, issue['number']))
    return out


def check_m5(snap):
    """M5: each live brief's Refs line and every PR number on its Role line exist and are open."""
    if isinstance(snap['workers'], Unreadable) or isinstance(snap['tasks'], Unreadable):
        return not_checked('M5', snap['workers'] if isinstance(snap['workers'], Unreadable) else snap['tasks'])
    out = []
    for w in snap['workers']:
        if '_unreadable_host' in w or not worker_live(w):
            continue
        spec = (snap['tasks'].get(w.get('taskId')) or {}).get('spec') or ''
        refs = []
        for line in spec.splitlines():
            if re.match(r'^\s*Refs\b', line):
                refs += REF_RE.findall(line)
            elif re.match(r'^\s*Role\b', line):
                refs += REF_RE.findall(line) + [('', n) for n in re.findall(r'\bPRs?\s+(\d+)\b', line)]
        for repo, num in refs:
            pool = [repo] if repo else list(snap['repos'])
            known = [open_numbers(snap, r) for r in pool if r in snap['repos']]
            if not known or any(k is None for k in known):
                continue
            if not any(int(num) in k for k in known):
                out.append('[M5] brief of %s names #%s, which is closed or missing%s; stop it and resend a fixed brief'
                           % (w['dispatchId'], num, ' in ' + repo if repo else ''))
    return out


def check_m6(snap):
    """M6: the inbox waiter (`orchestration check --run <run> --wait`) runs."""
    if snap['waiter']:
        return []
    return ['[M6] no inbox waiter for %s; arm one: orca orchestration check --run %s --wait --timeout-ms 3600000'
            % (snap['run'], snap['run'])]


def check_m7(snap):
    """M7: the newest Review or Verdict line on each open PR; FAIL names the owner to tell."""
    out = []
    workers_ok = not isinstance(snap['workers'], Unreadable) and not isinstance(snap['tasks'], Unreadable)
    for repo, pr, err in each_pr(snap, 'M7'):
        if err:
            out += not_checked('M7', err)
            continue
        latest = None
        for c in pr.get('comments') or []:
            first = (c.get('body') or '').split('\n', 1)[0].strip()
            if RECEIPT_RE.match(first):
                latest = first
        if not latest or RECEIPT_RE.match(latest).group(2) != 'FAIL':
            continue
        who = owners(repo, pr, snap['workers'], snap['tasks'], live=True) if workers_ok else []
        tell = 'send the defect to %s' % ', '.join(who) if who else 'no live owner: dispatch one with the defect'
        out.append('[M7] %s#%d latest receipt is "%s"; %s' % (repo, pr['number'], latest[:80], tell))
    return out


def check_loop(snap):
    """W1: the fleet-watch loop runs."""
    return [] if snap['loop'] else ['[W1] fleet-watch-loop is not running; start it from this terminal (coordinator-operations.md)']


def check_watch(snap):
    """W2: worker-watch.sh flags no stalled, idle or blocked worker."""
    if isinstance(snap['watch'], Unreadable):
        return not_checked('W2', snap['watch'])
    return ['[W2] worker %s is %s; act on it per pstack Orchestrate' % (d, v[:160])
            for d, _, v in snap['watch'] if not v.startswith('OK')]


def check_supply(snap):
    """W3: live workers against work_order.target_workers and the ready-for-agent supply."""
    target = (snap['config'].get('work_order') or {}).get('target_workers')
    if isinstance(snap['workers'], Unreadable):
        return not_checked('W3', snap['workers'])
    live = sum(1 for w in snap['workers'] if '_unreadable_host' not in w and worker_live(w))
    ready = 0
    for repo, entry in snap['repos'].items():
        if isinstance(entry['issues'], Unreadable):
            return not_checked('W3', entry['issues'])
        opened = open_numbers(snap, repo) or set()
        for issue in entry['issues']:
            if 'ready-for-agent' in label_names(issue) and not any(
                    (not r or r == repo) and int(n) in opened for r, n in blockers(issue.get('body'))):
                ready += 1
    if not isinstance(target, int) or live >= target:
        return []
    if ready:
        return ['[W3] %d of %d workers live and %d ready-for-agent issue(s); start up to %d'
                % (live, target, ready, min(ready, target - live))]
    return ['[W3] %d of %d workers live and no ready-for-agent issue; start architect-pm supply' % (live, target)]


def check_queues(snap):
    """W4: needs-triage and ready-for-human issues waiting."""
    out = []
    for repo, entry in snap['repos'].items():
        if isinstance(entry['issues'], Unreadable):
            out += not_checked('W4', entry['issues'])
            continue
        for label, act in (('needs-triage', 'triage them (architect-pm)'), ('ready-for-human', 'batch them to the owner')):
            n = sum(1 for i in entry['issues'] if label in label_names(i))
            if n:
                out.append('[W4] %s has %d %s issue(s); %s' % (repo, n, label, act))
    return out


def check_asks(snap):
    """W5: worker questions and escalations nobody answered for 15 minutes (fleet-watch state, open_asks)."""
    if isinstance(snap['state'], Unreadable):
        return not_checked('W5', snap['state'])
    if not snap['loop']:
        return not_checked('W5', 'fleet-watch is not running, so its ask book is stale')
    live = None
    if not isinstance(snap['workers'], Unreadable):
        live = {w['dispatchId'] for w in snap['workers'] if '_unreadable_host' not in w and worker_live(w)}
    out = []
    for mid, row in sorted((snap['state'].get('open_asks') or {}).items()):
        if row.get('answered') or snap['now'] - row.get('at', snap['now']) < ASK_SECONDS:
            continue
        if live is not None and row.get('dispatch') not in live:
            continue
        out.append('[W5] unanswered ask %s from %s for %d minutes; answer it with orca-reply.sh'
                   % (mid, row.get('dispatch'), (snap['now'] - row['at']) // 60))
    return out


CHECKS = (check_loop, check_m6, check_watch, check_asks, check_m1, check_m2, check_m7, check_m5,
          check_m4, check_m3, check_supply, check_queues)


def main(argv):
    p = argparse.ArgumentParser(prog='elon-tick.sh', description='One read only coordinator tick (#1790).')
    p.add_argument('--run', required=True)
    p.add_argument('--config', default=os.environ.get('FLEET_WATCH_CONFIG')
                   or str(Path.home() / '.claude/state/fleet-watch-elon.json'))
    p.add_argument('--state', default=os.environ.get('FLEET_WATCH_STATE'))
    args = p.parse_args(argv)
    if not args.state:
        args.state = re.sub(r'\.json$', '', args.config) + '.state.json'
    try:
        config = read_json(args.config)
    except Unreadable as e:
        print('elon-tick: cannot read config: %s' % e, file=sys.stderr)
        return 2
    snap = gather(args, config)
    actions = [line for check in CHECKS for line in check(snap)]
    if not actions:
        print('OK nothing to do')
        return 0
    for i, line in enumerate(actions, 1):
        print('%d. ACTION %s' % (i, line))
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
