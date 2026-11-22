#!/usr/bin/env python3
"""Move one repo to the 20 label issue set (dotfiles#1216).

usage: issue-labels-migrate.py OWNER/REPO [--apply] [--delete-old]

Dry run by default. It prints counts only. --apply creates the missing labels and relabels
open issues. --delete-old (with --apply) then deletes the retired labels from the repo.
A bug, hotfix or incident gets P0 and loses its other P labels. An issue with several P
labels keeps the highest. An open issue with no state and no hold label gets needs-triage.
"""
import argparse
import json
import subprocess
import sys

NEW_LABELS = {
    'needs-triage': ('Brief incomplete or awaiting priority and routing review', 'fbca04'),
    'ready-for-agent': ('Lint clean brief, one P label, no hold label, no open blockedBy edge', '0e8a16'),
    'needs-redesign': ('PR failed Verdict or Review twice; architect-pm root cause grill', 'b60205'),
    'needs-elon': ('Automation cap reached; the coordinator decides', 'd93f0b'),
    'P0': ('Outage, security, money loss, broken trunk, or any bug', 'b60205'),
    'P1': ('Core workflow broken without a workaround', 'd93f0b'),
    'P2': ('Standard unit of work (default)', 'fbca04'),
    'P3': ('Minor polish or cleanup', 'c2e0c6'),
    'size:S': ('Light tier unit', 'bfdadc'),
    'size:L': ('Strong tier unit, Strong PR review', '5319e7'),
    'role:pm': ('Routes to architect-pm', '1d76db'),
    'role:qa': ('Routes to qa-sdet', '1d76db'),
    'role:ops': ('Routes to release-manager', '1d76db'),
    'role:secops': ('Routes to secops-finops', '1d76db'),
    'role:growth': ('Routes to sales-marketing', '1d76db'),
    'role:support': ('Routes to support-csm', '1d76db'),
    'blocked': ('Waiting on an external dependency or reporter detail', 'e99695'),
    'owner': ('Waiting on the owner', 'e99695'),
    'deferred': ('Parked until a later milestone', 'cccccc'),
    'tracking': ('Umbrella issue; never dispatched to one builder', 'cccccc'),
}
# Board status labels (docs/agents/labels.md, Status). Created with the 20 set, never assigned here.
STATUS_LABELS = {
    'status:接下來': ('Ready and queued: the next batch to dispatch', '0e8a16'),
    'status:進行中': ('A worker is building it now', '1d76db'),
    'status:等你決定': ('Waits on the owner', 'e99695'),
}
ALL_LABELS = {**NEW_LABELS, **STATUS_LABELS}
PRIORITY = ('P0', 'P1', 'P2', 'P3')
STATE = ('needs-triage', 'ready-for-agent', 'needs-redesign', 'needs-elon')
HOLD = ('blocked', 'owner', 'deferred', 'tracking')
P0_SOURCES = ('bug', 'hotfix', 'incident')

# retired label -> new label, or None to drop it
RETIRED = {
    'design:architect': 'size:L', 'design:arena': 'size:L', 'review-strong': 'size:L',
    'area:e2e': 'role:qa', 'secops': 'role:secops',
    'needs-info': 'blocked', 'needs Meta app': 'blocked',
    'owner-action': 'owner', 'ready-for-human': 'owner', 'owner-gated': 'owner', 'needs-owner-shots': 'owner',
    'after-go-live': 'deferred', 'phase-2': 'deferred', 'backlog': 'deferred',
    'spec': 'tracking',
    'hotfix': 'P0', 'incident': 'P0', 'bug': 'P0',
    'design:none': None, 'design:review': None, 'Elon decision pending': None, 'enhancement': None,
    'documentation': None, 'dependencies': None, 'javascript': None, 'duplicate': None,
    'good first issue': None, 'help wanted': None, 'invalid': None, 'question': None, 'wontfix': None,
}


def gh(args, run=subprocess.run):
    proc = run(['gh'] + args, capture_output=True, text=True, timeout=60, check=False)
    if proc.returncode != 0:
        raise RuntimeError('gh %s failed: %s' % (' '.join(args[:2]), (proc.stderr or '').strip()[:200]))
    return proc.stdout


def new_labels_for(labels):
    """The label set an open issue ends with, from the labels it has now."""
    have = set(labels)
    out = {RETIRED[name] if name in RETIRED else name for name in have} - {None}
    if have & set(P0_SOURCES):
        out -= set(PRIORITY)
        out.add('P0')
    else:
        found = [p for p in PRIORITY if p in out]
        out -= set(found[1:])
    if out & set(HOLD):
        out.discard('ready-for-agent')
    elif not out & set(STATE):
        out.add('needs-triage')
    return out


def plan(issues):
    """[(number, add, remove)] for issues whose label set changes."""
    rows = []
    for issue in issues:
        current = {entry['name'] for entry in issue.get('labels') or []}
        target = new_labels_for(current)
        add, remove = sorted(target - current), sorted(current - target)
        if add or remove:
            rows.append((issue['number'], add, remove))
    return rows


def main(argv=None, run=subprocess.run):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('repo', nargs='?')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--delete-old', action='store_true')
    ap.add_argument('--print-labels', action='store_true',
                    help='print name|color|description for every label this script creates, then exit')
    args = ap.parse_args(argv)
    if args.print_labels:
        for name, (description, color) in ALL_LABELS.items():
            print('%s|%s|%s' % (name, color, description))
        return 0
    if not args.repo:
        ap.error('repo is required')
    if args.delete_old and not args.apply:
        ap.error('--delete-old needs --apply')
    try:
        existing = {entry['name'] for entry in json.loads(gh(
            ['label', 'list', '--repo', args.repo, '--limit', '500', '--json', 'name'], run))}
        issues = json.loads(gh(
            ['issue', 'list', '--repo', args.repo, '--state', 'open', '--limit', '1000',
             '--json', 'number,labels'], run))
    except (RuntimeError, ValueError) as exc:
        print('issue-labels-migrate: %s' % exc, file=sys.stderr)
        return 1
    to_create = [name for name in ALL_LABELS if name not in existing]
    rows = plan(issues)
    old_present = [name for name in RETIRED if name in existing]
    print('%s: %d open issues, %d labels to create, %d issues to relabel, %d retired labels present'
          % ('apply' if args.apply else 'dry run', len(issues), len(to_create), len(rows), len(old_present)))
    adds, removes = {}, {}
    for _n, add, remove in rows:
        for name in add:
            adds[name] = adds.get(name, 0) + 1
        for name in remove:
            removes[name] = removes.get(name, 0) + 1
    for name in sorted(adds):
        print('  add %s: %d' % (name, adds[name]))
    for name in sorted(removes):
        print('  remove %s: %d' % (name, removes[name]))
    if not args.apply:
        return 0
    try:
        for name in to_create:
            description, color = ALL_LABELS[name]
            gh(['label', 'create', name, '--repo', args.repo, '--description', description, '--color', color], run)
        for number, add, remove in rows:
            command = ['issue', 'edit', str(number), '--repo', args.repo]
            if add:
                command += ['--add-label', ','.join(add)]
            if remove:
                command += ['--remove-label', ','.join(remove)]
            gh(command, run)
        if args.delete_old:
            for name in old_present:
                gh(['label', 'delete', name, '--repo', args.repo, '--yes'], run)
    except RuntimeError as exc:
        print('issue-labels-migrate: %s' % exc, file=sys.stderr)
        return 1
    print('done: %d created, %d relabeled, %d deleted'
          % (len(to_create), len(rows), len(old_present) if args.delete_old else 0))
    return 0


if __name__ == '__main__':
    sys.exit(main())
