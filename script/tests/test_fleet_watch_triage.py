"""Idle seats with no ready issue start one triage worker per repo, at most once per interval."""
import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch_triage', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402

NOW = 100000.0


def pick(_role, avoid_family=None):
    return {'selected': {'provider': 'claude', 'model': 'opus'}}


def run(issues, backlog, state=None, interval_hours=None, occupied=0, order=None, workers=None, now=NOW, notices_out=None,
        go_live_date=None):
    starts = []
    config = scan_config('/work/app')
    if go_live_date is not None:
        config['go_live_date'] = go_live_date
    if order is not None:
        config['work_order'] = order
    if interval_hours is not None:
        config['issue_scan']['triage_interval_hours'] = interval_hours
    state = {'issue_scan_backlog_sweep_at': NOW} if state is None else state

    def start(command):
        starts.append(command)
        return 0

    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            config, state, now, workers or [], pr_fetch=lambda _r: [], list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': occupied},
            start_worker=start, act=lambda _c: 0, repo_id_lookup=lambda _h, _r: 'repo-id',
            pick_fn=pick, list_backlog=lambda _r: backlog,
        )
    triage = [c for c in starts if 'triage-architect-pm' in c]
    if notices_out is not None:
        notices_out.extend(_n)
    return triage, bits, state


class TriageWorker(unittest.TestCase):
    def test_starts_when_idle_with_backlog(self):
        triage, bits, state = run([], backlog=3)
        self.assertEqual(len(triage), 1, bits)
        self.assertIn('triage_start=3', bits)
        self.assertEqual(triage[0][triage[0].index('--agent') + 1], 'claude')
        self.assertEqual(list(state['issue_scan_triage_at'].values()), [NOW])

    def test_skips_with_no_backlog(self):
        triage, bits, _state = run([], backlog=0)
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_no_backlog', bits)

    def test_skips_when_a_ready_issue_started(self):
        triage, bits, _state = run([row(1)], backlog=3)
        self.assertEqual(triage, [])
        self.assertIn('issue_start=1', bits)

    def test_respects_the_interval(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'issue_scan_triage_at': {scan_config('/w')['issue_scan']['repos'][0]: NOW - 3600}}
        triage, bits, _state = run([], backlog=3, state=state)
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_recent', bits)
        state['issue_scan_triage_at'] = {k: NOW - 7300 for k in state['issue_scan_triage_at']}
        triage, _bits, _state = run([], backlog=3, state=state)
        self.assertEqual(len(triage), 1)

    def live(self, n, title='#1|fullstack-dev'):
        return [{'dispatchId': 'd%d' % i, 'dispatchStatus': 'running', 'terminalState': 'active', '_task_title': title,
                 'projection': {'liveness': {'verdict': 'live'}, 'host': {'id': 'local'}}} for i in range(n)]

    def test_under_min_active_triages_now_and_tells_the_coordinator(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'issue_scan_triage_at': {scan_config('/w')['issue_scan']['repos'][0]: NOW - 60}}
        notices = []
        triage, _bits, _state = run([], backlog=3, state=state, order={'min_active': 3, 'target_workers': 8},
                                    workers=self.live(2), notices_out=notices)
        self.assertEqual(len(triage), 1)
        self.assertIn('work order: 2 active, grill backlog', notices)

    def test_at_min_active_the_interval_still_holds(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'issue_scan_triage_at': {scan_config('/w')['issue_scan']['repos'][0]: NOW - 60}}
        notices = []
        triage, bits, _state = run([], backlog=3, state=state, order={'min_active': 3}, workers=self.live(3),
                                   notices_out=notices)
        self.assertEqual(triage, [])
        self.assertNotIn('work order: 3 active, grill backlog', notices)

    def test_no_work_before_19_00_sends_one_line_a_day(self):
        morning = 1_700_000_000.0  # 2023-11-14 22:13 UTC = 06:13 Asia/Taipei
        state, notices = {'issue_scan_backlog_sweep_at': morning}, []
        run([], backlog=0, state=state, order={}, now=morning, notices_out=notices)
        self.assertEqual(notices.count('work order: no work left, start the staging deploy and regression now'), 1)
        again = []
        run([], backlog=0, state=state, order={}, now=morning + 600, notices_out=again)
        self.assertNotIn('work order: no work left, start the staging deploy and regression now', again)

    def test_no_work_line_is_silent_after_19_00_or_while_building_or_unconfigured(self):
        line = 'work order: no work left, start the staging deploy and regression now'
        evening = 1_700_000_000.0 + 14 * 3600  # 20:13 Asia/Taipei
        for kwargs in ({'order': {}, 'now': evening}, {'order': {}, 'workers': self.live(1), 'now': 1_700_000_000.0},
                       {'order': None, 'now': 1_700_000_000.0}):
            notices = []
            run([], backlog=0, state={'issue_scan_backlog_sweep_at': kwargs['now']}, notices_out=notices, **kwargs)
            self.assertNotIn(line, notices, kwargs)

    def test_fill_stops_at_target_workers(self):
        notices = []
        triage, bits, _state = run([row(1), row(2), row(3)], backlog=0, order={'min_active': 3, 'target_workers': 2},
                                   workers=self.live(2), notices_out=notices)
        self.assertIn('work_order_target=2', bits)
        self.assertNotIn('issue_start=1', bits)

    def test_generated_spec_passes_brief_lint(self):
        triage, _bits, _state = run([], backlog=3)
        spec = Path(triage[0][triage[0].index('--spec') + 1])
        repo = Path(__file__).resolve().parents[2]
        result = subprocess.run(['bash', str(repo / 'script/brief-lint.sh'), str(spec), str(repo)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Setup: none', spec.read_text(encoding='utf-8'))


class KeepTargetUntilGoLive(unittest.TestCase):
    """work_order.keep_target_until_go_live holds the fleet at target_workers before go live (#1655)."""
    KEEP = {'min_active': 3, 'target_workers': 8, 'keep_target_until_go_live': True}

    def recent_state(self):
        return {'issue_scan_backlog_sweep_at': NOW, 'issue_scan_triage_at': {scan_config('/w')['issue_scan']['repos'][0]: NOW - 60}}

    def live(self, n):
        return TriageWorker.live(self, n)

    def test_switch_off_keeps_the_triage_interval(self):
        order = dict(self.KEEP, keep_target_until_go_live=False)
        triage, bits, _state = run([], backlog=3, state=self.recent_state(), order=order, workers=self.live(4),
                                   go_live_date='2099-01-01')
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_recent', bits)

    def test_before_go_live_four_live_triages_without_waiting(self):
        notices = []
        triage, bits, _state = run([], backlog=3, state=self.recent_state(), order=self.KEEP, workers=self.live(4),
                                   go_live_date='2099-01-01', notices_out=notices)
        self.assertEqual(len(triage), 1, bits)
        self.assertNotIn('work order: 4 active, grill backlog', notices)

    def test_at_target_the_interval_holds(self):
        triage, bits, _state = run([], backlog=3, state=self.recent_state(), order=self.KEEP, workers=self.live(8),
                                   go_live_date='2099-01-01')
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_recent', bits)

    def test_on_or_after_go_live_the_switch_does_nothing(self):
        for go_live in ('1970-01-02', '1970-01-01', 'soon', None):  # NOW is 1970-01-02 in Asia/Taipei
            triage, bits, _state = run([], backlog=3, state=self.recent_state(), order=self.KEEP, workers=self.live(4),
                                       go_live_date=go_live)
            self.assertEqual(triage, [], go_live)
            self.assertIn('triage_skip_recent', bits)

    def test_host_cap_still_holds(self):
        triage, bits, _state = run([], backlog=3, state=self.recent_state(), order=self.KEEP, workers=self.live(4),
                                   go_live_date='2099-01-01', occupied=4)
        self.assertEqual(triage, [])
        self.assertIn('triage_skip_no_seat', bits)

    def test_status_line_at_most_once_an_hour_and_only_after_a_start(self):
        config = {'work_order': self.KEEP, 'go_live_date': '2099-01-01'}
        state = {}
        self.assertIsNone(fw.work_order_status_notice(config, state, NOW, self.live(4), 0))
        self.assertEqual(fw.work_order_status_notice(config, state, NOW, self.live(4), 2),
                         'work order: 4 of 8 live, started 2')
        self.assertIsNone(fw.work_order_status_notice(config, state, NOW + 3599, self.live(5), 1))
        self.assertEqual(fw.work_order_status_notice(config, state, NOW + 3600, self.live(5), 1),
                         'work order: 5 of 8 live, started 1')
        self.assertIsNone(fw.work_order_status_notice(config, {}, NOW, self.live(8), 1))
        off = {'work_order': dict(self.KEEP, keep_target_until_go_live=False), 'go_live_date': '2099-01-01'}
        self.assertIsNone(fw.work_order_status_notice(off, {}, NOW, self.live(4), 2))


class CoordinatorHandle(unittest.TestCase):
    """The scheduled run has no ORCA_TERMINAL_HANDLE; issue scan starts get it from issue_scan.from_terminal (#1655)."""

    def handles(self, issues, backlog):
        seen = []

        def start(command):
            seen.append((command[command.index('--name') + 1] if '--name' in command else command[-1],
                         fw.os.environ.get('ORCA_TERMINAL_HANDLE'), '--from' in command))
            return 0

        config = scan_config('/work/app')
        with patch.dict(fw.os.environ, {}, clear=False), patch.object(fw, 'rpc', side_effect=fake_rpc):
            fw.os.environ.pop('ORCA_TERMINAL_HANDLE', None)
            fw.issue_scan_pass(
                config, {'issue_scan_backlog_sweep_at': NOW}, NOW, [], pr_fetch=lambda _r: [],
                list_issues=lambda _r: list(issues), gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0}, start_worker=start, act=lambda _c: 0,
                repo_id_lookup=lambda _h, _r: 'repo-id', pick_fn=pick, list_backlog=lambda _r: backlog,
            )
            self.assertIsNone(fw.os.environ.get('ORCA_TERMINAL_HANDLE'))
        return seen

    def test_issue_start_gets_the_handle_without_from(self):
        seen = self.handles([row(1)], backlog=0)
        self.assertTrue(seen)
        self.assertEqual({(handle, has_from) for _name, handle, has_from in seen}, {('term_coord', False)})

    def test_triage_start_gets_the_handle(self):
        seen = self.handles([], backlog=3)
        self.assertIn(('triage-architect-pm', 'term_coord', False), seen)


if __name__ == '__main__':
    unittest.main()
