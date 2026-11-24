#!/usr/bin/env python3
"""Weekly audit of tier 0 pull requests (#1730): pick 5 random merged ones, then report what the audits found.

fleet-watch calls pick() and append_log() once a week and starts one verifier per picked PR. Each verifier posts a
comment whose first line is `Audit: PASS merged=<sha>` or `Audit: FAIL merged=<sha>` (never a `Verdict:` line).
Usage: tier0-audit.py report --repo <owner/name> [--log FILE] [--days 14]
"""
import argparse
import calendar
import json
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

COUNT = 5
FAIL_RATE_BAR = 5.0  # percent, from the one week trial's success bar
AUDIT_RE = re.compile(r'^Audit: (PASS|FAIL) merged=([0-9a-f]{40})\b')


def log_path():
    return os.environ.get('TIER0_AUDIT_LOG') or os.path.expanduser('~/agent-state/tier0-audit.tsv')


def pick(prs, tier_of, count=COUNT, rng=None):
    """Up to `count` random tier 0 PRs, in PR number order."""
    eligible = [p for p in prs if isinstance(p, dict) and tier_of(p) == 0]
    chosen = (rng or random).sample(eligible, max(0, min(count, len(eligible))))
    return sorted(chosen, key=lambda p: p.get('number') or 0)


def append_log(path, week, repo, picks, now=None):
    """One row per picked PR: week, repo, PR number, merge commit, pick time (UTC)."""
    if not picks:
        return
    stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() if now is None else now))
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'a', encoding='utf-8') as handle:
        for row in picks:
            sha = (row.get('mergeCommit') or {}).get('oid') or ''
            handle.write('\t'.join([week, repo, str(row.get('number')), sha, stamp]) + '\n')


def read_log(path, repo, since):
    """[(week, pr, merge sha)] for this repo picked at or after `since` (epoch seconds)."""
    rows = []
    try:
        lines = Path(path).read_text(encoding='utf-8').splitlines()
    except OSError:
        return rows
    for line in lines:
        parts = line.split('\t')
        if len(parts) < 5 or parts[1] != repo or not parts[2].isdigit():
            continue
        try:
            picked = calendar.timegm(time.strptime(parts[4], '%Y-%m-%dT%H:%M:%SZ'))
        except ValueError:
            continue
        if picked >= since:
            rows.append((parts[0], int(parts[2]), parts[3]))
    return rows


def audit_result(comments, sha):
    """PASS, FAIL or pending from the newest unedited Audit comment for this merge commit."""
    found = 'pending'
    for comment in comments or []:
        if not isinstance(comment, dict) or comment.get('isMinimized') or comment.get('includesCreatedEdit'):
            continue
        match = AUDIT_RE.match((comment.get('body') or '').split('\n')[0])
        if match and (not sha or match.group(2) == sha):
            found = match.group(1)
    return found


def summarize(rows, comments_by_pr):
    results = [(week, pr, sha, audit_result(comments_by_pr.get(pr), sha)) for week, pr, sha in rows]
    passed = sum(1 for r in results if r[3] == 'PASS')
    failed = sum(1 for r in results if r[3] == 'FAIL')
    rate = (100.0 * failed / (passed + failed)) if passed + failed else None
    return results, passed, failed, rate


def render(repo, results, passed, failed, rate):
    lines = ['tier 0 audit %s: %d picked, %d PASS, %d FAIL, %d pending' % (
        repo, len(results), passed, failed, len(results) - passed - failed)]
    for week, pr, _sha, result in results:
        lines.append('  %s #%d %s' % (week, pr, result))
    if rate is None:
        lines.append('  FAIL rate: no finished audit yet (bar %g%% or less)' % FAIL_RATE_BAR)
    else:
        lines.append('  FAIL rate: %.0f%% (bar %g%% or less)%s' % (rate, FAIL_RATE_BAR, '' if rate <= FAIL_RATE_BAR else ', over the bar'))
    return '\n'.join(lines)


def fetch_comments(repo, number, run=subprocess.run):
    try:
        out = run(['gh', 'pr', 'view', str(number), '--repo', repo, '--json', 'comments'],
                  capture_output=True, text=True, timeout=30, check=True)
        return json.loads(out.stdout).get('comments') or []
    except (subprocess.SubprocessError, OSError, ValueError):
        return None


def report(repo, path, days, fetch=fetch_comments, now=None):
    since = (time.time() if now is None else now) - days * 86400
    rows = read_log(path, repo, since)
    if not rows:
        return 'tier 0 audit %s: no PR picked in the last %d days' % (repo, days)
    comments = {pr: fetch(repo, pr) for _w, pr, _s in rows}
    unread = [pr for pr, c in comments.items() if c is None]
    results, passed, failed, rate = summarize(rows, {pr: c for pr, c in comments.items() if c is not None})
    text = render(repo, results, passed, failed, rate)
    return text + ('\n  WARN: could not read comments of %s' % ', '.join('#%d' % pr for pr in unread) if unread else '')


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='cmd', required=True)
    rep = sub.add_parser('report')
    rep.add_argument('--repo', required=True)
    rep.add_argument('--log', default=None)
    rep.add_argument('--days', type=int, default=14)
    args = parser.parse_args(argv)
    print(report(args.repo, args.log or log_path(), args.days))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
