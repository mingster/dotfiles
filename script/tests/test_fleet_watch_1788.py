"""#1788: a ready-for-agent issue whose body says `Blocked by #n` waits while #n is open.

The blocker is read from the issue body (a `Blocked by` line, or items under a `## Blocked by` heading),
looked up on every pass, and the issue is skipped for that pass when its state cannot be read.
"""
import functools
import subprocess
import unittest
from unittest.mock import patch

from test_fleet_watch_scan import REPO, OTHER_REPO, NOW, fw, issue

CONFIG = {
    'issue_scan': {
        'enabled': True,
        'repos': [REPO],
        'run': 'run_x',
        'from_terminal': 'term_coord',
        'host': 'local',
        'agent': 'cursor',
        'model': 'm1',
        'repo_roots': {REPO: '/tmp/app'},
    },
    'host_caps': {'local': 4},
}

# A brief that passes brief-lint, so an unblocked issue reaches the start path.
BRIEF = (
    'Refs owner/app#1788\n\n'
    '## Acceptance\n'
    '- [ ] prove it\n\n'
    '## Out of scope\n'
    'other files\n\n'
    '## Verify\n'
    'bash script/checks-local.sh\n\n'
    '## Finish\n'
    'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
)


def blocked_body(*lines):
    return '\n'.join(lines) + '\n\n' + BRIEF


class Harness:
    """One issue_scan_pass with fakes. `states` maps (repo, number) to OPEN, CLOSED, or None when the lookup fails."""

    def __init__(self, rows, states=None):
        self.rows = rows
        self.states = states or {}
        self.lookups = []
        self.starts = []

    def issue_state(self, repo, number):
        self.lookups.append((repo, number))
        return self.states.get((repo, number), 'CLOSED')

    def start_detached(self, command, extra_env=None):
        self.starts.append(command)
        return 0

    def run(self, config=CONFIG):
        def list_issues(repo):
            return self.rows if repo == REPO else []

        state = {'issue_scan_backlog_sweep_at': NOW}
        notices, log = fw.issue_scan_pass(
            config, state, NOW, [],
            list_issues=list_issues, pr_fetch=lambda _repo: [],
            gate_check=lambda _cfg: True,
            admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
            start_worker=lambda command: self.starts.append(command) or 0,
            start_detached=self.start_detached, issue_state=self.issue_state,
            inventory_ok=True, persist_state=lambda: None,
            pick_fn=lambda role, **_kw: {'selected': {'provider': 'claude', 'model': 'opus'}},
        )
        return notices, ','.join(log)


class BlockedByBodyIsWaitedOn(unittest.TestCase):
    def test_section_item_with_open_blocker_is_not_started(self):
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('## Blocked by', '- #10077'))],
                    {(REPO, 10077): 'OPEN'})
        _, log = h.run()
        self.assertEqual(h.starts, [])
        self.assertIn('issue_blocked=10079:by=#10077', log)

    def test_blocked_by_line_with_open_blocker_is_not_started(self):
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                    {(REPO, 10077): 'OPEN'})
        _, log = h.run()
        self.assertEqual(h.starts, [])
        self.assertIn('issue_blocked=10079:by=#10077', log)

    def test_cross_repo_blocker_is_looked_up_in_its_own_repo(self):
        h = Harness([issue(7, ['ready-for-agent'], blocked_body('Blocked by owner/other#5'))],
                    {(OTHER_REPO, 5): 'OPEN'})
        _, log = h.run()
        self.assertEqual(h.starts, [])
        self.assertIn((OTHER_REPO, 5), h.lookups)
        self.assertIn('issue_blocked=7:by=owner/other#5', log)

    def test_issue_is_picked_again_once_blocker_closes_without_label_change(self):
        row = issue(10079, ['ready-for-agent'], blocked_body('## Blocked by', '- #10077'))
        h = Harness([row], {(REPO, 10077): 'OPEN'})
        h.run()
        self.assertEqual(h.starts, [])
        h.states[(REPO, 10077)] = 'CLOSED'
        _, log = h.run()
        self.assertEqual(len(h.starts), 1)
        self.assertNotIn('issue_blocked=10079', log)

    def test_failed_blocker_lookup_skips_the_issue_for_that_pass(self):
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                    {(REPO, 10077): None})
        _, log = h.run()
        self.assertEqual(h.starts, [])
        self.assertIn('issue_blocker_unknown=10079:by=#10077', log)

    def test_blocked_issue_is_not_ready_supply(self):
        # target_workers 1 and one blocked ready issue: counted as supply, the work order would start nothing.
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                    {(REPO, 10077): 'OPEN'})
        config = dict(CONFIG, work_order={'min_active': 0, 'target_workers': 1})
        _, log = h.run(config)
        self.assertIn('supply_start=1:0', log)


class SkippedIssuesAreNotSupply(unittest.TestCase):
    """#1816: ready issues the pass will not start (started, open PR, parked, live worker) are not supply."""

    CONFIG = dict(CONFIG, work_order={'min_active': 0, 'target_workers': 4})

    def scan(self, rows, prs=(), state=None, workers=None):
        starts = []
        state = state if state is not None else {}
        state.setdefault('issue_scan_backlog_sweep_at', NOW)
        _, log = fw.issue_scan_pass(
            self.CONFIG, state, NOW, workers or [],
            list_issues=lambda repo: rows if repo == REPO else [], pr_fetch=lambda _repo: list(prs),
            gate_check=lambda _cfg: True,
            admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
            start_worker=lambda command: starts.append(command) or 0,
            start_detached=lambda command, extra_env=None: starts.append(command) or 0,
            issue_state=lambda _repo, _number: 'CLOSED',
            inventory_ok=True, persist_state=lambda: None,
            pick_fn=lambda role, **_kw: {'selected': {'provider': 'claude', 'model': 'opus'}},
        )
        return starts, ','.join(log)

    def test_started_issue_is_not_supply(self):
        state = {'issue_scan_started': {REPO: [1]}, 'issue_scan_started_at': {REPO: {'1': NOW}}}
        starts, log = self.scan([issue(1, ['ready-for-agent'], BRIEF)], state=state)
        self.assertIn('supply_start=4:0', log)
        self.assertEqual(len(starts), 1)

    def test_open_pr_issue_is_not_supply(self):
        pr = {'number': 50, 'state': 'OPEN', 'body': 'Closes #1', 'headRefName': 'x', 'isDraft': False}
        starts, log = self.scan([issue(1, ['ready-for-agent'], BRIEF)], prs=[pr])
        self.assertIn('supply_start=4:0', log)

    def test_parked_issue_is_not_supply(self):
        row = issue(1, ['ready-for-agent'], BRIEF)
        key = fw.park_id('issue', REPO, 1, row.get('updatedAt') or '')
        starts, log = self.scan([row], state={'parked': {key: {}}})
        self.assertIn('issue_parked=1', log)
        self.assertIn('supply_start=4:0', log)

    def test_live_worker_issue_is_not_supply(self):
        worker = {'_task_title': '#1|fullstack-dev', 'status': 'working'}
        starts, log = self.scan([issue(1, ['ready-for-agent'], BRIEF)], workers=[worker])
        self.assertIn('issue_live=1', log)
        self.assertRegex(log, r'supply_start=\d+:0')

    def test_startable_issue_still_counts_as_supply(self):
        starts, log = self.scan([issue(1, ['ready-for-agent'], BRIEF)])
        self.assertIn('supply_start=4:1', log)


class NoFalseBlocks(unittest.TestCase):
    def test_issue_without_blocked_by_text_is_started_and_never_looked_up(self):
        h = Harness([issue(10079, ['ready-for-agent'], BRIEF)])
        h.run()
        self.assertEqual(len(h.starts), 1)
        self.assertEqual(h.lookups, [])

    def test_red_gate_line_in_body_is_not_a_blocker_lookup(self):
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('Blocked by red gate #9'))])
        h.run()
        self.assertNotIn((REPO, 9), h.lookups)

    def test_closed_blocker_does_not_hold_the_issue(self):
        h = Harness([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                    {(REPO, 10077): 'CLOSED'})
        h.run()
        self.assertEqual(len(h.starts), 1)


class DefaultLookupReadsPullRequests(unittest.TestCase):
    """#2027: a Blocked by ref may be a PR. The default lookup reads it through the REST issues route, as clear_stale_blocked does."""

    CONFIG = dict(CONFIG, work_order={'min_active': 0, 'target_workers': 4})

    def run_default(self, rows, gh):
        # gh maps a number to OPEN or CLOSED (REST serves a PR too). The fake `gh issue view` refuses a PR, as the real CLI does.
        def fake_gh(args, **_kw):
            if args[:2] == ['gh', 'api']:
                number = int(args[2].rsplit('/', 1)[1])
                state = gh.get(number)
                return subprocess.CompletedProcess(args, 0 if state else 1, (state or '') + '\n', '')
            return subprocess.CompletedProcess(args, 1, '', 'not an issue')

        starts = []
        with patch.object(fw, 'fetch_ref_state', functools.partial(fw.fetch_ref_state, run=fake_gh)), \
                patch.object(fw, 'fetch_issue_state', functools.partial(fw.fetch_issue_state, run=fake_gh)):
            _, log = fw.issue_scan_pass(
                self.CONFIG, {'issue_scan_backlog_sweep_at': NOW}, NOW, [],
                list_issues=lambda repo: rows if repo == REPO else [], pr_fetch=lambda _repo: [],
                gate_check=lambda _cfg: True,
                admit_fn=lambda _host, _cfg, _workers: {'admitted': True, 'occupied': 0},
                start_worker=lambda command: starts.append(command) or 0,
                start_detached=lambda command, extra_env=None: starts.append(command) or 0,
                inventory_ok=True, persist_state=lambda: None,
                pick_fn=lambda role, **_kw: {'selected': {'provider': 'claude', 'model': 'opus'}},
            )
        return starts, ','.join(log)

    def test_merged_pr_under_blocked_by_does_not_block_or_park(self):
        _, log = self.run_default([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                                  {10077: 'CLOSED'})
        self.assertIn('issue_start=10079', log)
        self.assertNotIn('issue_blocker_unknown', log)
        self.assertNotIn('issue_blocked=10079', log)

    def test_open_pr_under_blocked_by_still_blocks(self):
        _, log = self.run_default([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))],
                                  {10077: 'OPEN'})
        self.assertNotIn('issue_start=10079', log)
        self.assertIn('issue_blocked=10079:by=#10077', log)

    def test_unreadable_reference_is_unknown_and_not_started(self):
        _, log = self.run_default([issue(10079, ['ready-for-agent'], blocked_body('Blocked by #10077'))], {})
        self.assertNotIn('issue_start=10079', log)
        self.assertIn('issue_blocker_unknown=10079:by=#10077', log)


if __name__ == '__main__':
    unittest.main()
