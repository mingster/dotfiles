"""#1832: a signed out antigravity issue start undoes itself in worker-startup.sh and exits 10; the issue scan holds it."""
import copy
import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_agy_exit', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402
from test_fleet_watch_park import scan_config as park_config  # noqa: E402
from test_fleet_watch_scan import pr as plain_pr  # noqa: E402
from test_fleet_watch_triage import NOW, pick as triage_pick  # noqa: E402

ENV = fw.AGY_SIGNIN_ENV
HELD_NOTIFY = 'agy-signin: host=host-a notify'
HELD_KNOWN = 'agy-signin: host=host-a known'


def held(reason):
    return fw.BabysitStartResult(10, reason)


def run_issue_scan(start, issues=None, state=None, act=None, prs=None):
    state = {'issue_scan_backlog_sweep_at': NOW, 'work_order_supply_at': NOW} if state is None else state
    calls = [] if act is None else act
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        notices, bits = fw.issue_scan_pass(
            park_config('/work/app'), state, NOW, [], pr_fetch=lambda _r: list(prs or []),
            list_issues=lambda _r: list(issues if issues is not None else [row(1)]),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=start, act=lambda cmd: calls.append(cmd) or 0,
            repo_id_lookup=lambda _h, _r: 'repo-id', pick_fn=triage_pick, list_backlog=lambda _r: 0,
        )
    return notices, bits, state, calls


def urgent(notices):
    return [n for n in notices if isinstance(n, fw.Urgent)]


class IssueScanHoldsExit10(unittest.TestCase):
    def test_28_exit_10_changes_nothing(self):
        before = {'issue_scan_backlog_sweep_at': NOW, 'work_order_supply_at': NOW}
        state = copy.deepcopy(before)
        with patch.object(fw, 'defer_issue') as defer, patch.object(fw, 'park_failure') as park, \
                patch.object(fw, 'remember_started_dispatch') as remember, patch.object(fw, 'count_started') as counted:
            notices, bits, state, acts = run_issue_scan(lambda _c: held(HELD_KNOWN), state=state)
        self.assertIn('issue_start_agy_signin=1', bits)
        self.assertEqual([], acts, 'no gh label edit')
        for fn in (defer, park, remember, counted):
            fn.assert_not_called()
        self.assertEqual([], urgent(notices))
        self.assertFalse(any(b.startswith(('issue_start_fail', 'issue_start_deferred', 'issue_start=')) for b in bits), bits)
        self.assertEqual({}, state.get('issue_scan_started_at') or {})
        self.assertEqual({}, state.get('issue_scan_deferrals') or {})
        self.assertEqual({}, state.get('parked') or {})
        self.assertEqual(before['work_order_supply_at'], state['work_order_supply_at'])

    def test_28_never_counts_toward_the_deferral_escalation(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'work_order_supply_at': NOW}
        for _ in range(5):
            notices, bits, state, _acts = run_issue_scan(lambda _c: held(HELD_KNOWN), state=state)
            self.assertEqual([], notices)
        self.assertEqual({}, {k: v for k, v in state.items() if 'defer' in k and v})

    def test_29_notify_gives_one_urgent_notice_and_known_gives_none(self):
        notices, _bits, _s, _a = run_issue_scan(lambda _c: held(HELD_NOTIFY))
        found = urgent(notices)
        self.assertEqual(1, len(found))
        self.assertIn('host=host-a', found[0])
        self.assertIn('script/agy-signin-host.sh host-a (not over ssh)', found[0])
        notices, _bits, _s, _a = run_issue_scan(lambda _c: held(HELD_KNOWN))
        self.assertEqual([], urgent(notices))

    def test_29_exit_10_with_no_line_is_still_held_without_a_notice(self):
        notices, bits, _s, acts = run_issue_scan(lambda _c: held(''))
        self.assertIn('issue_start_agy_signin=1', bits)
        self.assertEqual([], urgent(notices))
        self.assertEqual([], acts)

    def test_29_two_issue_starts_one_pass_one_notice(self):
        results = iter([held(HELD_NOTIFY), held(HELD_KNOWN)])
        notices, bits, _s, _a = run_issue_scan(lambda _c: next(results), issues=[row(1), row(2)])
        self.assertEqual(1, len(urgent(notices)))
        self.assertEqual(2, sum(b.startswith('issue_start_agy_signin=') for b in bits))

    def test_exit_10_from_a_start_that_did_not_print_the_line_is_not_a_failure(self):
        _n, bits, state, acts = run_issue_scan(lambda _c: held('something else'))
        self.assertIn('issue_start_agy_signin=1', bits)
        self.assertEqual({}, state.get('parked') or {})
        self.assertEqual([], acts)


class OnlyIssueStartsCarryTheVariable(unittest.TestCase):
    def test_30_issue_start_sets_it_and_clears_it_afterwards(self):
        seen = []

        def start(command):
            seen.append(os.environ.get(ENV))
            return 0

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV, None)
            run_issue_scan(start)
            self.assertNotIn(ENV, os.environ)
        self.assertEqual(['exit'], seen)

    def test_30_an_inherited_value_is_put_back(self):
        with patch.dict(os.environ, {ENV: 'keep'}):
            run_issue_scan(lambda _c: 0)
            self.assertEqual('keep', os.environ[ENV])

    def test_30_variable_is_cleared_when_the_start_raises(self):
        def boom(_command):
            raise RuntimeError('start failed')

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV, None)
            with self.assertRaises(RuntimeError):
                with fw.agy_signin_exit_env():
                    boom(['x'])
            self.assertNotIn(ENV, os.environ)

    def test_30_rework_start_does_not_carry_it(self):
        seen = []
        head = 'a' * 40
        prs = [plain_pr(1, head=head, comments=[{'body': 'Checks: FAIL head=%s' % head}])]

        def start(command):
            seen.append((command[command.index('--title') + 1], os.environ.get(ENV)))
            return 0

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop(ENV, None)
            run_issue_scan(start, issues=[], prs=prs, state={'issue_scan_backlog_sweep_at': 1})
        self.assertTrue(seen, 'a rework start ran')
        self.assertEqual([None] * len(seen), [value for _t, value in seen])

    def test_30_exit_10_is_not_a_babysit_deferred_exit(self):
        self.assertNotIn(10, fw.BABYSIT_DEFERRED_EXITS)

    def test_agy_signin_notices_still_marks_by_screen(self):
        # agy_signin_notices is unchanged: it still reads running antigravity screens and sends the notice.
        self.assertTrue(callable(fw.agy_signin_notices))


class StoppedRowFixtures(unittest.TestCase):
    """The rows Orca lists after worker-stop and worker-release, captured on host-a (Orca 1.4.274): one local, one remote
    on host-b. Neither is live and neither holds a seat, so classify_worker and worker_row_is_live need no change."""

    CONFIG = {'host_caps': {'host-a': 3, 'host-b': 5}, 'local_host': 'host-a', 'runs': []}

    def rows(self):
        for name in ('local', 'remote'):
            path = Path(__file__).parent / 'fixtures' / ('agy-signin-stopped-%s.json' % name)
            fixture = json.loads(path.read_text())
            for key in ('worker_list_full_row_after_release', 'worker_list_full_row_after_60s'):
                if key in fixture:
                    yield '%s/%s' % (name, key), dict(fixture[key], _task_title='#1|builder')

    def test_22_no_seat_in_admit_alerts_and_the_seat_report(self):
        for label, row in self.rows():
            with self.subTest(label):
                self.assertFalse(fw.worker_row_is_live(row))
                occupies, info, unknown = fw.classify_worker(row)
                self.assertFalse(occupies, info)
                self.assertFalse(unknown)
                for host in ('host-a', 'host-b'):
                    receipt = fw.admit(host, self.CONFIG, workers=[row])
                    self.assertEqual(0, receipt.get('occupied'), receipt)
                report = fw.fleet_seat_report(self.CONFIG, workers=[row])
                for host, entry in report.items():
                    self.assertEqual((0, 0, 0), (entry['occupied'], entry['live_count'], entry['retained_count']), host)
                self.assertEqual([], fw.alerts(self.CONFIG, {'failed': []}, 1e9, [], [row], lambda *_a: False))

    def test_34_issue_has_no_live_dispatch_and_the_title_is_not_live(self):
        for label, row in self.rows():
            with self.subTest(label):
                self.assertFalse(fw.issue_has_live_dispatch([row], 1))
                self.assertFalse(fw.live_start_title(['--title', '#1|builder'], [row]))

    def test_35_no_dead_dispatch_notice_whether_the_terminal_is_listed_or_gone(self):
        for label, row in self.rows():
            for listed in ([], [{'handle': row.get('agentTerminalHandle') or 'x'}]):
                with self.subTest(label, listed=len(listed)):
                    calls = []

                    def rpc_call(*args):
                        calls.append(args)
                        return {'terminals': listed}

                    notices = fw.gone_remote_dispatch_notices([row], {}, rpc_call)
                    self.assertEqual([], notices)
                    self.assertEqual([], calls, 'a stopped row is not read at all')

    def test_36_stall_signal_and_nudge_passes_do_not_see_it_as_live(self):
        for label, row in self.rows():
            with self.subTest(label):
                def rpc_call(*args):
                    raise AssertionError('a stopped row must not be read or written: %r' % (args,))

                state = {}
                fw.worker_stall_pass(self.CONFIG, state, 1e9, [row], {}, rpc_call)
                fw.worker_signal_pass(self.CONFIG, state, 1e9, [row], {})
                fw.unread_nudge_pass(state, 1e9, [row], {}, [], rpc_call)
                self.assertEqual({}, {k: v for k, v in state.items() if v})


if __name__ == '__main__':
    unittest.main()
