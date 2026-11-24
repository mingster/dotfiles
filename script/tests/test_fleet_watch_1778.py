"""#1778: fill target_workers, a dotfiles issue that cannot start does not block, and stalls go to elon."""
import importlib.util
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
DOTS = 'owner/dotfiles'
NOW = 1_700_000_000.0
BODY = '## Acceptance criteria\n- x'


def ready(number, priority='P2'):
    return {
        'number': number, 'title': 'ticket %d' % number, 'body': BODY, 'comments': [],
        'labels': [{'name': 'ready-for-agent'}, {'name': priority}], 'createdAt': '2026-01-01T00:00:00Z',
    }


def live(n):
    return [{'dispatchId': 'ctx_%d' % i, 'state': 'running', 'name': 'w%d' % i} for i in range(n)]


def config(**extra):
    cfg = {
        'issue_scan': {
            'enabled': True, 'repos': [APP, DOTS], 'run': 'run_x', 'from_terminal': 'term_coord', 'host': 'local',
            'agent': 'cursor', 'model': 'm1', 'rework_agent': 'cursor', 'rework_model': 'm1',
            'repo_roots': {APP: '/tmp/app', DOTS: '/tmp/dotfiles'}, 'backlog_sweep_interval_seconds': 10 ** 9,
        },
        'host_caps': {'local': 8},
        'work_order': {'min_active': 3, 'target_workers': 10},
    }
    cfg.update(extra)
    return cfg


class Base(unittest.TestCase):
    def setUp(self):
        fleet_env.guard_gh_writes(self)
        gh = patch.object(fw, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)
        lint = patch.object(fw, 'brief_lint_missing', return_value=[])
        lint.start()
        self.addCleanup(lint.stop)

    def scan(self, cfg, state, issues, workers=None, prs=None, now=NOW, admit=None, **kw):
        starts = []

        def start_worker(command):
            starts.append(command)
            return 0

        notices, log = fw.issue_scan_pass(
            cfg, state, now, workers or [],
            list_issues=lambda repo: issues.get(repo, []), pr_fetch=lambda repo: (prs or {}).get(repo, []),
            gate_check=lambda _cfg: True,
            admit_fn=admit or (lambda _host, _cfg, _workers: {'admitted': True, 'occupied': len(workers or [])}),
            start_worker=start_worker, inventory_ok=True, start_detached=lambda _command, extra_env=None: 0, **kw)
        return notices, log, starts


class FillTarget(Base):
    def test_five_live_target_ten_starts_up_to_the_cap_and_tells_elon_the_gap(self):
        issues = {APP: [ready(n) for n in range(1, 7)]}
        notices, log, starts = self.scan(config(), {'issue_scan_backlog_sweep_at': NOW}, issues, workers=live(5))
        self.assertEqual(len(starts), 3)  # cap 8, 5 live
        self.assertEqual([b for b in log if b.startswith('issue_start=')], ['issue_start=1', 'issue_start=2', 'issue_start=3'])
        self.assertEqual(sum(1 for b in log if b.startswith('issue_deferred=') and b.endswith(':host_cap')), 3)
        gap = [n for n in notices if str(n).startswith('fill gap:')]
        self.assertEqual(gap, ['fill gap: 8 of 10 live, 3 ready issue(s) not started (host_cap x3), elon tops up by hand'])

    def test_no_gap_line_when_every_ready_issue_starts(self):
        cfg = config(host_caps={'local': 20})
        notices, log, _starts = self.scan(cfg, {'issue_scan_backlog_sweep_at': NOW}, {APP: [ready(1), ready(2)]}, workers=live(5))
        self.assertEqual([b for b in log if b.startswith('issue_start=')], ['issue_start=1', 'issue_start=2'])
        self.assertFalse([n for n in notices if str(n).startswith('fill gap:')])

    def test_no_gap_line_without_a_work_order_block(self):
        cfg = config()
        del cfg['work_order']
        notices, _log, _starts = self.scan(cfg, {'issue_scan_backlog_sweep_at': NOW}, {APP: [ready(n) for n in range(1, 7)]}, workers=live(5))
        self.assertFalse([n for n in notices if str(n).startswith('fill gap:')])

    def test_local_admission_refused_with_no_other_host_still_tells_elon(self):
        refuse = lambda _h, _c, _w: {'admitted': False, 'occupied': 5, 'reason': 'host_cap 5 of 5'}  # noqa: E731
        notices, log, starts = self.scan(
            config(host_caps={'local': 5}), {'issue_scan_backlog_sweep_at': NOW}, {APP: [ready(1), ready(2)]},
            workers=live(5), admit=refuse)
        self.assertEqual(starts, [])
        gap = [n for n in notices if str(n).startswith('fill gap:')]
        self.assertEqual(len(gap), 1)
        self.assertIn('5 of 10 live, 2 ready issue(s) not started', gap[0])

    def test_all_host_caps_full_defers_every_ready_issue(self):
        notices, log, starts = self.scan(
            config(host_caps={'local': 5}), {'issue_scan_backlog_sweep_at': NOW}, {APP: [ready(1), ready(2)]}, workers=live(5))
        self.assertEqual(starts, [])
        self.assertIn('fill gap: 5 of 10 live, 2 ready issue(s) not started (host_cap x2), elon tops up by hand', notices)


class DotfilesFirstDoesNotBlock(Base):
    def remote_config(self):
        return config(local_host='coord', host_caps={'coord': 4, 'hostA': 4})

    def run_remote(self, state, maps):
        def admit(host, _cfg, _workers):
            if host == 'local':
                return {'admitted': False, 'reason': 'load per core too high'}
            return {'admitted': True, 'occupied': 0, 'cap': 4}

        with patch.object(fw, '_host_maps_repo', side_effect=lambda _c, _h, repo: maps(repo)):
            return self.scan(
                self.remote_config(), state, {APP: [ready(1, 'P2')], DOTS: [ready(2, 'P3')]}, admit=admit,
                repo_id_lookup=lambda _host, _repo: 'id_remote')

    def test_dotfiles_issue_refused_on_placement_does_not_stop_the_other_repo(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        _notices, log, starts = self.run_remote(state, lambda repo: repo != DOTS)
        self.assertIn('issue_deferred=2:placement', log)
        self.assertIn('issue_start=1', log)
        self.assertEqual(len(starts), 1)
        # fleet-watch records it for worker-startup, which then lets a hand start of another repo through.
        self.assertEqual(state['dotfiles_deferred'], {'2': NOW})

    def test_dotfiles_issue_that_can_start_still_goes_first(self):
        _notices, log, starts = self.run_remote({'issue_scan_backlog_sweep_at': NOW}, lambda _repo: True)
        self.assertEqual([b for b in log if b.startswith('issue_start=')], ['issue_start=2', 'issue_start=1'])
        self.assertEqual(len(starts), 2)

    def test_a_started_dotfiles_issue_leaves_the_deferred_record(self):
        state = {'issue_scan_backlog_sweep_at': NOW, 'dotfiles_deferred': {'2': NOW - 300},
                 'issue_scan_deferred': {DOTS: {'2': {'reason': 'placement', 'passes': 1, 'at': NOW - 300}}}}
        self.run_remote(state, lambda _repo: True)
        self.assertNotIn('2', state['dotfiles_deferred'])
        self.assertNotIn('2', state['issue_scan_deferred'][DOTS])


class DeferralEscalation(Base):
    def passes(self, state, count, reason_maps=lambda repo: repo != DOTS, start=NOW):
        notices = []
        helper = DotfilesFirstDoesNotBlock('run_remote')
        helper.setUp()
        for index in range(count):
            when = start + 300 * index
            admit = lambda host, _c, _w: ({'admitted': False, 'reason': 'busy'} if host == 'local' else {'admitted': True, 'occupied': 0, 'cap': 4})  # noqa: E731
            with patch.object(fw, '_host_maps_repo', side_effect=lambda _c, _h, repo: reason_maps(repo)):
                got, _log, _starts = helper.scan(
                    helper.remote_config(), state, {DOTS: [ready(2)]}, admit=admit, now=when,
                    repo_id_lookup=lambda _host, _repo: 'id_remote')
            notices.append(got)
        return notices

    def test_third_pass_with_the_same_reason_escalates_once(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        got = self.passes(state, 4)
        urgent = [[n for n in batch if 'deferred' in str(n) and 'elon resolves' in str(n)] for batch in got]
        self.assertEqual([len(u) for u in urgent], [0, 0, 1, 0])
        self.assertIsInstance(urgent[2][0], fw.Urgent)
        self.assertIn('owner/dotfiles #2 deferred 3 passes in a row (placement)', urgent[2][0])

    def test_a_gap_between_passes_starts_the_count_over(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        self.passes(state, 2)
        got = self.passes(state, 1, start=NOW + 4 * 3600)
        self.assertFalse([n for n in got[0] if 'elon resolves' in str(n)])
        self.assertEqual(state['issue_scan_deferred'][DOTS]['2']['passes'], 1)

    def test_a_changed_reason_starts_the_count_over(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        notices, bits = [], []
        for index, reason in enumerate(['placement', 'placement', 'host_cap', 'host_cap']):
            fw.defer_issue(state, NOW + 300 * index, DOTS, 2, reason, [], notices, bits)
        self.assertEqual(notices, [])


def open_pr(number, updated, branch='feature/x', head='a' * 40, labels=()):
    return {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': branch,
        'statusCheckRollup': [], 'comments': [], 'labels': [{'name': n} for n in labels], 'updatedAt': updated,
        'body': '', 'files': [],
    }


def iso(epoch):
    import time
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(epoch))


class UnownedPr(Base):
    def scan_prs(self, state, prs, workers=None, now=NOW):
        return self.scan(config(), state, {}, workers=workers, prs={APP: prs}, now=now)

    def test_pr_with_no_owner_and_no_progress_for_an_hour_goes_to_elon_once(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        prs = [open_pr(40, iso(NOW - 61 * 60))]
        notices, log, _starts = self.scan_prs(state, prs)
        urgent = [n for n in notices if 'no live owner worker' in str(n)]
        self.assertEqual(len(urgent), 1)
        self.assertIsInstance(urgent[0], fw.Urgent)
        self.assertIn('owner/app #40 has no live owner worker and no progress for 61 minutes: elon resolves it this wake', urgent[0])
        self.assertIn('pr_unowned=40', log)
        again, _log, _ = self.scan_prs(state, prs, now=NOW + 300)
        self.assertFalse([n for n in again if 'no live owner worker' in str(n)])

    def test_a_new_head_escalates_again(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        self.scan_prs(state, [open_pr(40, iso(NOW - 3700))])
        again, _log, _ = self.scan_prs(state, [open_pr(40, iso(NOW - 3700), head='b' * 40)], now=NOW + 300)
        self.assertEqual(len([n for n in again if 'no live owner worker' in str(n)]), 1)

    def test_pr_updated_within_the_hour_is_left_alone(self):
        notices, _log, _ = self.scan_prs({'issue_scan_backlog_sweep_at': NOW}, [open_pr(40, iso(NOW - 59 * 60))])
        self.assertFalse([n for n in notices if 'no live owner worker' in str(n)])

    def test_pr_with_a_live_owner_worker_is_left_alone(self):
        owner = {'dispatchId': 'ctx_o', 'state': 'running', 'name': 'build-40', 'headRefName': 'feature/x', 'githubPullRequestNumber': 40}
        notices, _log, _ = self.scan_prs({'issue_scan_backlog_sweep_at': NOW}, [open_pr(40, iso(NOW - 7200))], workers=[owner])
        self.assertFalse([n for n in notices if 'no live owner worker' in str(n)])

    def test_issue_builder_titled_for_the_issue_the_pr_closes_owns_it(self):
        row = open_pr(40, iso(NOW - 7200), branch='x')
        row['body'] = 'Closes #1778'
        builder = {'dispatchId': 'ctx_b', 'state': 'running', '_task_title': '#1778|fullstack-dev'}
        notices, _log, _ = self.scan_prs({'issue_scan_backlog_sweep_at': NOW}, [row], workers=[builder])
        self.assertFalse([n for n in notices if 'no live owner worker' in str(n)])

    def test_a_live_verifier_alone_is_not_an_owner(self):
        row = open_pr(40, iso(NOW - 7200))
        verifier = {'dispatchId': 'ctx_v', 'state': 'running', '_task_title': '#40|qa-sdet', 'headRefName': 'feature/x',
                    'githubPullRequestNumber': 40}
        notices, _log, _ = self.scan_prs({'issue_scan_backlog_sweep_at': NOW}, [row], workers=[verifier])
        self.assertEqual(len([n for n in notices if 'no live owner worker' in str(n)]), 1)

    def test_pr_already_labelled_needs_elon_is_left_alone(self):
        notices, _log, _ = self.scan_prs({'issue_scan_backlog_sweep_at': NOW}, [open_pr(40, iso(NOW - 7200), labels=['needs-elon'])])
        self.assertFalse([n for n in notices if 'no live owner worker' in str(n)])


if __name__ == '__main__':
    unittest.main()
