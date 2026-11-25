"""#1820: per phase durations, a start time budget, and throttles on the two slow notice checks."""
import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fleet_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fleet_env)

APP = 'owner/app'
NOW = 1_700_000_000.0


class PassPhases(unittest.TestCase):
    def setUp(self):
        fw.begin_pass_counts()

    def test_phases_line_lists_each_phase_in_order(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('babysit', now=101.5)
        fw._PASS.phase(None, now=131.5)
        self.assertEqual(fw.pass_phases_line(), 'phases inventory=1.5,babysit=30.0')

    def test_running_phase_is_listed_last(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('issue_scan', now=102.0)
        self.assertEqual(fw._PASS.phases_line(now=250.0), 'phases inventory=2.0,issue_scan=148.0')

    def test_no_phase_gives_empty_line(self):
        self.assertEqual(fw.pass_phases_line(), '')

    def test_killed_pass_logs_the_phase_it_was_in(self):
        fw._PASS.phase('inventory', now=100.0)
        fw._PASS.phase('babysit', now=110.0)
        logged = []
        with patch.object(fw, 'log_fleet_watch', logged.append), patch.object(fw.time, 'time', return_value=380.0):
            fw.log_killed_pass(100.0)
        self.assertEqual(logged, ['pass killed 280.0s; phases inventory=10.0,babysit=270.0'])

    def test_new_pass_drops_old_phases(self):
        fw._PASS.phase('inventory', now=1.0)
        fw.begin_pass_counts()
        self.assertEqual(fw.pass_phases_line(), '')

    def test_start_durations_follow_the_phases(self):
        fw._PASS.phase('babysit', now=100.0)
        fw._PASS.starts += [41.25, 38.0]
        self.assertEqual(fw._PASS.phases_line(now=180.0), 'phases babysit=80.0 starts=41.2,38.0')


class StartBudget(unittest.TestCase):
    def setUp(self):
        fw.begin_pass_counts()
        self.addCleanup(setattr, fw, 'PASS_STARTED', None)

    def test_no_budget_outside_main(self):
        fw.PASS_STARTED = None
        self.assertFalse(fw.start_budget_spent(now=10 ** 12))

    def test_budget_counts_from_main_start(self):
        fw.PASS_STARTED = 1000.0
        self.assertFalse(fw.start_budget_spent(now=1000.0 + fw.START_BUDGET_SECONDS - 1))
        self.assertTrue(fw.start_budget_spent(now=1000.0 + fw.START_BUDGET_SECONDS))

    def test_the_wrapper_allows_a_start_a_caller_just_let_through(self):
        # 1820 review: a caller checks at 90 s; the wrapper's own check must not refuse that same start.
        fw.PASS_STARTED = 1000.0
        ran = []
        start = fw.with_coordinator_handle({}, lambda command: ran.append(command) or 0)
        with patch.object(fw.time, 'time', return_value=1000.0 + fw.START_BUDGET_SECONDS + 1):
            self.assertTrue(fw.start_budget_spent())
            self.assertEqual(start(['worker-startup.sh']), 0)
        with patch.object(fw.time, 'time', return_value=1000.0 + fw.START_BUDGET_SECONDS + fw.START_BUDGET_GRACE):
            self.assertEqual(fw.start_result_parts(start(['worker-startup.sh']))[1], fw.START_BUDGET_REASON)
        self.assertEqual(len(ran), 1)

    def test_spent_budget_defers_the_start_without_running_it(self):
        ran = []
        start = fw.with_coordinator_handle({}, lambda command: ran.append(command) or 0)
        with patch.object(fw, 'start_budget_spent', return_value=True):
            result = start(['worker-startup.sh'])
        self.assertEqual(ran, [])
        code, reason = fw.start_result_parts(result)
        self.assertIn(code, fw.BABYSIT_DEFERRED_EXITS)
        self.assertEqual(reason, fw.START_BUDGET_REASON)

    def test_a_start_inside_the_budget_runs_and_its_duration_is_kept(self):
        start = fw.with_coordinator_handle({}, lambda command: 0)
        with patch.object(fw, 'start_budget_spent', return_value=False):
            self.assertEqual(start(['worker-startup.sh']), 0)
        self.assertEqual(len(fw._PASS.starts), 1)


def ready(number):
    return {'number': number, 'title': 'ticket %d' % number, 'body': '## Acceptance criteria\n- x', 'comments': [],
            'labels': [{'name': 'ready-for-agent'}, {'name': 'P2'}], 'createdAt': '2026-01-01T00:00:00Z'}


class IssueScanBudget(unittest.TestCase):
    """A start the budget holds back is not deferred, parked or failed, and it starts on the next pass."""

    def setUp(self):
        fleet_env.guard_gh_writes(self)
        for name, value in (('run_gh', 0), ('brief_lint_missing', [])):
            patcher = patch.object(fw, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        fw.begin_pass_counts()
        self.config = {
            'issue_scan': {
                'enabled': True, 'repos': [APP], 'run': 'run_x', 'from_terminal': 'term_coord', 'host': 'local',
                'agent': 'cursor', 'model': 'm1', 'rework_agent': 'cursor', 'rework_model': 'm1',
                'repo_roots': {APP: '/tmp/app'}, 'backlog_sweep_interval_seconds': 10 ** 9,
            },
            'host_caps': {'local': 8},
        }

    def scan(self, state, issues, spent_after, now):
        starts = []

        def start_worker(command):
            starts.append(command)
            return 0

        with patch.object(fw, 'start_budget_spent', side_effect=lambda now=None, grace=0: len(starts) >= spent_after):
            _notices, log = fw.issue_scan_pass(
                self.config, state, now, [],
                list_issues=lambda repo: issues, pr_fetch=lambda repo: [], gate_check=lambda _cfg: True,
                admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
                start_worker=start_worker, inventory_ok=True, start_detached=lambda _command, extra_env=None: 0)
        return log, starts

    def test_budget_holds_the_rest_for_the_next_pass(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        log, starts = self.scan(state, [ready(1), ready(2)], spent_after=1, now=NOW)
        self.assertEqual(len(starts), 1)
        self.assertIn('issue_start=1', log)
        self.assertIn('issue_start_budget=2', log)
        self.assertFalse([b for b in log if b.startswith('issue_deferred=')])
        self.assertNotIn('2', state.get('issue_scan_deferred', {}).get(APP, {}))
        self.assertEqual((fw._PASS.parked, fw._PASS.failed), (0, 0))
        fw.begin_pass_counts()
        log, starts = self.scan(state, [ready(2)], spent_after=99, now=NOW + 300)
        self.assertIn('issue_start=2', log)

    def test_only_the_issue_start_skips_the_agy_screen_wait(self):
        # 1820 review: verifier, fixer and rework state would hold a stopped start as done, so they keep the wait.
        seen = []
        self.assertNotIn('WORKER_STARTUP_AGY_DEFER', fw.os.environ)
        fw.start_issue_worker(lambda command: seen.append(fw.os.environ.get('WORKER_STARTUP_AGY_DEFER')) or 0, ['x'])
        self.assertEqual(seen, ['1'])
        self.assertNotIn('WORKER_STARTUP_AGY_DEFER', fw.os.environ)
        state = {'issue_scan_backlog_sweep_at': NOW}
        flags = []
        with patch.object(fw, 'start_issue_worker', side_effect=lambda start, command: flags.append(1) or start(command)):
            self.scan(state, [ready(1)], spent_after=99, now=NOW)
        self.assertEqual(flags, [1])


def check_result(calls):
    return lambda *a, **k: calls.append(a) or SimpleNamespace(returncode=0, stdout='')


class StaleWorktreeThrottle(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.config = {'repo_roots': {APP: str(Path(__file__).parent)}}

    def test_runs_once_per_interval(self):
        state = {}
        fw.stale_worktree_notices(self.config, state, 1000, run=check_result(self.calls))
        fw.stale_worktree_notices(self.config, state, 1000 + 300, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 1)
        fw.stale_worktree_notices(self.config, state, 1000 + fw.STALE_WORKTREE_EVERY, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 2)

    def test_without_state_it_runs_every_time(self):
        fw.stale_worktree_notices(self.config, run=check_result(self.calls))
        fw.stale_worktree_notices(self.config, run=check_result(self.calls))
        self.assertEqual(len(self.calls), 2)


if __name__ == '__main__':
    unittest.main()
