#!/usr/bin/env python3
"""Settle one dispatched task whose dispatch record is gone everywhere (#2022).

Usage: settle-orphan-task.sh --run <run_id> --task <task_id> [--dry-run]

An orphan is a task still `dispatched` while `orca orchestration dispatch-show --task <id>` returns no
dispatch on this machine and on every paired Orca server. The script checks every server first and refuses
when any shows a dispatch (stop or settle that worker instead) or cannot be read (the check would be partial).
Then it marks the task failed with `task-update`. When Orca still refuses because a start on a paired server
is active, it fences that worker with `worker-abandon` (retains every resource, no process or file action)
and retries once. It never edits Orca's own database.

Exit 0 settled (or already settled, or --dry-run found an orphan), 1 refused or Orca would not settle it, 2 usage.
"""
import json
import os
import shlex
import subprocess
import sys

USAGE = 'Usage: settle-orphan-task.sh --run <run_id> --task <task_id> [--dry-run]'
REASON = 'orphan: no dispatch record on any server (settled by settle-orphan-task.sh)'


def orca(*args):
    """(ok, result or error text). Never raises."""
    command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca')) + list(args) + ['--json']
    try:
        out = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
        reply = json.loads(out.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return False, 'orca %s: no readable reply' % ' '.join(args[:2])
    if not isinstance(reply, dict) or reply.get('ok') is False or not isinstance(reply.get('result'), dict):
        error = reply.get('error') if isinstance(reply, dict) else None
        return False, str((error or {}).get('message') or 'orca %s: refused' % ' '.join(args[:2]))
    return True, reply['result']


def servers():
    """[(label, environment args)] for this machine and every paired server, or None when the list cannot be read."""
    ok, listed = orca('environment', 'list')
    if not ok:
        return None
    found = [('local', [])]
    for env in listed.get('environments') or []:
        found.append((env.get('name') or env.get('id'), ['--environment', env['id']]))
    return found


def main(argv):
    run = task = None
    dry = False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == '--run' and args:
            run = args.pop(0)
        elif a == '--task' and args:
            task = args.pop(0)
        elif a == '--dry-run':
            dry = True
        else:
            print(USAGE, file=sys.stderr)
            return 2
    if not run or not task:
        print(USAGE, file=sys.stderr)
        return 2

    ok, listed = orca('orchestration', 'task-list', '--run', run)
    row = next((t for t in (listed.get('tasks') or []) if t.get('id') == task), None) if ok else None
    if not ok:
        print('REFUSED: cannot read tasks of %s: %s' % (run, listed), file=sys.stderr)
        return 1
    if row is None:
        print('REFUSED: %s is not a task of %s' % (task, run), file=sys.stderr)
        return 1
    if row.get('status') in ('failed', 'completed'):
        print('already %s: %s' % (row['status'], task))
        return 0
    if row.get('status') != 'dispatched':
        print('REFUSED: %s is %s, not dispatched' % (task, row.get('status')), file=sys.stderr)
        return 1

    hosts = servers()
    if hosts is None:
        print('REFUSED: cannot list the paired servers, so the check would be partial', file=sys.stderr)
        return 1
    for label, env in hosts:
        ok, shown = orca('orchestration', 'dispatch-show', '--task', task, *env)
        if not ok:
            print('REFUSED: cannot read dispatch-show on %s (%s); not settling on a partial check' % (label, shown), file=sys.stderr)
            return 1
        if shown.get('dispatch'):
            print('REFUSED: %s has a dispatch record on %s (%s); stop or settle that worker instead'
                  % (task, label, shown['dispatch'].get('id')), file=sys.stderr)
            return 1
    print('no dispatch record for %s on %s' % (task, ', '.join(label for label, _ in hosts)))
    if dry:
        print('dry run: would mark %s failed' % task)
        return 0

    ok, reply = orca('orchestration', 'task-update', '--id', task, '--status', 'failed', '--result', REASON, '--run', run)
    if not ok and 'Dispatch' in str(reply):
        fenced = 0
        for label, env in hosts:
            found, workers = orca('orchestration', 'worker-list', '--limit', '100', *env)
            for w in (workers.get('workers') or []) if found else []:
                if w.get('taskId') == task and w.get('outcome') == 'in_progress' and w.get('dispatchId'):
                    done, why = orca('orchestration', 'worker-abandon', '--dispatch', w['dispatchId'], *env)
                    print('fenced %s on %s' % (w['dispatchId'], label) if done else 'could not fence %s on %s: %s' % (w['dispatchId'], label, why))
                    fenced += 1 if done else 0
        if fenced:
            ok, reply = orca('orchestration', 'task-update', '--id', task, '--status', 'failed', '--result', REASON, '--run', run)
    if not ok:
        print('NOT SETTLED: Orca refused: %s' % reply, file=sys.stderr)
        return 1
    print('settled %s: failed (%s)' % (task, REASON))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
