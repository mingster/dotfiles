"""#1838: a pass ends by PASS_HARD_END (250 s), before the automation's 280 s precheck timeout kills it.

The check is cooperative: at phase, babysit row and scan row boundaries. A worker start already begun is never cut."""
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_deadline', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1730 import BIG_CODE, PICK, pr as tier_pr, scan_config as tier_config  # noqa: E402
from test_fleet_watch_scan import pr as plain_pr  # noqa: E402
from test_fleet_watch_standing import FakeIO  # noqa: E402

T0 = 1_800_000_000.0


class Clock:
    """time.time() for the module under test; a step moves it forward."""

    def __init__(self, elapsed):
        self.now = T0 + elapsed

    def __call__(self):
        return self.now


class PassDeadline(unittest.TestCase):
    def setUp(self):
        fw.begin_pass_counts()

    def tearDown(self):
        fw.end_pass_clock()

    def test_no_clock_never_reaches_the_deadline(self):
        fw.end_pass_clock()
        self.assertFalse(fw.pass_deadline_reached())

    def test_deadline_is_250_seconds_into_the_pass(self):
        self.assertEqual(fw.PASS_HARD_END, 250.0)
        for elapsed, want in ((249.0, False), (250.0, True), (400.0, True)):
            with self.subTest(elapsed=elapsed), patch.object(fw.time, 'time', Clock(elapsed)):
                fw.begin_pass_clock(now=T0)
                self.assertEqual(fw.pass_deadline_reached(), want)

    def test_a_slow_babysit_step_ends_the_row_loop_and_the_start_it_began_finishes(self):
        clock = Clock(100.0)
        starts = []

        def slow_start(command):
            starts.append(command)
            clock.now += 200.0  # this start takes 200 s; it is let finish, then the next row stops the loop
            return fw.BabysitStartResult(0, '', 'ctx_%d' % len(starts), 'term_x')

        state = {}
        with tempfile.TemporaryDirectory() as root, \
                patch.dict(os.environ, {'STANDING_VERIFIER_TRIAL_LOG': os.path.join(root, 't.tsv')}), \
                patch.object(fw.time, 'time', clock), patch.object(fw, 'start_allowed', return_value=True):
            fw.begin_pass_clock(now=T0)
            _n, lines, bits = fw.babysit_pass(
                tier_config(root), state, [], pr_fetch=lambda _r: [tier_pr(2, BIG_CODE), tier_pr(3, BIG_CODE)],
                start_worker=slow_start, pick=PICK, owner_check=lambda _pr, **_kw: None,
                release_worker=lambda *_a, **_k: None, notify_worker=lambda *_a: None,
                now=10_000.0, term_times={}, standing_io=FakeIO(),
            )
        self.assertEqual(len(starts), 1, bits)
        self.assertIn('babysit_deadline=3', bits)

    def babysit_at(self, elapsed):
        starts = []
        with tempfile.TemporaryDirectory() as root, \
                patch.dict(os.environ, {'STANDING_VERIFIER_TRIAL_LOG': os.path.join(root, 't.tsv')}), \
                patch.object(fw.time, 'time', Clock(elapsed)), patch.object(fw, 'start_allowed', return_value=True):
            fw.begin_pass_clock(now=T0)
            _n, _lines, bits = fw.babysit_pass(
                tier_config(root), {}, [], pr_fetch=lambda _r: [tier_pr(2, BIG_CODE)],
                start_worker=lambda c: starts.append(c) or fw.BabysitStartResult(0, '', 'ctx_1', 'term_x'),
                pick=PICK, owner_check=lambda _pr, **_kw: None,
                release_worker=lambda *_a, **_k: None, notify_worker=lambda *_a: None,
                now=10_000.0, term_times={}, standing_io=FakeIO(),
            )
        return starts, bits

    def test_a_babysit_start_that_would_end_past_the_deadline_is_held(self):
        # #1820: a verifier or fixer start is held when elapsed plus its cost passes PASS_HARD_END, so the 280 s
        # timeout never kills a start. The next pass starts it.
        cost = fw.agent_start_cost('cursor')  # PICK picks cursor
        starts, bits = self.babysit_at(fw.PASS_HARD_END - cost + 1)
        self.assertEqual(starts, [], bits)
        self.assertIn('start_deadline=2', bits)
        starts, bits = self.babysit_at(fw.PASS_HARD_END - fw.START_COST_AGY - 1)
        self.assertEqual(len(starts), 1, bits)

    def test_issue_scan_stops_at_the_deadline_before_any_pr_row(self):
        starts = []
        head = 'a' * 40
        prs = [plain_pr(1, head=head, comments=[{'body': 'Checks: FAIL head=%s' % head}])]
        with patch.object(fw.time, 'time', Clock(260.0)):
            fw.begin_pass_clock(now=T0)
            _n, bits = fw.issue_scan_pass(
                tier_config('/tmp/app'), {'issue_scan_backlog_sweep_at': T0}, T0, [], list_issues=lambda _r: [],
                pr_fetch=lambda _r: prs, gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda cmd: (starts.append(cmd), 0)[1], act=lambda _c: 0,
            )
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_deadline', bits)

    def test_run_phase_skips_and_records_a_phase_past_the_deadline(self):
        calls = []
        with patch.object(fw.time, 'time', Clock(100.0)):
            fw.begin_pass_clock(now=T0)
            self.assertEqual(fw.run_phase('audit', lambda: calls.append('audit') or 'ran', 'skipped'), 'ran')
        with patch.object(fw.time, 'time', Clock(251.0)):
            self.assertEqual(fw.run_phase('stall', lambda: calls.append('stall') or 'ran', 'skipped'), 'skipped')
        self.assertEqual(calls, ['audit'])
        self.assertEqual(fw.pass_deadline_line(), 'pass deadline 250s: skipped stall')


if __name__ == '__main__':
    unittest.main()
