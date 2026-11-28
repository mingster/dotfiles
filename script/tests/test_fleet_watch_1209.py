"""#1209: no issue start when an open PR exists for it, and a Verdict or Review FAIL goes to a digest line."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import REPO, issue_row, scan_config  # noqa: E402

HEAD = 'c' * 40


def open_pr(number, branch='feature/x', body='', comments=(), checks=()):
    return {'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': HEAD, 'headRefName': branch,
            'body': body, 'comments': list(comments), 'statusCheckRollup': list(checks), 'labels': []}


def run_pass(prs, issues=()):
    starts = []
    state = {'issue_scan_backlog_sweep_at': 1}
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        notices, bits = fw.issue_scan_pass(
            scan_config('/work/app'), state, 1, [],
            pr_fetch=lambda _r: prs, list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=lambda command: starts.append(command) or 0, act=lambda _c: 0,
        )
    return starts, notices, bits, state


class IssueWithOpenPr(unittest.TestCase):
    def issue_starts(self, prs):
        return run_pass(prs, [issue_row(5, '2026-01-01T00:00:00Z')])[0]

    def test_no_pr_starts(self):
        self.assertEqual(len(self.issue_starts([])), 1)

    def test_closing_keyword_in_body_skips(self):
        for body in ('Closes #5', 'fixes: #5', 'Refs o/r#5', 'Resolves #5.'):
            self.assertEqual(self.issue_starts([open_pr(9, body=body)]), [], body)

    def test_branch_with_the_issue_number_skips(self):
        self.assertEqual(self.issue_starts([open_pr(9, branch='me/build-5')]), [])

    def test_other_issue_numbers_do_not_skip(self):
        prs = [open_pr(9, branch='me/build-50', body='Closes #55')]
        self.assertEqual(len(self.issue_starts(prs)), 1)

    def test_closed_pr_does_not_skip(self):
        pr = open_pr(9, body='Closes #5')
        pr['state'] = 'MERGED'
        self.assertEqual(len(self.issue_starts([pr])), 1)

    def test_skip_is_logged(self):
        _s, _n, bits, _st = run_pass([open_pr(9, body='Closes #5')], [issue_row(5, '2026-01-01T00:00:00Z')])
        self.assertIn('issue_open_pr=5', bits)


class FailGoesToDigest(unittest.TestCase):
    def test_verdict_and_review_fail_digest_without_rework(self):
        for label in ('Verdict', 'Review'):
            pr = open_pr(9, comments=[{'body': '%s: FAIL head=%s\nbad' % (label, HEAD)}])
            starts, notices, bits, _st = run_pass([pr])
            self.assertEqual(starts, [], label)
            self.assertTrue(any(n.startswith('FAIL: send to architect-pm') and '#9' in n for n in notices), label)
            self.assertIn('rework_fail_digest=9', bits)

    def test_digest_line_is_sent_once_per_head(self):
        pr = open_pr(9, comments=[{'body': 'Review: FAIL head=%s' % HEAD}])
        state = {'issue_scan_backlog_sweep_at': 1}
        seen = []
        for _ in range(2):
            with patch.object(fw, 'rpc', side_effect=fake_rpc):
                notices, _b = fw.issue_scan_pass(
                    scan_config('/work/app'), state, 1, [], pr_fetch=lambda _r: [pr], list_issues=lambda _r: [],
                    gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                    start_worker=lambda c: 0, act=lambda _c: 0)
            seen.append(len(notices))
        self.assertEqual(seen, [1, 0])

    def test_checks_fail_still_reruns_via_rework(self):
        pr = open_pr(9, comments=[{'body': 'Checks: FAIL head=%s\nlint' % HEAD}],
                     checks=[{'name': 'script-tests', 'conclusion': 'FAILURE'}])
        pr['files'] = []
        starts, notices, _b, _st = run_pass([pr])
        self.assertFalse(any(n.startswith('FAIL: send') for n in notices))


if __name__ == '__main__':
    unittest.main()
