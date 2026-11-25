"""#1820 slice 3: an antigravity issue start skips the sign in wait; the next pass stops, releases and restarts it.

Test cases 13 to 21 of the #1820 redesign comment."""
import copy
import importlib.util
import os
import pathlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parent.parent
spec = importlib.util.spec_from_file_location('fleet_watch_agy_defer', SCRIPT / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
agy_spec = importlib.util.spec_from_file_location('agy_signin_defer', SCRIPT / 'agy-signin.py')
agy = importlib.util.module_from_spec(agy_spec)
agy_spec.loader.exec_module(agy)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_1811 import row as ready_row  # noqa: E402
from test_fleet_watch_park import REPO, scan_config  # noqa: E402
from test_fleet_watch_scan import pr as plain_pr  # noqa: E402

SIGN_IN = (SCRIPT / 'tests' / 'fixtures' / 'agy' / 'signin-screen.txt').read_text()
WORKING = (SCRIPT / 'tests' / 'fixtures' / 'agy' / 'working-screen.txt').read_text()
ENV = fw.AGY_DEFER_ENV


def agy_row(dispatch, number, role='fullstack-dev', terminal='t_' + 'x', host=None, title=None):
    """A worker-list row for an antigravity worker started from issue `number`."""
    row = {
        'dispatchId': dispatch, 'terminal': terminal, 'agent': 'antigravity', 'dispatchStatus': 'dispatched',
        'terminalState': 'active', 'projection': {'outcome': 'in_progress'},
        '_task_title': title or '#%d|%s' % (number, role),
    }
    if terminal is None:
        row.pop('terminal')
    if host:
        row['projection']['host'] = {'id': host}
        row['server'] = {'name': host}
    return row


def own(state, dispatch, kind='issue'):
    state.setdefault('own_dispatches', {})[dispatch] = {'kind': kind}


class FakeOrca:
    """Records every rpc call; `listed` says which terminals the host still lists after a stop."""

    def __init__(self, shown_terminal=None, stop_error=False):
        self.calls = []
        self.shown_terminal = shown_terminal
        self.stop_error = stop_error

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('orchestration', 'worker-show'):
            return {'worker': {'terminal': self.shown_terminal}} if self.shown_terminal else {}
        if args[:2] == ('orchestration', 'worker-stop') and self.stop_error:
            raise fw.OrcaReadError('stop failed')
        return {}

    def verbs(self):
        return [(a[1], a[a.index('--dispatch') + 1]) + (('env=' + a[a.index('--environment') + 1],)
                                                         if '--environment' in a else ()) for a in self.calls]


class AgyCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        patcher = patch.dict(os.environ, {'AGY_UNAVAILABLE_STATE': str(pathlib.Path(self.tmp) / 'agy-unavailable.json')})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config = {'local_host': 'hosta'}
        self.state = {}
        self.orca = FakeOrca()

    def sweep(self, workers, screens, now=1000, orca=None, persist=None):
        return fw.agy_signin_notices(
            self.config, workers, read=lambda term, host: screens[term], now=now,
            state=self.state, rpc_call=orca or self.orca, persist_state=persist)


class DeferEnv(unittest.TestCase):
    """13: only issue starts carry WORKER_STARTUP_AGY_DEFER=1, and it is not left set."""

    def issue_start_env(self, prior=None):
        seen = []
        state = {'issue_scan_backlog_sweep_at': 1}

        def start(command):
            seen.append(os.environ.get(ENV))
            return 0

        env = {k: v for k, v in os.environ.items() if k != ENV}
        if prior is not None:
            env[ENV] = prior
        with patch.dict(os.environ, env, clear=True), patch.object(fw, 'rpc', side_effect=fake_rpc), \
                patch.object(fw, 'run_gh', return_value=0):
            fw.issue_scan_pass(
                scan_config('/work/app'), state, 1, [], pr_fetch=lambda _r: [],
                list_issues=lambda _r: [ready_row(5)], list_claimed=lambda _r: [],
                gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start, act=lambda _c: 0)
            after = os.environ.get(ENV)
        return seen, after

    def test_issue_start_carries_the_variable_and_leaves_none_behind(self):
        seen, after = self.issue_start_env()
        self.assertEqual(seen, ['1'])
        self.assertIsNone(after)

    def test_a_value_set_before_the_start_is_put_back(self):
        seen, after = self.issue_start_env(prior='0')
        self.assertEqual(seen, ['1'])
        self.assertEqual(after, '0')

    def test_verifier_start_has_no_variable(self):
        seen = []
        config = {'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: '/tmp/app'}},
                  'babysit': {'repos': [REPO], 'startup': '/bin/true'}}
        from test_fleet_watch_park import verifier_pr  # noqa: E402
        pick = lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731

        def start(command):
            seen.append(os.environ.get(ENV))
            return fw.BabysitStartResult(0)

        with patch.dict(os.environ, {k: v for k, v in os.environ.items() if k != ENV}, clear=True):
            fw.babysit_pass(config, {}, [], pr_fetch=lambda _r: [verifier_pr()], pr_state_fetch=None,
                            start_worker=start, pick=pick, owner_check=lambda _pr: None)
        self.assertEqual(seen, [None])

    def test_rework_start_has_no_variable(self):
        seen = []
        head = 'a' * 40
        prs = [plain_pr(1, head=head, comments=[{'body': 'Checks: FAIL head=%s' % head}])]
        env = {k: v for k, v in os.environ.items() if k != ENV}

        def start(command):
            seen.append(os.environ.get(ENV))
            return 0

        with patch.dict(os.environ, env, clear=True), patch.object(fw, 'rpc', side_effect=fake_rpc):
            fw.issue_scan_pass(
                scan_config('/work/app'), {'issue_scan_backlog_sweep_at': 1}, 1, [], pr_fetch=lambda _r: prs,
                list_issues=lambda _r: [], gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0}, start_worker=start, act=lambda _c: 0)
        self.assertEqual(seen, [None])

    def test_only_the_issue_start_site_sets_it(self):
        source = (SCRIPT / 'fleet-watch.py').read_text()
        self.assertEqual(source.count('with agy_signin_deferred():'), 1)


class OtherRowsAreNotStopped(AgyCase):
    """14: a verifier, fixer or rework row on the sign in screen is marked and noticed, never stopped."""

    def test_verifier_fixer_and_rework_rows_are_left_running(self):
        rows = [
            agy_row('dv', 7, 'qa-sdet', 't1', host='hostb'),
            agy_row('dx', 8, 'fullstack-dev', 't2', host='hostc'),
            agy_row('dr', 9, 'fullstack-dev', 't3', host='hostd'),
            agy_row('ds', 10, 'qa-sdet', 't4', host='hoste', title='#10|qa-sdet|standing'),
        ]
        own(self.state, 'dv', 'verifier')
        own(self.state, 'dx', 'rework')
        own(self.state, 'dr', 'rework')
        own(self.state, 'ds', 'verifier')
        notices = self.sweep(rows, {t: SIGN_IN for t in ('t1', 't2', 't3', 't4')})
        self.assertEqual(len(notices), 4)
        self.assertEqual(self.orca.calls, [])
        self.assertNotIn(fw.AGY_RELEASED_KEY, self.state)
        for host in ('hostb', 'hostc', 'hostd', 'hoste'):
            self.assertTrue(agy.is_unavailable(host, 1000 + 3600))
        self.assertTrue(all(fw.worker_row_is_live(r) for r in rows))

    def test_issue_title_without_an_issue_start_record_is_not_stopped(self):
        rows = [agy_row('d1', 7, host='hostb')]
        notices = self.sweep(rows, {'t_x': SIGN_IN})
        self.assertEqual(len(notices), 1)
        self.assertEqual(self.orca.calls, [])

    def test_working_issue_row_is_left_alone(self):
        rows = [agy_row('d1', 7, host='hostb')]
        own(self.state, 'd1')
        self.assertEqual(self.sweep(rows, {'t_x': WORKING}), [])
        self.assertEqual(self.orca.calls, [])


class RemoteIssueStop(AgyCase):
    def test_no_terminal_handle_comes_from_worker_show_then_it_is_stopped(self):  # 15
        self.orca = FakeOrca(shown_terminal='t_shown')
        rows = [agy_row('d1', 7, terminal=None, host='hostb')]
        own(self.state, 'd1')
        reads = []

        def read(term, host):
            reads.append((term, host))
            return SIGN_IN

        fw.agy_signin_notices(self.config, rows, read=read, now=1000, state=self.state, rpc_call=self.orca)
        self.assertEqual(reads, [('t_shown', 'hostb')])
        self.assertIn(('worker-show', 'd1', 'env=hostb'), self.orca.verbs())
        self.assertIn(('worker-stop', 'd1', 'env=hostb'), self.orca.verbs())

    def test_stopped_once_released_on_both_sides_and_never_read_again(self):  # 16
        own(self.state, 'd1')
        rows = [agy_row('d1', 7, host='hostb')]
        persisted = []
        first = self.sweep(rows, {'t_x': SIGN_IN}, persist=lambda: persisted.append(1))
        self.assertEqual(len(first), 1)
        self.assertEqual(self.orca.verbs(), [
            ('worker-stop', 'd1', 'env=hostb'), ('worker-release', 'd1', 'env=hostb'), ('worker-release', 'd1')])
        self.assertEqual(self.state[fw.AGY_RELEASED_KEY], ['d1'])
        self.assertEqual(persisted, [1])
        self.assertFalse(fw.worker_row_is_live(rows[0]))
        self.assertFalse(fw.issue_has_live_dispatch(rows, 7))
        # Next pass: the inventory lists the row live again, the terminal is still there.
        again = [agy_row('d1', 7, host='hostb')]
        fw.apply_agy_released(again, self.state)
        self.assertFalse(fw.issue_has_live_dispatch(again, 7))
        orca = FakeOrca()
        with patch.object(agy, 'mark', side_effect=AssertionError('mark again')):
            notices = fw.agy_signin_notices(
                self.config, again, read=lambda *_a: self.fail('read again'), now=1300,
                state=self.state, rpc_call=orca)
        self.assertEqual(notices, [])
        self.assertEqual(orca.calls, [])
        self.assertIn('d1', fw.persisted_released_ids(self._write_state()))

    def _write_state(self):
        path = pathlib.Path(self.tmp) / 'state.json'
        fw.save_state(path, self.state)
        return path

    def test_a_failed_stop_is_not_recorded_and_tries_again(self):
        own(self.state, 'd1')
        rows = [agy_row('d1', 7, host='hostb')]
        self.sweep(rows, {'t_x': SIGN_IN}, orca=FakeOrca(stop_error=True))
        self.assertNotIn(fw.AGY_RELEASED_KEY, self.state)
        self.assertTrue(fw.worker_row_is_live(rows[0]))
        self.sweep(rows, {'t_x': SIGN_IN}, now=1300)
        self.assertEqual(self.state[fw.AGY_RELEASED_KEY], ['d1'])

    def test_terminal_gone_after_the_stop_raises_no_dead_dispatch_notice(self):  # 17
        own(self.state, 'd1')
        server_row = {'dispatchId': 'd1', 'state': 'ready', 'stage': 'server_record', 'agent': 'antigravity',
                      'server': {'name': 'hostb'}, 'host': 'hostb', '_task_title': '#7|fullstack-dev'}
        self.sweep([agy_row('d1', 7, host='hostb')], {'t_x': SIGN_IN})
        listed = lambda *a: {'terminals': []}  # noqa: E731
        control = fw.gone_remote_dispatch_notices([dict(server_row)], {}, lambda *a: {} if a[1] == 'worker-show' else listed())
        self.assertEqual(len(control), 1)  # the notice a row left live would send
        rows = [dict(server_row)]
        fw.apply_agy_released(rows, self.state)
        notices = fw.gone_remote_dispatch_notices(rows, self.state, lambda *a: listed())
        self.assertEqual(notices, [])

    def test_the_pass_stages_see_the_row_as_not_live(self):  # 18
        own(self.state, 'd1')
        self.sweep([agy_row('d1', 7, host='hostb')], {'t_x': SIGN_IN})
        # The next pass lists the row live again; the real state holds its issue start record.
        rows = [agy_row('d1', 7, host='hostb')]
        fw.apply_agy_released(rows, self.state)
        calls = []

        def spy(*args):
            calls.append(args)
            return {}

        times = {'t_x': 0}
        before = copy.deepcopy(self.state)
        stall, _log = fw.worker_stall_pass(self.config, self.state, 10 ** 6, rows, times, spy, inventory_ok=True)
        signal, _slog = fw.worker_signal_pass(self.config, self.state, 10 ** 6, rows, times, inventory_ok=True)
        nudges = fw.unread_nudge_pass(self.state, 10 ** 6, rows, times, [], spy)
        self.assertEqual((stall, signal, nudges, calls), ([], [], [], []))
        self.assertEqual({k: v for k, v in self.state.items() if v}, before)

    def test_a_tier_0_audit_issue_start_is_stopped_too(self):
        own(self.state, 'd1')
        self.sweep([agy_row('d1', 7, role='qa-sdet', host='hostb')], {'t_x': SIGN_IN})
        self.assertIn(('worker-stop', 'd1', 'env=hostb'), self.orca.verbs())

    def test_local_host_falls_back_to_the_name_worker_startup_marks(self):
        own(self.state, 'd1')
        self.config = {}
        with patch.object(fw, 'worker_is_remote', return_value=False), \
                patch.object(fw.socket, 'gethostname', return_value='MiniSix.local'):
            self.sweep([agy_row('d1', 7)], {'t_x': SIGN_IN})
        self.assertTrue(agy.is_unavailable('minisix', 1000 + 3600))


class MainOrder(unittest.TestCase):
    """The earlier cold reviews failed on pass order, so pin it."""

    def test_agy_read_runs_between_the_inventory_and_the_stages_that_count_rows(self):
        source = (SCRIPT / 'fleet-watch.py').read_text()
        main = source[source.index('\ndef main('):]
        names = (
            'apply_agy_released(workers, state)',
            'gone_remote_dispatch_notices(workers, state, rpc)',
            'agy_signin_notices(\n',
            'babysit_pass(\n        config, state, workers',
            'issue_scan_pass(\n        config, state, now, workers',
            'worker_stall_pass(',
        )
        order = [main.index(name) for name in names]
        self.assertEqual(order, sorted(order))


class RestartAndHosts(AgyCase):
    def test_two_signed_out_issue_workers_on_one_host_are_both_stopped_with_one_notice(self):  # 20
        rows = [agy_row('d1', 7, terminal='t1', host='hostb'), agy_row('d2', 8, terminal='t2', host='hostb')]
        own(self.state, 'd1')
        own(self.state, 'd2')
        notices = self.sweep(rows, {'t1': SIGN_IN, 't2': SIGN_IN})
        self.assertEqual(len(notices), 1)
        stops = [v for v in self.orca.verbs() if v[0] == 'worker-stop']
        self.assertEqual(stops, [('worker-stop', 'd1', 'env=hostb'), ('worker-stop', 'd2', 'env=hostb')])
        self.assertEqual(self.state[fw.AGY_RELEASED_KEY], ['d1', 'd2'])

    def test_local_issue_row_is_stopped_and_released_without_environment(self):  # 21
        row = agy_row('d1', 7)  # no host: the coordinator's own machine
        own(self.state, 'd1')
        with patch.object(fw, 'worker_is_remote', return_value=False):
            notices = self.sweep([row], {'t_x': SIGN_IN})
        self.assertEqual(len(notices), 1)
        self.assertEqual(self.orca.verbs(), [('worker-stop', 'd1'), ('worker-release', 'd1')])
        self.assertTrue(agy.is_unavailable('hosta', 1000 + 3600))
        self.assertFalse(fw.worker_row_is_live(row))

    def test_stop_lets_the_issue_scan_restart_now_without_the_30_minute_grace(self):  # 19
        own(self.state, 'd1')
        self.state.update({
            'issue_scan_backlog_sweep_at': 1,
            'issue_scan_started': {REPO: [7]},
            'issue_scan_started_at': {REPO: {'7': 1000}},
        })
        rows = [agy_row('d1', 7, host='hostb')]
        with patch.object(fw, 'repo_for_worker', return_value=REPO):
            self.sweep(rows, {'t_x': SIGN_IN})
        self.assertNotIn('7', self.state['issue_scan_started_at'][REPO])
        edits = []
        with patch.object(fw, 'rpc', side_effect=fake_rpc):
            _n, bits = fw.issue_scan_pass(
                scan_config('/work/app'), self.state, 1000 + 60, rows, pr_fetch=lambda _r: [],
                list_issues=lambda _r: [], list_claimed=lambda _r: [{'number': 7}],
                gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda _c: 0, act=lambda c: edits.append(c) or 0)
        self.assertIn('issue_restart=7:orphaned', bits)
        self.assertTrue(any('ready-for-agent' in ' '.join(e) for e in edits), edits)
        self.assertNotIn(7, self.state['issue_scan_started'][REPO])

    def test_without_the_stop_the_issue_waits_out_the_grace(self):
        self.state.update({
            'issue_scan_backlog_sweep_at': 1,
            'issue_scan_started': {REPO: [7]},
            'issue_scan_started_at': {REPO: {'7': 1000}},
        })
        with patch.object(fw, 'rpc', side_effect=fake_rpc):
            _n, bits = fw.issue_scan_pass(
                scan_config('/work/app'), self.state, 1060, [], pr_fetch=lambda _r: [],
                list_issues=lambda _r: [], list_claimed=lambda _r: [{'number': 7}],
                gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda _c: 0, act=lambda _c: 0)
        self.assertNotIn('issue_restart=7:orphaned', bits)


if __name__ == '__main__':
    unittest.main()
