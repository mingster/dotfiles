#!/usr/bin/env python3
"""Same comment fixtures through receipt-state (fleet-watch and ship entry points)."""
import importlib.util
import json
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('receipt_state', HERE.parent / 'receipt-state.py')
rs = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(rs)
RECEIPT_PY = HERE.parent / 'receipt-state.py'
HEAD = 'a' * 40
MAIN = 'b' * 40
ANCESTOR = 'c' * 40


def pr(head, comments, rollup=None):
    return {
        'headRefOid': head,
        'comments': comments,
        'statusCheckRollup': rollup or [],
    }


def cli(*args, pr_obj):
    proc = subprocess.run(
        ['python3', str(RECEIPT_PY), *args],
        input=json.dumps(pr_obj),
        text=True,
        capture_output=True,
    )
    return proc.returncode


def comment(body, at):
    return {'body': body, 'createdAt': at}


class ReceiptStateCross(unittest.TestCase):
    def test_checks_receipt_at_head_cli(self):
        present = pr(HEAD, [comment('Checks: PASS head=%s main=%s' % (HEAD, MAIN), '2026-11-08T00:00:00Z')])
        self.assertEqual(0, cli('checks-receipt-at-head', pr_obj=present))
        self.assertEqual(1, cli('checks-receipt-at-head', pr_obj=pr(HEAD, [])))

    def assert_same_verdict(self, pr_obj, merge_refuse, review_failed, rollup_fail=None):
        self.assertEqual(merge_refuse, cli('--head', HEAD, 'merge-refuse-review', pr_obj=pr_obj) == 0)
        self.assertEqual(review_failed, cli('review-failed', pr_obj=pr_obj) == 0)
        self.assertEqual(review_failed, rs.review_failed_at_head(pr_obj))
        self.assertEqual(merge_refuse, rs.merge_refuse_review_fail(pr_obj, HEAD))
        if rollup_fail is not None:
            self.assertEqual(rollup_fail, cli('--head', HEAD, 'status-rollup-failure', pr_obj=pr_obj) == 0)
            self.assertEqual(rollup_fail, rs.status_rollup_failure_at_head(pr_obj, HEAD))

    def test_checks_pass_review_fail_verdict_pass(self):
        rows = [
            comment('Checks: PASS head=%s' % HEAD, '2026-11-08T09:00:00Z'),
            comment('Review: FAIL head=%s' % HEAD, '2026-11-08T10:00:00Z'),
            comment('Verdict: PASS head=%s verifier=x author=y' % HEAD, '2026-11-08T11:00:00Z'),
        ]
        for ordering in (rows, list(reversed(rows)), [rows[0], rows[2], rows[1]]):
            obj = pr(HEAD, ordering)
            self.assert_same_verdict(obj, merge_refuse=True, review_failed=True)

    def test_checks_pass_review_pass_verdict_fail(self):
        rows = [
            comment('Checks: PASS head=%s' % HEAD, '2026-11-08T09:00:00Z'),
            comment('Review: PASS head=%s' % HEAD, '2026-11-08T10:00:00Z'),
            comment('Verdict: FAIL head=%s verifier=x author=y' % HEAD, '2026-11-08T11:00:00Z'),
        ]
        obj = pr(HEAD, rows)
        self.assert_same_verdict(obj, merge_refuse=False, review_failed=True)

    def test_verdict_fail_then_review_pass(self):
        rows = [
            comment('Verdict: FAIL head=%s verifier=x author=y' % HEAD, '2026-11-08T09:00:00Z'),
            comment('Review: PASS head=%s' % HEAD, '2026-11-08T10:00:00Z'),
        ]
        obj = pr(HEAD, rows)
        self.assert_same_verdict(obj, merge_refuse=False, review_failed=True)

    def test_main_suffix(self):
        rows = [
            comment('Checks: PASS head=%s main=%s' % (HEAD, MAIN), '2026-11-08T09:00:00Z'),
            comment('Review: FAIL head=%s main=%s' % (HEAD, MAIN), '2026-11-08T10:00:00Z'),
        ]
        obj = pr(HEAD, rows)
        self.assert_same_verdict(obj, merge_refuse=True, review_failed=True)

    def test_carried_ancestor_review_fail(self):
        rows = [
            comment('Checks: PASS head=%s' % HEAD, '2026-11-08T12:00:00Z'),
            comment('Review: FAIL head=%s' % ANCESTOR, '2026-11-08T09:00:00Z'),
        ]
        obj = pr(HEAD, rows)
        self.assert_same_verdict(obj, merge_refuse=False, review_failed=False)

    def test_rollup_after_checks_pass(self):
        rows = [comment('Checks: PASS head=%s' % HEAD, '2026-11-08T09:00:00Z')]
        roll = [{'conclusion': 'FAILURE', 'completedAt': '2026-11-08T10:00:00Z'}]
        obj = pr(HEAD, rows, rollup=roll)
        self.assert_same_verdict(obj, merge_refuse=False, review_failed=False, rollup_fail=True)


if __name__ == '__main__':
    unittest.main()
