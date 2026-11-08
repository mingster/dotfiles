import importlib.util
import json
import os
import subprocess
import tempfile
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


class ReceiptAtHead(unittest.TestCase):
    def test_checks_fail_then_pass_with_main(self):
        head = '0' * 40
        main = '1' * 40
        row = pr(1, head=head, comments=[
            {'body': 'Checks: FAIL head=%s' % head, 'createdAt': '2026-11-05T10:00:00Z'},
            {'body': 'Checks: PASS head=%s main=%s' % (head, main), 'createdAt': '2026-11-05T10:05:00Z'},
        ])
        self.assertFalse(fw.checks_fail_at_head(row))
        self.assertTrue(fw.checks_pass_at_head(row))

    def test_checks_pass_then_fail_with_main(self):
        head = '2' * 40
        main = '3' * 40
        row = pr(2, head=head, comments=[
            {'body': 'Checks: PASS head=%s main=%s' % (head, main), 'createdAt': '2026-11-05T10:00:00Z'},
            {'body': 'Checks: FAIL head=%s' % head, 'createdAt': '2026-11-05T10:05:00Z'},
        ])
        self.assertTrue(fw.checks_fail_at_head(row))
        self.assertFalse(fw.checks_pass_at_head(row))

    def test_review_fail_then_pass_by_created_at(self):
        head = '4' * 40
        row = pr(3, head=head, comments=[
            {'body': 'Review: FAIL head=%s' % head, 'createdAt': '2026-11-05T10:05:00Z'},
            {'body': 'Review: PASS head=%s' % head, 'createdAt': '2026-11-05T10:00:00Z'},
        ])
        self.assertTrue(fw.review_failed_at_head(row))

    def test_review_pass_then_fail_by_created_at(self):
        head = '5' * 40
        row = pr(4, head=head, comments=[
            {'body': 'Review: PASS head=%s' % head, 'createdAt': '2026-11-05T10:00:00Z'},
            {'body': 'Review: FAIL head=%s' % head, 'createdAt': '2026-11-05T10:05:00Z'},
        ])
        self.assertTrue(fw.review_failed_at_head(row))


class ReviewAtHead(unittest.TestCase):
    def test_later_pass_verdict_cancels_rework(self):
        head = 'e' * 40
        row = pr(3, head=head, comments=[
            {'body': 'Verdict: FAIL head=%s x' % head, 'createdAt': '2026-11-05T10:00:00Z'},
            {'body': 'Verdict: PASS head=%s y' % head, 'createdAt': '2026-11-05T10:05:00Z'},
        ])
        self.assertFalse(fw.review_failed_at_head(row))

    def test_verdict_pass_does_not_clear_review_fail(self):
        head = 'd' * 40
        row = pr(3, head=head, comments=[
            {'body': 'Checks: PASS head=%s' % head, 'createdAt': '2026-11-08T09:00:00Z'},
            {'body': 'Review: FAIL head=%s' % head, 'createdAt': '2026-11-08T10:00:00Z'},
            {'body': 'Verdict: PASS head=%s verifier=x author=y' % head, 'createdAt': '2026-11-08T11:00:00Z'},
        ])
        self.assertTrue(fw.review_failed_at_head(row))
        self.assertTrue(fw.rework_needed_at_head(row, {}, REPO))

    def test_review_check_success_cancels_failure(self):
        head = 'f' * 40
        row = pr(4, head=head, checks=[
            {'context': 'review', 'conclusion': 'FAILURE'},
            {'context': 'review', 'conclusion': 'SUCCESS'},
        ])
        self.assertFalse(fw.review_failed_at_head(row))

    def test_checks_receipt_does_not_hide_verdict(self):
        head = 'a' * 40
        other = 'b' * 40
        row = pr(5, head=head, comments=[
            {'body': 'Verdict: PASS head=%s' % head},
            {'body': 'Checks: PASS head=%s main=%s' % (head, other)},
        ])
        self.assertTrue(fw.review_verdict_at_head(row))

    def test_review_fail_comment_triggers_rework(self):
        head = 'c' * 40
        row = pr(5, head=head, comments=[
            {'body': 'Checks: PASS head=%s' % head},
            {'body': 'Review: FAIL head=%s' % head},
        ])
        self.assertTrue(fw.review_failed_at_head(row))

    def test_review_pass_cancels_fail(self):
        head = 'h' * 40
        row = pr(6, head=head, comments=[
            {'body': 'Review: FAIL head=%s' % head},
            {'body': 'Review: PASS head=%s' % head},
        ])
        self.assertFalse(fw.review_failed_at_head(row))


class FetchPrsFields(unittest.TestCase):
    def test_json_includes_head_ref_and_labels(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout='[]')

        orig = fw.subprocess.run
        fw.subprocess.run = fake_run
        try:
            fw.fetch_prs(REPO)
            fields = calls[0][calls[0].index('--json') + 1]
            self.assertIn('headRefName', fields)
            self.assertIn('labels', fields)
            self.assertIn('isDraft', fields)
        finally:
            fw.subprocess.run = orig


class BuildReworkCommand(unittest.TestCase):
    CONFIG = {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'repo_roots': {REPO: '/tmp/app'},
        },
    }

    def test_base_branch_and_failure_excerpt(self):
        head = 'a' * 40
        row = pr(8, head=head, branch='mingster/issue-677', comments=[
            {'body': 'Checks: FAIL head=%s\nlint broke' % head},
        ])
        cmd = fw.build_rework_start_command(self.CONFIG, REPO, row)
        self.assertIn('--base-branch', cmd)
        self.assertIn('mingster/issue-677', cmd)
        spec = cmd[cmd.index('--spec') + 1]
        text = Path(spec).read_text(encoding='utf-8')
        self.assertIn('lint broke', text)


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
        admit_occupied=0, host_cap=4, detached=None, checks_locked=False, config=None,
        workflow_watch_prior=None, suppress_backlog_sweep=True,
    ):
        cfg = config or self.CONFIG
        issues_by_repo = issues_by_repo or {}
        if suppress_backlog_sweep and 'issue_scan_backlog_sweep_at' not in state:
            state['issue_scan_backlog_sweep_at'] = NOW
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
            cfg, state, NOW, workers,
            list_issues=list_issues, pr_fetch=fetch_prs,
            gate_check=gate_check, admit_fn=admit, start_worker=start_worker,
            inventory_ok=inventory_ok, persist_state=persist_state,
            start_detached=start_detached,
            checks_lock_live=(lambda _root: True) if checks_locked else None,
            workflow_watch_prior=workflow_watch_prior,
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

    def test_empty_queue_starts_backlog_sweep_pair(self):
        state = {}
        _, log, starts, _ = self.run_pass(state, {REPO: []}, suppress_backlog_sweep=False)
        self.assertEqual(len(starts), 2)
        joined = ' '.join(' '.join(cmd) for cmd in starts)
        self.assertIn('architect-pm', joined)
        self.assertIn('sales-marketing', joined)
        self.assertIn('team-grill-backlog', Path(starts[0][starts[0].index('--spec') + 1]).read_text(encoding='utf-8'))
        self.assertIn('backlog_sweep_start=architect-pm', ','.join(log))
        self.assertIn('backlog_sweep_start=sales-marketing', ','.join(log))

    def test_queue_of_three_skips_backlog_sweep(self):
        state = {}
        issues = {
            REPO: [
                issue(i, ['ready-for-agent'], 'no acceptance') for i in range(1, 4)
            ],
        }
        _, log, starts, _ = self.run_pass(state, issues, suppress_backlog_sweep=False)
        self.assertEqual(starts, [])
        self.assertIn('backlog_sweep_skip_queue', ','.join(log))

    def test_recent_backlog_sweep_skips_second_pair(self):
        state = {'issue_scan_backlog_sweep_at': NOW - 3600}
        _, log, starts, _ = self.run_pass(state, {REPO: []}, suppress_backlog_sweep=False)
        self.assertEqual(starts, [])
        self.assertIn('backlog_sweep_skip_recent', ','.join(log))

    def test_empty_queue_lists_issues_once_for_backlog_sweep(self):
        calls = []

        def list_issues(repo):
            calls.append(repo)
            return []

        state = {}
        fw.issue_scan_pass(
            self.CONFIG, state, NOW, [],
            list_issues=list_issues,
            gate_check=lambda _cfg: True,
            admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
            start_worker=lambda _cmd: 0,
            inventory_ok=True,
        )
        self.assertEqual(calls, [REPO])

    def test_partial_backlog_sweep_retries_missing_role_only(self):
        state = {}
        starts = []
        tick = 1000.0
        outcomes = {'architect-pm': 0, 'sales-marketing': 1}

        def start_worker(command):
            starts.append(command)
            name_idx = command.index('--name') + 1
            role = command[name_idx].replace('backlog-', '', 1)
            return outcomes.get(role, 1)

        def run_at(when):
            return fw.issue_scan_pass(
                self.CONFIG, state, when, [],
                list_issues=lambda _repo: [],
                gate_check=lambda _cfg: True,
                admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
                inventory_ok=True,
            )

        run_at(tick)
        self.assertEqual(state.get('issue_scan_backlog_sweep_at'), tick)
        self.assertEqual(state.get('issue_scan_backlog_sweep_roles'), ['architect-pm'])
        architect_starts = [
            cmd for cmd in starts
            if 'backlog-architect-pm' in cmd
        ]
        self.assertEqual(len(architect_starts), 1)

        outcomes['sales-marketing'] = 0
        run_at(tick + 300.0)
        architect_starts = [
            cmd for cmd in starts
            if 'backlog-architect-pm' in cmd
        ]
        self.assertEqual(len(architect_starts), 1)
        marketing_starts = [
            cmd for cmd in starts
            if 'backlog-sales-marketing' in cmd
        ]
        self.assertEqual(len(marketing_starts), 2)
        self.assertNotIn('issue_scan_backlog_sweep_roles', state)

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

    def test_persisted_head_checks_started_does_not_block_retry_without_receipt(self):
        head = 'd' * 40
        state = {'head_checks_started': {REPO: {head: True}}}
        with tempfile.TemporaryDirectory() as td:
            wt = os.path.join(td, 'wt')
            subprocess.run(['git', 'init', '-q', wt], check=True)
            subprocess.run(['git', '-C', wt, 'config', 'user.email', 't@example.com'], check=True)
            subprocess.run(['git', '-C', wt, 'config', 'user.name', 't'], check=True)
            subprocess.run(['git', '-C', wt, 'commit', '--allow-empty', '-m', 'init', '-q'], check=True)
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = os.path.join(td, 'coord-state')
            try:
                self.assertTrue(fw.write_post_push_stamp(REPO, head, checks_started=True))
                prs = {REPO: [pr(33, head=head)]}
                cfg = json.loads(json.dumps(self.CONFIG))
                cfg['issue_scan']['repo_roots'] = {REPO: wt}
                _, log, starts, _ = self.run_pass(
                    state, prs_by_repo=prs, detached=True, config=cfg,
                )
                self.assertEqual(len(starts), 1, log)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
                self.assertIn('head_checks_start=' + head[:8], ','.join(log))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

    def test_head_checks_retries_after_lock_dropped_without_receipt(self):
        head = 'e' * 40
        state = {}
        lock_held = [True]
        starts = []

        def lock_live(_root):
            return lock_held[0]

        def start_detached(command, extra_env=None):
            starts.append(command)
            return 0

        with tempfile.TemporaryDirectory() as td:
            wt = os.path.join(td, 'wt')
            subprocess.run(['git', 'init', '-q', wt], check=True)
            subprocess.run(['git', '-C', wt, 'config', 'user.email', 't@example.com'], check=True)
            subprocess.run(['git', '-C', wt, 'config', 'user.name', 't'], check=True)
            subprocess.run(['git', '-C', wt, 'commit', '--allow-empty', '-m', 'init', '-q'], check=True)
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = os.path.join(td, 'coord-state')
            try:
                self.assertTrue(fw.write_post_push_stamp(REPO, head, checks_started=True))
                prs = {REPO: [pr(34, head=head)]}
                cfg = json.loads(json.dumps(self.CONFIG))
                cfg['issue_scan']['repo_roots'] = {REPO: wt}
                common = dict(
                    pr_fetch=lambda repo: prs.get(repo, []),
                    gate_check=lambda _c: True,
                    admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
                    start_detached=start_detached,
                    checks_lock_live=lock_live,
                )
                fw.issue_scan_pass(cfg, state, NOW, [], **common)
                self.assertEqual(starts, [])
                lock_held[0] = False
                _, log = fw.issue_scan_pass(cfg, state, NOW, [], **common)
                self.assertEqual(len(starts), 1, log)
                self.assertIn('head_checks_start=' + head[:8], ','.join(log))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

    def test_publication_stamp_without_receipt_still_starts_checks(self):
        with tempfile.TemporaryDirectory() as td:
            wt = os.path.join(td, 'wt')
            subprocess.run(['git', 'init', '-q', wt], check=True)
            subprocess.run(
                ['git', '-C', wt, 'config', 'user.email', 't@example.com'],
                check=True,
            )
            subprocess.run(['git', '-C', wt, 'config', 'user.name', 't'], check=True)
            subprocess.run(
                ['git', '-C', wt, 'commit', '--allow-empty', '-m', 'init', '-q'],
                check=True,
            )
            head = subprocess.check_output(
                ['git', '-C', wt, 'rev-parse', 'HEAD'], text=True,
            ).strip()
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = os.path.join(td, 'coord-state')
            try:
                self.assertTrue(fw.write_post_push_stamp(
                    REPO, head, checks_started=True, reviewer_started=True,
                ))
                state = {}
                branch = 'mingster/build-683'
                prs = {REPO: [pr(30, head=head, branch=branch)]}
                workers = [author_worker(30, branch, worktree=wt)]
                cfg = json.loads(json.dumps(self.CONFIG))
                cfg['issue_scan']['repo_roots'] = {REPO: wt}
                _, log, starts, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True, config=cfg,
                )
                self.assertEqual(len(starts), 1)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
                self.assertIn('head_checks_start=' + head[:8], ','.join(log))
                self.assertNotIn('reviewer_start=' + head[:8], ','.join(log))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

    def test_remote_author_worktree_coordinator_stamp_starts_checks_and_reviewer_once(self):
        remote_wt = '/remote/blueDevil/workspaces/dotfiles/pr-680'
        with tempfile.TemporaryDirectory() as td:
            state_root = os.path.join(td, 'coord-state')
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = state_root
            root = os.path.join(td, 'repo-root')
            subprocess.run(['git', 'init', '-q', root], check=True)
            subprocess.run(
                ['git', '-C', root, 'config', 'user.email', 't@example.com'],
                check=True,
            )
            subprocess.run(['git', '-C', root, 'config', 'user.name', 't'], check=True)
            subprocess.run(
                ['git', '-C', root, 'commit', '--allow-empty', '-m', 'init', '-q'],
                check=True,
            )
            try:
                head = 'b' * 40
                self.assertTrue(fw.write_post_push_stamp(
                    REPO, head, checks_started=True, reviewer_started=True,
                ))
                state = {}
                branch = 'mingster/build-683'
                prs = {REPO: [pr(31, head=head, branch=branch)]}
                workers = [author_worker(31, branch, worktree=remote_wt)]
                cfg = json.loads(json.dumps(self.CONFIG))
                cfg['issue_scan']['repo_roots'] = {REPO: root}
                _, log, starts, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True, config=cfg,
                )
                self.assertEqual(len(starts), 1, log)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

        with tempfile.TemporaryDirectory() as td:
            state_root = os.path.join(td, 'coord-state')
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = state_root
            root = os.path.join(td, 'repo-root')
            subprocess.run(['git', 'init', '-q', root], check=True)
            subprocess.run(
                ['git', '-C', root, 'config', 'user.email', 't@example.com'],
                check=True,
            )
            subprocess.run(['git', '-C', root, 'config', 'user.name', 't'], check=True)
            subprocess.run(
                ['git', '-C', root, 'commit', '--allow-empty', '-m', 'init', '-q'],
                check=True,
            )
            try:
                head = 'c' * 40
                branch = 'mingster/build-683'
                prs = {REPO: [pr(32, head=head, branch=branch)]}
                workers = [author_worker(32, branch, worktree=remote_wt)]
                cfg = json.loads(json.dumps(self.CONFIG))
                cfg['issue_scan']['repo_roots'] = {REPO: root}
                state = {}
                _, log, starts, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True, config=cfg,
                )
                self.assertEqual(len(starts), 2, log)
                _, _, starts2, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True, config=cfg,
                )
                self.assertEqual(len(starts2), 1)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts2))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

    def test_open_pr_starts_checks_and_reviewer_in_parallel_once(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ['COORDINATOR_PUBLICATION_STATE_DIR'] = os.path.join(td, 'coord-state')
            try:
                state = {}
                head = '9' * 40
                branch = 'mingster/build-683'
                prs = {REPO: [pr(20, head=head, branch=branch)]}
                workers = [author_worker(20, branch)]
                _, log, starts, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True,
                )
                self.assertEqual(len(starts), 2)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
                self.assertTrue(any('on-worker-done.sh' in ' '.join(cmd) for cmd in starts))
                self.assertIn('head_checks_start=' + head[:8], ','.join(log))
                self.assertIn('reviewer_start=' + head[:8], ','.join(log))
                _, _, starts2, _ = self.run_pass(
                    state, prs_by_repo=prs, workers=workers, detached=True,
                )
                self.assertEqual(len(starts2), 1)
                self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts2))
            finally:
                os.environ.pop('COORDINATOR_PUBLICATION_STATE_DIR', None)

    def test_verdict_blocks_second_reviewer_when_checks_receipt_is_newer(self):
        state = {}
        head = '7' * 40
        other = '6' * 40
        branch = 'mingster/build-683'
        pr_row = pr(
            22, head=head, branch=branch,
            comments=[
                {'body': 'Verdict: PASS head=%s' % head},
                {'body': 'Checks: PASS head=%s main=%s' % (head, other)},
            ],
        )
        prs = {REPO: [pr_row]}
        workers = [author_worker(22, branch)]
        _, log, starts, _ = self.run_pass(state, prs_by_repo=prs, workers=workers, detached=True)
        self.assertEqual(starts, [])
        self.assertNotIn('reviewer_start=' + head[:8], ','.join(log))

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

    def test_checks_fail_starts_rework(self):
        state = {}
        head = '1' * 40
        prs = {REPO: [pr(9, head=head, comments=[{'body': 'Checks: FAIL head=%s' % head}])]}
        _, _, starts, _ = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(len(starts), 1)

    def test_rework_cap_labels_needs_elon(self):
        state = {'issue_scan_rework_rounds': {REPO: {'10': 2}}}
        head = '2' * 40
        prs = {REPO: [pr(10, head=head, comments=[
            {'body': 'Checks: PASS head=%s' % head},
            {'body': 'Review: FAIL head=%s' % head},
        ])]}
        edits = []

        def act(command):
            edits.append(command)
            return 0

        notices, _ = fw.issue_scan_pass(
            self.CONFIG, state, NOW, [],
            pr_fetch=lambda repo: prs.get(repo, []),
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda _c: 1,
            act=act,
        )
        self.assertTrue(any(c[:3] == ['gh', 'pr', 'edit'] for c in edits))
        self.assertIn('needs-elon', edits[0])
        self.assertTrue(any(isinstance(n, fw.Urgent) for n in notices))

    def test_needs_elon_label_skips_rework(self):
        state = {}
        head = '3' * 40
        prs = {REPO: [pr(11, head=head, labels=['needs-elon'], comments=[
            {'body': 'Checks: FAIL head=%s' % head},
        ])]}
        _, _, starts, _ = self.run_pass(state, prs_by_repo=prs)
        self.assertEqual(starts, [])

    def test_rollup_failure_without_prior_watch_starts_nothing(self):
        state = {'workflow_watch': {REPO: {'77': 'rerun'}}}
        head = '4' * 40
        prs = {REPO: [pr(12, head=head, checks=[{'context': 'ShellCheck', 'conclusion': 'FAILURE'}])]}
        _, _, starts, _ = self.run_pass(state, prs_by_repo=prs, workflow_watch_prior={})
        self.assertEqual(starts, [])

    def test_rollup_failure_unrelated_rerun_does_not_start_rework(self):
        head = '4' * 40
        fail_run = '42420403371'
        checks = [{
            'context': 'Script tests',
            'conclusion': 'FAILURE',
            'detailsUrl': 'https://github.com/%s/actions/runs/%s/job/1' % (REPO, fail_run),
        }]
        prs = {REPO: [pr(14, head=head, checks=checks)]}
        prior = {REPO: {'11111111111': 'rerun'}}
        _, _, starts, _ = self.run_pass({}, prs_by_repo=prs, workflow_watch_prior=prior)
        self.assertEqual(starts, [])

    def test_status_rollup_failure_after_rerun_keys_on_failing_run(self):
        head = '5' * 40
        run_id = '42420403371'
        pr_row = pr(15, head=head, checks=[{
            'context': 'Script tests',
            'conclusion': 'FAILURE',
            'detailsUrl': 'https://github.com/%s/actions/runs/%s/job/1' % (REPO, run_id),
        }])
        self.assertFalse(fw.status_rollup_failure_after_rerun(
            pr_row, {REPO: {'11111111111': 'rerun'}}, REPO))
        self.assertTrue(fw.status_rollup_failure_after_rerun(
            pr_row, {REPO: {run_id: 'rerun'}}, REPO))

    def test_rollup_failure_with_prior_watch_starts_rework(self):
        state = {}
        head = '4' * 40
        run_id = '77'
        prs = {REPO: [pr(13, head=head, checks=[{
            'context': 'ShellCheck',
            'conclusion': 'FAILURE',
            'detailsUrl': 'https://github.com/%s/actions/runs/%s/job/1' % (REPO, run_id),
        }])]}
        prior = {REPO: {run_id: 'rerun'}}
        _, _, starts, _ = self.run_pass(state, prs_by_repo=prs, workflow_watch_prior=prior)
        self.assertEqual(len(starts), 1)


if __name__ == '__main__':
    unittest.main()
