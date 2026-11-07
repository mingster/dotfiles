import importlib.util
import json
import subprocess
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
OTHER_REPO = 'owner/other'
NOW = 1_700_000_000.0
FIXTURE = Path(__file__).parent / 'fixtures' / 'gh_issue_list_ready.json'


def issue(number, labels=None, body='', comments=None, created=None, blocked=False, blocker_state='OPEN'):
    labels = labels or []
    created = created or '2026-01-01T00:00:00Z'
    row = {
        'number': number,
        'title': 'ticket %d' % number,
        'body': body,
        'labels': [{'name': n} for n in labels],
        'comments': comments or [],
        'createdAt': created,
    }
    if blocked:
        row['blockedBy'] = {
            'nodes': [{'number': 99, 'state': blocker_state}],
            'totalCount': 1,
        }
    return row


def pr(number, head='a' * 40, checks=(), comments=(), branch='feature/pr', labels=(), draft=False):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': draft,
        'headRefOid': head,
        'headRefName': branch,
        'statusCheckRollup': list(checks),
        'comments': list(comments),
        'labels': [{'name': n} for n in labels],
    }


def author_worker(number, branch, worktree='/tmp/wt', dispatch='ctx_author'):
    return {
        'dispatchId': dispatch,
        'githubPullRequestNumber': number,
        'headRefName': branch,
        'projection': {
            'provider': {'id': 'claude', 'model': 'sonnet'},
            'workspace': {'path': worktree},
            'runId': 'run_x',
        },
    }


class IssueEligibility(unittest.TestCase):
    def test_ready_label_and_acceptance_required(self):
        good = issue(1, ['ready-for-agent'], '## Acceptance criteria\n- x')
        self.assertTrue(fw.issue_scan_eligible(good))
        self.assertFalse(fw.issue_scan_eligible(issue(2, ['ready-for-agent'], 'no criteria')))
        self.assertFalse(fw.issue_scan_eligible(issue(3, [], '## Acceptance criteria\n- x')))

    def test_acceptance_may_live_in_comments(self):
        self.assertTrue(fw.issue_scan_eligible(issue(1, ['ready-for-agent'], '', comments=[{'body': '## Acceptance criteria\n- y'}])))

    def test_blocked_issues_never_eligible(self):
        self.assertFalse(fw.issue_scan_eligible(issue(1, ['ready-for-agent'], '## Acceptance criteria\n- x', blocked=True)))

    def test_closed_blocker_does_not_block(self):
        row = issue(1, ['ready-for-agent'], '## Acceptance criteria\n- x', blocked=True, blocker_state='CLOSED')
        self.assertTrue(fw.issue_scan_eligible(row))


class FetchReadyIssues(unittest.TestCase):
    def test_command_requests_blocked_by_not_is_blocked(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout='[]')

        fw.fetch_ready_issues(REPO, run=fake_run)
        json_fields = calls[0][calls[0].index('--json') + 1]
        self.assertIn('blockedBy', json_fields)
        self.assertNotIn('isBlocked', json_fields)

    def test_parses_recorded_live_list_json(self):
        raw = FIXTURE.read_text(encoding='utf-8')
        rows = json.loads(raw)
        self.assertTrue(rows)
        self.assertIn('blockedBy', rows[0])

        def fake_run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, stdout=raw)

        result = fw.fetch_ready_issues(REPO, run=fake_run)
        self.assertEqual(len(result), 1)
        self.assertTrue(fw.issue_scan_eligible(result[0]))


class ReviewAtHead(unittest.TestCase):
    def test_later_pass_verdict_cancels_rework(self):
        head = 'e' * 40
        row = pr(3, head=head, comments=[
            {'body': 'Verdict: FAIL head=%s x' % head},
            {'body': 'Verdict: PASS head=%s y' % head},
        ])
        self.assertFalse(fw.review_failed_at_head(row))

    def test_review_check_success_cancels_failure(self):
        head = 'f' * 40
        row = pr(4, head=head, checks=[
            {'context': 'review', 'conclusion': 'FAILURE'},
            {'context': 'review', 'conclusion': 'SUCCESS'},
        ])
        self.assertFalse(fw.review_failed_at_head(row))


class IssueScanOrder(unittest.TestCase):
    def test_p0_before_p1_before_oldest(self):
        rows = [
            issue(3, ['ready-for-agent', 'P1'], '## Acceptance criteria\n- x', created='2026-01-03T00:00:00Z'),
            issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x', created='2026-01-01T00:00:00Z'),
            issue(2, ['ready-for-agent'], '## Acceptance criteria\n- x', created='2026-01-02T00:00:00Z'),
            issue(4, ['ready-for-agent', 'P1'], '## Acceptance criteria\n- x', created='2026-01-01T12:00:00Z'),
        ]
        ordered = fw.issue_scan_sorted_eligible(rows)
        self.assertEqual([r['number'] for r in ordered], [1, 4, 3, 2])


class IssueScanPass(unittest.TestCase):
    CONFIG = {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'agent': 'cursor',
            'model': 'm1',
            'rework_agent': 'cursor',
            'rework_model': 'm1',
            'repo_roots': {REPO: '/tmp/app'},
        },
        'host_caps': {'local': 4},
    }

    def run_pass(
        self, state, issues_by_repo=None, starts=None, gate_ok=True, admitted=True,
        prs_by_repo=None, inventory_ok=True, start_rc=0, workers=None, persist=None,
        admit_occupied=0, host_cap=4, detached=None, checks_locked=False,
    ):
        issues_by_repo = issues_by_repo or {}
        prs_by_repo = prs_by_repo or {}
        starts = starts if starts is not None else []
        persists = persist if persist is not None else []
        workers = [] if workers is None else workers

        def list_issues(repo):
            return issues_by_repo.get(repo, [])

        def fetch_prs(repo):
            return prs_by_repo.get(repo, [])

        def gate_check(_cfg):
            return gate_ok

        def admit(_host, _cfg, _workers):
            return {
                'admitted': admitted,
                'occupied': admit_occupied,
            }

        detached_starts = []

        def start_worker(command):
            starts.append(command)
            return start_rc

        def start_detached(command, extra_env=None):
            if detached is True:
                detached_starts.append((command, extra_env))
            return 0

        def persist_state():
            persists.append(True)

        notices, log = fw.issue_scan_pass(
            self.CONFIG, state, NOW, workers,
            list_issues=list_issues, pr_fetch=fetch_prs,
            gate_check=gate_check, admit_fn=admit, start_worker=start_worker,
            inventory_ok=inventory_ok, persist_state=persist_state,
            start_detached=start_detached,
            checks_lock_live=(lambda _root: True) if checks_locked else None,
        )
        if detached is True:
            starts.extend([row[0] for row in detached_starts])
        return notices, log, starts, persists

    def test_disabled_starts_nothing(self):
        cfg = {'issue_scan': {'enabled': False}}
        notices, log = fw.issue_scan_pass(cfg, {}, NOW, [])
        self.assertEqual(notices, [])
        self.assertEqual(log, ['issue_scan_off'])

    def test_no_config_starts_nothing(self):
        notices, log = fw.issue_scan_pass({}, {}, NOW, [])
        self.assertEqual(notices, [])
        self.assertEqual(log, ['issue_scan_off'])

    def test_eligible_issue_starts_once(self):
        state = {}
        issues = {
            REPO: [issue(9, ['ready-for-agent'], '## Acceptance criteria\n- prove it')],
        }
        _, log, starts, _ = self.run_pass(state, issues)
        self.assertEqual(len(starts), 1)
        joined = ' '.join(starts[0])
        self.assertIn('worker-startup', joined)
        self.assertIn('--run', starts[0])
        self.assertIn('run_x', starts[0])
        _, log2, starts2, _ = self.run_pass(state, issues)
        self.assertEqual(starts2, [])
        self.assertIn('issue_scan_none', log2)

    def test_ineligible_never_starts(self):
        state = {}
        issues = {
            REPO: [
                issue(1, ['ready-for-agent'], 'no section'),
                issue(2, [], '## Acceptance criteria\n- x'),
                issue(3, ['ready-for-agent'], '## Acceptance criteria\n- x', blocked=True),
            ],
        }
        _, _, starts, _ = self.run_pass(state, issues)
        self.assertEqual(starts, [])

    def test_gate_refusal_starts_nothing(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        _, log, starts, _ = self.run_pass(state, issues, gate_ok=False)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_gate', log)

    def test_load_refusal_starts_nothing(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        _, log, starts, _ = self.run_pass(state, issues, admitted=False)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_load', log)

    def test_priority_order_picks_first_eligible_only(self):
        state = {}
        issues = {
            REPO: [
                issue(2, ['ready-for-agent'], '## Acceptance criteria\n- x', created='2026-01-02T00:00:00Z'),
                issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x', created='2026-01-03T00:00:00Z'),
            ],
        }
        _, _, starts, _ = self.run_pass(state, issues)
        self.assertEqual(len(starts), 1)
        self.assertIn('#1', ' '.join(starts[0]))

    def test_failed_inventory_refuses_start(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        _, log, starts, _ = self.run_pass(state, issues, inventory_ok=False)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_inventory_failed', log)

    def test_failed_inventory_with_live_worker_refuses_not_empty_fleet(self):
        state = {}
        issues = {REPO: [issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- x')]}
        live = [{'dispatchId': 'd1', 'status': 'running', 'host': 'local'}]
        _, log, starts, _ = self.run_pass(state, issues, inventory_ok=False, workers=live)
        self.assertEqual(starts, [])
        self.assertIn('issue_scan_inventory_failed', log)

    def test_pending_latch_before_start_blocks_second_pass(self):
        state = {'issue_scan_pending': {REPO: [8]}}
        issues = {REPO: [issue(8, ['ready-for-agent'], '## Acceptance criteria\n- x')]}
        _, log2, starts2, _ = self.run_pass(state, issues, start_rc=0)
        self.assertEqual(starts2, [])
        self.assertIn('issue_scan_none', log2)

    def test_start_timeout_clears_pending_and_retries(self):
        state = {}
        issues = {REPO: [issue(5, ['ready-for-agent'], '## Acceptance criteria\n- x')]}
        _, _, starts1, _ = self.run_pass(state, issues, start_rc=1)
        self.assertEqual(len(starts1), 1)
        self.assertNotIn(5, state.get('issue_scan_started', {}).get(REPO, []))
        self.assertNotIn(5, state.get('issue_scan_pending', {}).get(REPO, []))
        _, _, starts2, _ = self.run_pass(state, issues, start_rc=0)
        self.assertEqual(len(starts2), 1)
        self.assertIn(5, state.get('issue_scan_started', {}).get(REPO, []))

    def test_cap_one_allows_only_one_rework_in_pass(self):
        state = {}
        head_a, head_b = 'a' * 40, 'b' * 40
        prs = {
            REPO: [
                pr(1, head=head_a, checks=[
                    {'context': 'head-checks', 'conclusion': 'SUCCESS'},
                    {'context': 'review', 'conclusion': 'FAILURE'},
                ]),
                pr(2, head=head_b, checks=[
                    {'context': 'head-checks', 'conclusion': 'SUCCESS'},
                    {'context': 'review', 'conclusion': 'FAILURE'},
                ]),
            ],
        }
        cfg = dict(self.CONFIG)
        cfg['host_caps'] = {'local': 1}
        starts = []

        def fetch_prs(repo):
            return prs.get(repo, [])

        def admit(_host, _cfg, _workers):
            return {'admitted': True, 'occupied': 0}

        def start_worker(command):
            starts.append(command)
            return 0

        _, log = fw.issue_scan_pass(
            cfg, state, NOW, [],
            pr_fetch=fetch_prs,
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=start_worker,
        )
        self.assertEqual(len(starts), 1)
        self.assertIn('rework_start=', ','.join(log))

    def test_open_pr_starts_checks_and_reviewer_in_parallel_once(self):
        state = {}
        head = '9' * 40
        branch = 'mingster/build-683'
        prs = {REPO: [pr(20, head=head, branch=branch)]}
        workers = [author_worker(20, branch)]
        _, log, starts, _ = self.run_pass(state, prs_by_repo=prs, workers=workers, detached=True)
        self.assertEqual(len(starts), 2)
        self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
        self.assertTrue(any('on-worker-done.sh' in ' '.join(cmd) for cmd in starts))
        self.assertIn('head_checks_start=' + head[:8], ','.join(log))
        self.assertIn('reviewer_start=' + head[:8], ','.join(log))
        _, _, starts2, _ = self.run_pass(state, prs_by_repo=prs, workers=workers, detached=True)
        self.assertEqual(starts2, [])

    def test_locked_checks_skips_second_head_checks_spawn(self):
        state = {}
        head = '8' * 40
        prs = {REPO: [pr(21, head=head)]}
        _, log, starts, _ = self.run_pass(state, prs_by_repo=prs, detached=True, checks_locked=True)
        self.assertEqual(starts, [])
        self.assertNotIn('head_checks_start=', ','.join(log))

    def test_failed_review_starts_one_rework_per_head(self):
        state = {}
        head = 'c' * 40
        prs = {
            REPO: [
                pr(7, head=head, checks=[{'context': 'head-checks', 'conclusion': 'SUCCESS'},
                                         {'context': 'review', 'conclusion': 'FAILURE'}]),
            ],
        }
        _, log, starts, _ = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(len(starts), 1)
        self.assertIn('rework', ' '.join(starts[0]).lower())
        _, _, starts2, _ = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(starts2, [])
        other = 'd' * 40
        prs[REPO][0]['headRefOid'] = other
        _, _, starts3, _ = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(len(starts3), 1)


if __name__ == '__main__':
    unittest.main()
