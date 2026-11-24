#!/usr/bin/env python3
"""Measure the delay from a PASS Verdict at the merged head to the merge (#1731).

Usage: verdict-to-merge.py --repo owner/name [--hours 48] [--split <ISO time>] [--json]
       verdict-to-merge.py --fixture <data.json> [--split <ISO time>] [--json]
-h and --help print this Usage block.

Per merged PR: the first `Verdict: PASS` or `Verdict: PASS+NOTES` comment at the merged head, then merged
minus that time. Prints n, p50/p75/p90/p95 and max in minutes, a bucket count, and the slowest PRs, each
with a cause by wait time: `ship-at-verdict` (under 1 minute, the verifier's `post-verdict.sh --ship`),
`waited-for-pass` (1 to 15 minutes), `waited-over-15` (15 minutes or more), and `main-red` (a push Checks run on
main failed or was cancelled during the wait, so ship.sh refused).
--split puts PRs whose Verdict is before that time in their own group, to compare before and after a change.
A PR merged on a Verdict at an older head (patch-id carry) or with no Verdict is counted as `no-verdict-at-head`.
--fixture reads {"prs": [{number, mergedAt, headRefOid, comments: [{createdAt, body}]}], "main_runs": [{createdAt, updatedAt, conclusion}]}.
"""
import argparse
import datetime as dt
import json
import re
import subprocess
import sys

BUCKETS = (('<1', 1), ('1-5', 5), ('5-10', 10), ('10-30', 30), ('>=30', None))
VERDICT = re.compile(r'^Verdict: (PASS\+NOTES|PASS) head=([0-9a-f]{40})\b')


def parse(stamp):
    return dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))


def percentile(values, q):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, int(len(ordered) * q / 100 + 0.5) - 1))]


def bucket(minutes):
    for name, upper in BUCKETS:
        if upper is None or minutes < upper:
            return name


def cause(minutes, verdict_at, merged_at, red_windows):
    if any(start <= merged_at and end >= verdict_at for start, end in red_windows):
        return 'main-red'
    if minutes < 1:
        return 'ship-at-verdict'
    return 'waited-for-pass' if minutes < 15 else 'waited-over-15'


def measure(prs, main_runs):
    red = [(parse(r['createdAt']), parse(r['updatedAt'])) for r in main_runs
           if r.get('conclusion') in ('failure', 'cancelled')]
    rows, missing = [], 0
    for pr in prs:
        head = pr.get('headRefOid') or ''
        stamps = []
        for comment in pr.get('comments') or []:
            match = VERDICT.match((comment.get('body') or '').split('\n', 1)[0])
            if match and match.group(2) == head:
                stamps.append(parse(comment['createdAt']))
        if not stamps:
            missing += 1
            continue
        verdict_at, merged_at = min(stamps), parse(pr['mergedAt'])
        minutes = (merged_at - verdict_at).total_seconds() / 60
        rows.append({'number': pr['number'], 'verdict_at': verdict_at, 'minutes': minutes,
                     'cause': cause(minutes, verdict_at, merged_at, red)})
    return rows, missing


def summary(rows):
    values = [r['minutes'] for r in rows]
    if not values:
        return {'n': 0}
    counts, causes = {}, {}
    for r in rows:
        counts[bucket(r['minutes'])] = counts.get(bucket(r['minutes']), 0) + 1
        causes[r['cause']] = causes.get(r['cause'], 0) + 1
    return {'n': len(values), **{'p%d' % q: round(percentile(values, q), 1) for q in (50, 75, 90, 95)},
            'max': round(max(values), 1), 'buckets': {name: counts.get(name, 0) for name, _ in BUCKETS},
            'causes': causes,
            'slowest': [{'pr': r['number'], 'minutes': round(r['minutes'], 1), 'cause': r['cause']}
                        for r in sorted(rows, key=lambda r: -r['minutes'])[:5]]}


def gh_json(args):
    return json.loads(subprocess.run(['gh'] + args, capture_output=True, text=True, check=True).stdout)


def fetch(repo, hours):
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')
    listed = gh_json(['pr', 'list', '--repo', repo, '--state', 'merged', '--limit', '500',
                      '--search', 'merged:>=' + since, '--json', 'number'])
    prs = [gh_json(['pr', 'view', str(p['number']), '--repo', repo, '--json', 'number,mergedAt,headRefOid,comments'])
           for p in listed]
    runs = gh_json(['run', 'list', '--repo', repo, '--workflow', 'Checks', '--branch', 'main', '--event', 'push',
                    '--limit', '300', '--json', 'createdAt,updatedAt,conclusion'])
    return prs, runs


def main(argv):
    if any(a in ('-h', '--help') for a in argv):
        print(__doc__.split('"""')[0].strip())
        return 0
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--repo')
    parser.add_argument('--hours', type=float, default=48)
    parser.add_argument('--fixture')
    parser.add_argument('--split')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    if bool(args.repo) == bool(args.fixture):
        print('verdict-to-merge: give --repo or --fixture, not both', file=sys.stderr)
        return 2
    if args.fixture:
        data = json.load(open(args.fixture, encoding='utf-8'))
        prs, runs = data['prs'], data.get('main_runs', [])
    else:
        prs, runs = fetch(args.repo, args.hours)
    rows, missing = measure(prs, runs)
    groups = {'all': rows}
    if args.split:
        cut = parse(args.split)
        groups['before'] = [r for r in rows if r['verdict_at'] < cut]
        groups['after'] = [r for r in rows if r['verdict_at'] >= cut]
    result = {'no-verdict-at-head': missing, **{k: summary(v) for k, v in groups.items()}}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print('no-verdict-at-head: %d' % missing)
        for name, stats in result.items():
            if name != 'no-verdict-at-head':
                print('%s: %s' % (name, json.dumps(stats)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
