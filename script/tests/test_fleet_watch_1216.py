"""#1216: issue labels. Eligibility, sort order, start strip, failed start return and double start guards."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import HEAD, REPO, failing_review_pr, issue_row, scan_config  # noqa: E402


def row(number, labels=('ready-for-agent',), created='2026-01-01T00:00:00Z'):
    out = issue_row(number, '2026-01-02T00:00:00Z')
    out['labels'] = [{'name': name} for name in labels]
    out['createdAt'] = created
    return out


def run_pass(issues, workers=(), start_code=0, prs=(), pick=None, state=None):
    starts, edits = [], []
    state = {'issue_scan_backlog_sweep_at': 1} if state is None else state
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        notices, bits = fw.issue_scan_pass(
            scan_config('/work/app'), state, 1, list(workers),
            pr_fetch=lambda _r: list(prs), list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=lambda command: starts.append(command) or start_code,
            act=lambda command: edits.append(command) or 0, pick_fn=pick,
        )
    return starts, edits, bits, state


def issue_of(command):
    return int(command[command.index('--name') + 1].split('-')[1])


class SortOrder(unittest.TestCase):
    def numbers(self, rows):
        return [r['number'] for r in sorted(fw.issue_scan_sorted_eligible(rows), key=fw.issue_scan_sort_key)]

    def test_priority_then_size_then_created_then_number(self):
        rows = [
            row(1, ('ready-for-agent', 'P3')),
            row(2, ('ready-for-agent', 'P2', 'size:L')),
            row(3, ('ready-for-agent', 'P2')),
            row(4, ('ready-for-agent', 'P2', 'size:S')),
            row(5, ('ready-for-agent', 'P1', 'size:L')),
            row(6, ('ready-for-agent', 'P0', 'size:L')),
            row(7, ('ready-for-agent',), created='2026-01-01T00:00:00Z'),
            row(8, ('ready-for-agent', 'P2'), created='2025-12-31T00:00:00Z'),
        ]
        self.assertEqual(self.numbers(rows), [6, 5, 4, 8, 3, 7, 2, 1])

    def test_number_breaks_a_full_tie(self):
        rows = [row(9), row(3), row(5)]
        self.assertEqual(self.numbers(rows), [3, 5, 9])

    def test_no_p_label_ranks_as_p2(self):
        self.assertEqual(fw.issue_scan_priority(row(1)), fw.issue_scan_priority(row(2, ('ready-for-agent', 'P2'))))
        self.assertGreater(fw.issue_scan_priority(row(1, ('ready-for-agent', 'P3'))), fw.issue_scan_priority(row(2)))

    def test_pass_starts_the_best_ranked_issue(self):
        starts, *_ = run_pass([row(1, ('ready-for-agent', 'P3')), row(2, ('ready-for-agent', 'P0')), row(3)])
        self.assertEqual(issue_of(starts[0]), 2)


class Eligibility(unittest.TestCase):
    def test_each_hold_label_blocks(self):
        for hold in sorted(fw.ISSUE_HOLD_LABELS):
            self.assertFalse(fw.issue_scan_eligible(row(1, ('ready-for-agent', hold))), hold)
        self.assertEqual(
            fw.ISSUE_HOLD_LABELS,
            {'blocked', 'owner', 'deferred', 'tracking', 'needs-triage', 'needs-elon', 'needs-redesign'})

    def test_plain_ready_issue_is_eligible(self):
        self.assertTrue(fw.issue_scan_eligible(row(1, ('ready-for-agent', 'P2'))))


class StartStrip(unittest.TestCase):
    def test_a_started_issue_loses_ready_for_agent(self):
        starts, edits, _bits, _st = run_pass([row(5)])
        self.assertEqual(len(starts), 1)
        self.assertEqual(edits, [['gh', 'issue', 'edit', '5', '--repo', REPO, '--remove-label', 'ready-for-agent']])


class FailedStart(unittest.TestCase):
    def test_failed_start_with_no_pr_returns_to_needs_triage(self):
        starts, edits, bits, _st = run_pass([row(5)], start_code=1)
        self.assertEqual(len(starts), 1)
        self.assertEqual(edits, [[
            'gh', 'issue', 'edit', '5', '--repo', REPO,
            '--add-label', 'needs-triage', '--remove-label', 'ready-for-agent']])
        self.assertTrue(any(b.startswith('issue_start_fail=5') for b in bits))

    def test_deferred_start_keeps_the_label(self):
        code = sorted(fw.BABYSIT_DEFERRED_EXITS)[0]
        _starts, edits, _bits, _st = run_pass([row(5)], start_code=code)
        self.assertEqual(edits, [])


class DoubleStartGuards(unittest.TestCase):
    def test_live_worker_with_other_role_or_suffix_blocks(self):
        for title in ('#5|fullstack-dev', '#5|fullstack-dev-small', '#5|fullstack-dev|retry', '#5|qa-sdet'):
            worker = {'_task_title': title, 'status': 'running'}
            with patch.object(fw, 'worker_row_is_live', return_value=True):
                starts, edits, bits, _st = run_pass([row(5)], workers=[worker])
            self.assertEqual(starts, [], title)
            self.assertEqual(edits, [], title)
            self.assertIn('issue_live=5', bits, title)

    def test_prefix_does_not_match_a_longer_number(self):
        worker = {'_task_title': '#55|fullstack-dev', 'status': 'running'}
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, *_ = run_pass([row(5)], workers=[worker])
        self.assertEqual(len(starts), 1)

    def test_started_set_blocks(self):
        starts, *_ = run_pass([row(5)], state={'issue_scan_backlog_sweep_at': 1, 'issue_scan_started': {REPO: [5]}})
        self.assertEqual(starts, [])

    def test_pending_set_blocks(self):
        starts, *_ = run_pass([row(5)], state={'issue_scan_backlog_sweep_at': 1, 'issue_scan_pending': {REPO: [5]}})
        self.assertEqual(starts, [])

    def test_open_pr_blocks(self):
        pr = {'number': 9, 'state': 'OPEN', 'isDraft': False, 'headRefOid': 'c' * 40, 'headRefName': 'x',
              'body': 'Closes #5', 'comments': [], 'statusCheckRollup': [], 'labels': []}
        starts, _e, bits, _st = run_pass([row(5)], prs=[pr])
        self.assertEqual(starts, [])
        self.assertIn('issue_open_pr=5', bits)


class RoleRouting(unittest.TestCase):
    def picker(self, seen):
        def pick(role, tier=None):
            seen.append(role if tier is None else (role, tier))
            return {'selected': {'provider': 'claude', 'model': 'm-' + role}, 'candidates': []}
        return pick

    def test_routes(self):
        cases = {
            ('ready-for-agent',): None,
            ('ready-for-agent', 'size:S'): ('fullstack-dev-small', 'fullstack-dev-small', None),
            ('ready-for-agent', 'size:L'): ('fullstack-dev', 'fullstack-dev', 'strong'),
            ('ready-for-agent', 'role:pm'): ('architect-pm', 'architect-pm', None),
            ('ready-for-agent', 'role:qa', 'size:L'): ('qa-sdet', 'qa-sdet', None),
            ('ready-for-agent', 'role:ops'): ('release-manager', 'release-manager', None),
            ('ready-for-agent', 'role:ops', 'size:L'): ('release-manager', 'release-manager', 'strong'),
            ('ready-for-agent', 'role:secops'): ('secops-finops', 'secops-finops', None),
            ('ready-for-agent', 'role:growth'): ('sales-marketing', 'sales-marketing', None),
            ('ready-for-agent', 'role:support'): ('support-csm', 'support-csm', None),
        }
        for labels, want in cases.items():
            self.assertEqual(fw.issue_scan_route(row(1, labels)), want, labels)

    def test_role_label_picks_through_usage_gate(self):
        seen = []
        starts, *_ = run_pass([row(5, ('ready-for-agent', 'role:qa'))], pick=self.picker(seen))
        self.assertEqual(seen, ['qa-sdet'])
        command = starts[0]
        self.assertEqual(command[command.index('--title') + 1], '#5|qa-sdet')
        self.assertEqual(command[command.index('--model') + 1], 'm-qa-sdet')

    def test_no_role_label_keeps_the_builder_pick(self):
        seen = []
        starts, *_ = run_pass([row(5)], pick=self.picker(seen))
        self.assertEqual(seen, [])
        self.assertEqual(starts[0][starts[0].index('--model') + 1], 'm1')

    def test_blocked_pick_skips_to_the_next_issue(self):
        calls = []

        def pick(role, tier=None):
            calls.append(role)
            return {'selected': None, 'candidates': []} if role == 'qa-sdet' else {
                'selected': {'provider': 'claude', 'model': 'x'}, 'candidates': []}
        starts, _e, bits, _st = run_pass(
            [row(1, ('ready-for-agent', 'P0', 'role:qa')), row(2, ('ready-for-agent', 'P2'))], pick=pick)
        self.assertIn('issue_route_blocked=1:qa-sdet', bits)
        self.assertEqual(issue_of(starts[0]), 2)

    def test_size_l_picks_the_strong_tier(self):
        seen = []
        starts, *_ = run_pass([row(5, ('ready-for-agent', 'size:L')),
                               row(6, ('ready-for-agent', 'role:ops', 'size:L'))], pick=self.picker(seen))
        self.assertEqual(seen, [('fullstack-dev', 'strong'), ('release-manager', 'strong')])
        self.assertEqual([c[c.index('--title') + 1] for c in starts], ['#5|fullstack-dev', '#6|release-manager'])
        self.assertEqual(starts[0][starts[0].index('--model') + 1], 'm-fullstack-dev')


class StrongRework(unittest.TestCase):
    """#1396 owner Q3: the first rework of an M PR stays Workhorse; Strong from the second round, or round 1 on size:L."""

    def rework(self, pr, rounds=0, issue_labels=(), selected=True):
        seen = []

        def pick(role, tier=None):
            seen.append((role, tier))
            return {'selected': {'provider': 'claude', 'model': 'opus', 'effort': 'high'} if selected else None,
                    'candidates': []}
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            if rounds:
                state['issue_scan_rework_rounds'] = {REPO: {str(pr['number']): rounds}}
            starts = []
            with patch.object(fw, 'rpc', side_effect=fake_rpc), \
                    patch.object(fw, 'issue_label_names', side_effect=lambda _r, _n: list(issue_labels)):
                fw.issue_scan_pass(
                    scan_config(root), state, 1, [], pr_fetch=lambda _r: [pr], list_issues=lambda _r: [],
                    gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                    start_worker=lambda command: starts.append(command) or 0,
                    start_detached=lambda *_a, **_k: 0, checks_lock_live=lambda _root: False,
                    act=lambda _c: 0, pick_fn=pick,
                )
        self.assertEqual(len(starts), 1)
        command = starts[0]
        return seen, (command[command.index('--agent') + 1], command[command.index('--model') + 1])

    def test_first_rework_of_an_m_pr_stays_workhorse(self):
        seen, pair = self.rework(failing_review_pr(4, HEAD))
        self.assertEqual((seen, pair), ([], ('cursor', 'm1')))

    def test_second_rework_round_goes_strong(self):
        seen, pair = self.rework(failing_review_pr(4, HEAD), rounds=1)
        self.assertEqual((seen, pair), ([('fullstack-dev', 'strong')], ('claude', 'opus')))

    def test_first_rework_of_a_size_l_pr_goes_strong(self):
        pr = failing_review_pr(4, HEAD)
        pr['labels'] = [{'name': 'size:L'}]
        self.assertEqual(self.rework(pr)[1], ('claude', 'opus'))

    def test_first_rework_when_the_closing_issue_is_size_l_goes_strong(self):
        pr = {**failing_review_pr(4, HEAD), 'body': 'Part one.\nCloses #41'}
        self.assertEqual(self.rework(pr, issue_labels=('P2', 'size:L'))[1], ('claude', 'opus'))
        self.assertEqual(self.rework(pr, issue_labels=('P2',))[1], ('cursor', 'm1'))

    def test_no_strong_model_keeps_the_workhorse_rework(self):
        self.assertEqual(self.rework(failing_review_pr(4, HEAD), rounds=1, selected=False)[1], ('cursor', 'm1'))


if __name__ == '__main__':
    unittest.main()
