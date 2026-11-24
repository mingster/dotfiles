"""#1746: a red gate issue starts its fixer first, and a PR whose receipt names an open red gate waits."""
import os
import subprocess
import tempfile
import unittest

import test_fleet_watch_1088 as base
from test_fleet_watch_1216 import fw, issue_of, row, run_pass

HEAD = base.HEAD


def gate_receipt(head, number):
    return {
        'body': 'Checks: INFRA head=%s\n\nblocked by red gate #%d (run-scoped-tests)\n\nResult: gate broken' % (head, number),
        'createdAt': '2026-11-24T10:00:00Z',
    }


class FixerStart(unittest.TestCase):
    def test_red_gate_issue_starts_before_a_p0_and_before_main_work(self):
        plain = row(1, ('ready-for-agent', 'P0'))
        gate = dict(row(2, ('ready-for-agent', 'P1')), title='red gate: run-scoped-tests')
        later = row(3, ('ready-for-agent', 'P1'))
        starts, _edits, _bits, _state = run_pass([plain, later, gate])
        self.assertEqual(issue_of(starts[0]), 2, [issue_of(s) for s in starts])
        self.assertEqual(sorted(issue_of(s) for s in starts), [1, 2, 3])

    def test_red_gate_in_another_repo_queue_key_still_goes_first(self):
        gate = dict(row(2, ('ready-for-agent', 'P1')), title='red gate: head-checks')
        plain = row(1, ('ready-for-agent', 'P0'))
        keys = sorted([('dotfiles', plain), ('other/app', gate)], key=lambda r: fw.issue_scan_queue_key(*r))
        self.assertEqual(keys[0][1]['number'], 2)


class ReceiptHold(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        wt = os.path.join(self.tmp.name, 'wt')
        subprocess.run(['git', 'init', '-q', wt], check=True)
        subprocess.run(['git', '-C', wt, 'config', 'user.email', 't@example.com'], check=True)
        subprocess.run(['git', '-C', wt, 'config', 'user.name', 't'], check=True)
        subprocess.run(['git', '-C', wt, 'commit', '--allow-empty', '-m', 'init', '-q'], check=True)
        self.config = {
            'issue_scan': {
                'enabled': True, 'repos': [base.REPO], 'repo_roots': {base.REPO: wt},
                'run': 'run_x', 'from_terminal': 'term_x', 'host': 'local',
                'agent': 'cursor', 'model': 'grok-4.7-xhigh',
            },
            'host_caps': {'local': 4},
            'local_host': 'local',
        }

    def scan(self, comments, open_gates):
        starts, asked = [], []

        def red_gates(repo):
            asked.append(repo)
            return open_gates

        def start_detached(command, extra_env=None):
            starts.append(command)
            return 0

        _notices, log = fw.issue_scan_pass(
            self.config, {}, base.NOW, [],
            pr_fetch=lambda _repo: [base.pr_row(HEAD, comments)],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_detached=start_detached, checks_lock_live=lambda _root: False, red_gates=red_gates,
        )
        return starts, log, asked

    def test_pr_naming_an_open_red_gate_waits_without_retrying(self):
        starts, log, _asked = self.scan([gate_receipt(HEAD, 41)], {41})
        self.assertEqual(starts, [])
        self.assertIn('head_checks_red_gate=%s#41' % HEAD[:8], ','.join(log))

    def test_closed_red_gate_lets_the_checks_run_again(self):
        starts, _log, _asked = self.scan([gate_receipt(HEAD, 41)], set())
        self.assertEqual(len(starts), 1)

    def test_other_infra_receipt_keeps_the_normal_rerun(self):
        starts, _log, asked = self.scan([base.infra(HEAD, 1)], {41})
        self.assertEqual(len(starts), 1)
        self.assertEqual(asked, [], 'gh must not be asked when no receipt names a gate')

    def test_hold_helper_reads_only_the_newest_checks_receipt_at_this_head(self):
        pr = base.pr_row(HEAD, [gate_receipt('9' * 40, 41)])
        self.assertIsNone(fw.red_gate_hold(pr, lambda: {41}))
        self.assertEqual(fw.red_gate_hold(base.pr_row(HEAD, [gate_receipt(HEAD, 41)]), lambda: {41}), 41)

    def test_receipt_line_text_is_what_head_checks_writes(self):
        line = 'blocked by red gate #%d (%s)' % (41, 'run-scoped-tests')
        self.assertRegex(line, fw._RED_GATE_HOLD_RE)


if __name__ == '__main__':
    unittest.main()
