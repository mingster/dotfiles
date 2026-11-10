#!/usr/bin/env python3
"""Shared receipt scans: newest comment per kind (Checks, Review, Verdict) at an exact head."""
from __future__ import annotations

import argparse
import json
import re
import sys

HEAD_RECEIPT_RE = re.compile(
    r'^(?P<label>Checks|Review|Verdict): (?P<status>\S+) '
    r'head=(?P<head>[0-9a-f]{40})(?: main=[0-9a-f]{40})?(?:\s|$)'
)


def receipt_first_line(body):
    return (body or '').split('\n')[0]


def newest_comment_receipt(comments, label, head):
    """Newest comment whose first line is ``label:`` for an exact head (optional main=)."""
    best = None
    best_at = ''
    for comment in comments or []:
        first = receipt_first_line(comment.get('body'))
        match = HEAD_RECEIPT_RE.match(first)
        if not match or match.group('label') != label or match.group('head') != head:
            continue
        created = comment.get('createdAt') or ''
        if created >= best_at:
            best = comment
            best_at = created
    return best


def newest_receipt_kind(comments, label, head):
    """PASS, FAIL, or None from the newest receipt of ``label`` at ``head``."""
    comment = newest_comment_receipt(comments, label, head)
    if not comment:
        return None
    first = receipt_first_line(comment.get('body'))
    if first.startswith('%s: PASS' % label):
        return 'PASS'
    if first.startswith('%s: FAIL' % label):
        return 'FAIL'
    if label == 'Verdict' and first.startswith('Verdict: PASS+NOTES'):
        return 'PASS'
    return None


def status_rollup_failure_at_head(pr, head):
    """True when statusCheckRollup shows FAILURE after the newest Checks receipt at head."""
    comments = pr.get('comments') or []
    comment = newest_comment_receipt(comments, 'Checks', head)
    if comment:
        first = receipt_first_line(comment.get('body'))
        if first.startswith('Checks: FAIL'):
            return True
        receipt_at = comment.get('createdAt') or ''
        return any(
            check.get('conclusion') == 'FAILURE'
            and (not receipt_at or (check.get('completedAt') or '') > receipt_at)
            for check in pr.get('statusCheckRollup') or []
            if isinstance(check, dict)
        )
    return any(
        check.get('conclusion') == 'FAILURE'
        for check in pr.get('statusCheckRollup') or []
        if isinstance(check, dict)
    )


def checks_receipt_at_head(pr):
    head = pr.get('headRefOid') or ''
    return newest_receipt_kind(pr.get('comments'), 'Checks', head) in ('PASS', 'FAIL')


def merge_refuse_review_fail(pr, head):
    """Ship preflight: refuse when the newest Review receipt at head is FAIL."""
    return newest_receipt_kind(pr.get('comments'), 'Review', head) == 'FAIL'


def review_failed_at_head(pr):
    """Fleet rework: fail when newest Review or newest Verdict at head is FAIL (per kind, not merged)."""
    head = pr.get('headRefOid') or ''
    comments = pr.get('comments') or []
    for label in ('Review', 'Verdict'):
        if newest_receipt_kind(comments, label, head) == 'FAIL':
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


def rework_needed_checks_and_review(pr):
    """True when Checks fail, or Checks pass and Review/Verdict failed at head (receipt part only)."""
    head = pr.get('headRefOid') or ''
    comments = pr.get('comments') or []
    checks = newest_receipt_kind(comments, 'Checks', head)
    if checks == 'FAIL':
        return True
    if checks == 'PASS' and review_failed_at_head(pr):
        return True
    if checks is not None:
        return False
    for check in pr.get('statusCheckRollup') or []:
        if not isinstance(check, dict):
            continue
        ctx = (check.get('context') or check.get('name') or '').lower()
        if 'head-checks' in ctx or ctx == 'checks':
            return check.get('conclusion') == 'FAILURE'
    return review_failed_at_head(pr)


def _load_pr(stream):
    data = json.load(stream)
    if isinstance(data, dict) and 'headRefOid' in data:
        return data
    if isinstance(data, dict) and 'comments' in data:
        return data
    raise SystemExit('expected PR JSON object on stdin')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--head', help='head sha (default: headRefOid on stdin PR)')
    sub = parser.add_subparsers(dest='cmd', required=True)

    sub.add_parser('merge-refuse-review', help='exit 0 when merge must refuse for Review FAIL')
    sub.add_parser('review-failed', help='exit 0 when rework review/verdict failed at head')
    sub.add_parser('status-rollup-failure', help='exit 0 when rollup failure blocks merge')
    sub.add_parser('rework-checks-review', help='exit 0 when receipt side of rework applies')
    sub.add_parser('checks-receipt-at-head', help='exit 0 when Checks PASS or FAIL exists at head')

    args = parser.parse_args(argv)
    pr = _load_pr(sys.stdin)
    head = args.head or pr.get('headRefOid') or ''

    if args.cmd == 'checks-receipt-at-head':
        return 0 if checks_receipt_at_head(pr) else 1
    if args.cmd == 'merge-refuse-review':
        return 0 if merge_refuse_review_fail(pr, head) else 1
    if args.cmd == 'review-failed':
        return 0 if review_failed_at_head(pr) else 1
    if args.cmd == 'status-rollup-failure':
        return 0 if status_rollup_failure_at_head(pr, head) else 1
    if args.cmd == 'rework-checks-review':
        return 0 if rework_needed_checks_and_review(pr) else 1
    raise SystemExit('unknown command')


if __name__ == '__main__':
    raise SystemExit(main())
