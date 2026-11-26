"""#1957: work_order.max_workers is a fleet wide ceiling on live workers. Unset keeps today's behaviour."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fleet_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fleet_env)

APP = 'owner/app'
NOW = 1_700_000_000.0
BODY = '## Acceptance criteria\n- x'
PICK = lambda _role, **_kw: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731
BIG_CODE = [{'path': 'script/x.py', 'additions': 300, 'deletions': 5}]


def ready(number):
    return {
        'number': number, 'title': 'ticket %d' % number, 'body': BODY, 'comments': [],
        'labels': [{'name': 'ready-for-agent'}, {'name': 'P2'}], 'createdAt': '2026-01-01T00:00:00Z',
    }


def live(n):
    return [{'dispatchId': 'ctx_%d' % i, 'state': 'running', 'name': 'w%d' % i} for i in range(n)]


def config(max_workers=None, target=8, cap=20):
    order = {'min_active': 3, 'target_workers': target}
    if max_workers is not None:
        order['max_workers'] = max_workers
    return {
        'issue_scan': {
            'enabled': True, 'repos': [APP], 'run': 'run_x', 'from_terminal': 'term_coord', 'host': 'local',
            'agent': 'cursor', 'model': 'm1', 'rework_agent': 'cursor', 'rework_model': 'm1',
            'repo_roots': {APP: '/tmp/app'}, 'backlog_sweep_interval_seconds': 10 ** 9,
        },
        'host_caps': {'local': cap},
        'work_order': order,
    }


def begin_pass(case):
    # main() opens a pass; the ceiling counts this pass's starts through it.
    fw.begin_pass_counts()
    case.addCleanup(setattr, fw, '_PASS', None)


class Base(unittest.TestCase):
    def setUp(self):
        fleet_env.guard_gh_writes(self)
        begin_pass(self)
        for name, value in (('run_gh', 0), ('brief_lint_missing', [])):
            p = patch.object(fw, name, return_value=value)
            p.start()
            self.addCleanup(p.stop)

    def scan(self, cfg, issues, workers, state=None):
        starts = []
        notices, log = fw.issue_scan_pass(
            cfg, state if state is not None else {'issue_scan_backlog_sweep_at': NOW}, NOW, workers,
            list_issues=lambda repo: issues.get(repo, []), pr_fetch=lambda _repo: [],
            gate_check=lambda _cfg: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': len(workers)},
            start_worker=lambda command: (starts.append(command), 0)[1],
            inventory_ok=True, start_detached=lambda _command, extra_env=None: 0)
        return notices, log, starts


class Settings(unittest.TestCase):
    def test_reads_a_positive_int_and_ignores_the_rest(self):
        self.assertEqual(fw.work_order_max_workers({'work_order': {'max_workers': 8}}), 8)
        for bad in (None, 0, -1, 'x', True):
            self.assertIsNone(fw.work_order_max_workers({'work_order': {'max_workers': bad}}), bad)
        self.assertIsNone(fw.work_order_max_workers({'work_order': {}}))
        self.assertIsNone(fw.work_order_max_workers({}))


class IssueScan(Base):
    def test_at_max_workers_the_scan_starts_nothing_and_says_so(self):
        issues = {APP: [ready(1), ready(2)]}
        notices, log, starts = self.scan(config(max_workers=8, target=10), issues, live(8))
        self.assertEqual(starts, [])
        self.assertEqual(sum(1 for b in log if b.endswith(':max_workers')), 2, log)
        gap = [n for n in notices if str(n).startswith('fill gap:')]
        self.assertEqual(gap, ['fill gap: 8 of 10 live, 2 ready issue(s) not started (max_workers x2), at max_workers 8'])
        self.assertFalse([n for n in notices if isinstance(n, fw.Urgent)])

    def test_the_scan_stops_once_its_own_starts_reach_the_ceiling(self):
        issues = {APP: [ready(n) for n in range(1, 5)]}
        notices, log, starts = self.scan(config(max_workers=8, target=10), issues, live(6))
        self.assertEqual(len(starts), 2)
        self.assertEqual([b for b in log if b.startswith('issue_start=')], ['issue_start=1', 'issue_start=2'])
        self.assertIn('fill gap: 8 of 10 live, 2 ready issue(s) not started (max_workers x2), at max_workers 8', notices)

    def test_waiting_at_the_ceiling_never_escalates(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        for _ in range(4):
            notices, _log, _starts = self.scan(config(max_workers=8), {APP: [ready(1)]}, live(8), state=state)
            self.assertFalse([n for n in notices if isinstance(n, fw.Urgent)], notices)

    def test_no_max_workers_key_behaves_as_today(self):
        issues = {APP: [ready(n) for n in range(1, 4)]}
        _n, log_a, starts_a = self.scan(config(target=10), issues, live(8))
        self.assertEqual(len(starts_a), 3)
        self.assertFalse([b for b in log_a if 'max_workers' in b])

    def test_supply_waits_at_the_ceiling(self):
        bits, started = fw.work_order_try_supply(
            config(max_workers=8, target=10), {}, NOW, [APP], 0, 'local', {'admitted': True}, 0, 0, live(8),
            start_worker=lambda _c: self.fail('started'))
        self.assertEqual((bits, started), (['supply_max_workers'], 0))


def pr(number, review=True):
    head = ('%x' % number) * 40
    comments = [{'body': 'Review: PASS head=%s' % head}] if review else []
    return {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head[:40], 'headRefName': 'b%d' % number,
        'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
        'comments': comments, 'labels': [], 'mergeable': 'MERGEABLE', 'files': BIG_CODE,
        'body': '## Self-check\n$ bash script/checks-local.sh\nexit 0\nBuilder: agent=claude model=sonnet',
    }


class Babysit(unittest.TestCase):
    def setUp(self):
        begin_pass(self)

    def run_pass(self, rows, workers, max_workers=8):
        starts = []
        with tempfile.TemporaryDirectory() as root:
            cfg = config(max_workers=max_workers)
            cfg['issue_scan']['repos'] = [APP]
            cfg['issue_scan']['repo_roots'] = {APP: root}
            cfg['babysit'] = {'repos': [APP], 'startup': '/bin/true', 'per_pass_cap': 4}
            _n, lines, log = fw.babysit_pass(
                cfg, {}, workers, pr_fetch=lambda _r: rows,
                start_worker=lambda cmd: (starts.append(cmd), fw.BabysitStartResult(0))[1],
                pick=PICK, owner_check=lambda _pr, **_kw: None,
            )
        return starts, lines, log

    def test_a_review_pass_verifier_takes_one_seat_over_the_ceiling(self):
        starts, lines, _log = self.run_pass([pr(1)], live(8))
        self.assertEqual(len(starts), 1, lines)

    def test_but_not_two(self):
        starts, lines, log = self.run_pass([pr(1)], live(9))
        self.assertEqual(starts, [], lines)
        self.assertIn('max_workers=1', log)
        self.assertTrue(any('max-workers' in l for l in lines), lines)

    def test_only_one_review_pass_verifier_goes_over_per_pass(self):
        starts, lines, _log = self.run_pass([pr(1), pr(2)], live(8))
        self.assertEqual(len(starts), 1, lines)

    def test_no_max_workers_key_starts_as_today(self):
        starts, lines, _log = self.run_pass([pr(1)], live(12), max_workers=None)
        self.assertEqual(len(starts), 1, lines)


HOUR = 1_795_687_200  # 2026-11-26T10:00:00Z
FIXTURE_LOG = [
    '2026-11-26T09:59:00Z pass ok 10.0s; live=20 started=0 refused=0 parked=0 failed=9 sent=0 send_failed=0 refused_reasons=',
    '2026-11-26T10:00:05Z pass ok 10.0s; live=6; start_unknown=ctx_u1 started=1 refused=0 parked=0 failed=1 sent=0 send_failed=0 refused_reasons=',
    '2026-11-26T10:05:05Z pass ok 10.0s; live=8; start_unknown=ctx_u1; dup_workers=ctx_d1; scan issue_start=3 started=1 refused=0 parked=0 failed=0 sent=0 send_failed=0 refused_reasons=',
    '2026-11-26T10:10:05Z closed terminal term_x',
    '2026-11-26T10:10:06Z pass ok 10.0s; live=7; dup_workers=ctx_d1,ctx_d2 started=0 refused=1 parked=0 failed=2 sent=0 send_failed=0 refused_reasons=max_workers:1',
    '2026-11-26T11:00:01Z pass ok 10.0s; live=30 started=0 refused=0 parked=0 failed=5 sent=0 send_failed=0 refused_reasons=',
]


def merged(number, created, merged_at, receipts):
    return {'number': number, 'createdAt': created, 'mergedAt': merged_at,
            'comments': [{'body': '%s head=%s' % (r, 'a' * 40)} for r in receipts]}


FIXTURE_PRS = [
    merged(1, '2026-11-26T08:00:00Z', '2026-11-26T10:00:00Z', ['Review: PASS', 'Verdict: PASS']),
    merged(2, '2026-11-26T09:00:00Z', '2026-11-26T10:30:00Z', ['Review: FAIL', 'Review: PASS', 'Verdict: PASS']),
    merged(3, '2026-11-26T05:00:00Z', '2026-11-26T10:59:59Z', ['Review: PASS', 'Verdict: FAIL', 'Verdict: PASS']),
    merged(4, '2026-11-26T05:00:00Z', '2026-11-26T11:00:00Z', ['Review: PASS']),  # next hour
]


class HourlyMetrics(unittest.TestCase):
    def test_fixture_log_gives_the_expected_numbers(self):
        line = fw.hourly_metrics_line(FIXTURE_LOG, FIXTURE_PRS, HOUR)
        self.assertEqual(line, (
            'metrics hour=2026-11-26T10 merged_per_h=3 review_first_pass=2/3 verdict_first_pass=2/3 '
            'wasted_starts=6 (start_unknown=1 duplicate=2 failed_dispatch=3) '
            'median_open_to_merge_h=2.0 mean_live=7.0 cost: n/a'))

    def test_an_empty_hour_says_n_a(self):
        self.assertEqual(fw.hourly_metrics_line([], [], HOUR), (
            'metrics hour=2026-11-26T10 merged_per_h=0 review_first_pass=n/a verdict_first_pass=n/a '
            'wasted_starts=0 (start_unknown=0 duplicate=0 failed_dispatch=0) '
            'median_open_to_merge_h=n/a mean_live=n/a cost: n/a'))

    def test_logs_once_per_hour_for_the_hour_that_ended(self):
        cfg = {'babysit': {'repos': [APP]}}
        state = {}
        fetched = []
        fetch = lambda repo, since: (fetched.append((repo, since)), FIXTURE_PRS)[1]  # noqa: E731
        with patch.object(fw, 'log_fleet_watch') as logged:
            self.assertIsNone(fw.maybe_log_hourly_metrics(cfg, state, HOUR + 30, fetch=fetch, log_lines=FIXTURE_LOG))
            self.assertIsNone(fw.maybe_log_hourly_metrics(cfg, state, HOUR + 1800, fetch=fetch, log_lines=FIXTURE_LOG))
            line = fw.maybe_log_hourly_metrics(cfg, state, HOUR + 3605, fetch=fetch, log_lines=FIXTURE_LOG)
            self.assertIsNone(fw.maybe_log_hourly_metrics(cfg, state, HOUR + 3900, fetch=fetch, log_lines=FIXTURE_LOG))
        self.assertTrue(line.startswith('metrics hour=2026-11-26T10 merged_per_h=3'), line)
        logged.assert_called_once_with(line)
        self.assertEqual(fetched, [(APP, HOUR)])

    def test_digest_prints_the_last_twelve_metric_lines(self):
        lines = ['2026-11-26T%02d:00:01Z metrics hour=2026-11-26T%02d merged_per_h=1' % (h, h) for h in range(14)]
        lines.insert(3, '2026-11-26T03:00:02Z pass ok 1.0s; live=3')
        digest = fw.metrics_digest(lines, 12)
        self.assertEqual(len(digest), 12)
        self.assertTrue(digest[0].endswith('hour=2026-11-26T02 merged_per_h=1'))
        self.assertTrue(digest[-1].endswith('hour=2026-11-26T13 merged_per_h=1'))

    def test_digest_flag_reads_the_log(self):
        import os
        import subprocess
        import sys
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'fw.log'
            log.write_text('\n'.join(FIXTURE_LOG + ['2026-11-26T11:00:02Z ' + fw.hourly_metrics_line(FIXTURE_LOG, FIXTURE_PRS, HOUR)]) + '\n')
            out = subprocess.run(
                [sys.executable, str(Path(fw.__file__)), '--metrics-digest', '12'], capture_output=True, text=True,
                env=dict(os.environ, FLEET_WATCH_LOG_PATH=str(log)), timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), ['2026-11-26T11:00:02Z metrics hour=2026-11-26T10 merged_per_h=3 '
                                                   'review_first_pass=2/3 verdict_first_pass=2/3 wasted_starts=6 '
                                                   '(start_unknown=1 duplicate=2 failed_dispatch=3) '
                                                   'median_open_to_merge_h=2.0 mean_live=7.0 cost: n/a'])

    def test_pass_parts_name_unknown_and_duplicate_dispatches(self):
        workers = [
            {'dispatchId': 'ctx_a', 'state': 'running', 'name': '#5|qa-sdet'},
            {'dispatchId': 'ctx_b', 'state': 'running', 'name': '#5|qa-sdet'},
            {'dispatchId': 'ctx_c', 'state': 'running', 'name': '#5|fullstack-dev'},
            {'dispatchId': 'ctx_u', 'status': 'start_unknown', 'name': '#6|fullstack-dev'},
        ]
        parts = fw.pass_waste_parts(workers)
        self.assertEqual(parts[1:], ['start_unknown=ctx_u', 'dup_workers=ctx_b'])
        self.assertTrue(parts[0].startswith('live='))


if __name__ == '__main__':
    unittest.main()
