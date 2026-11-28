"""#1811: a delivered refusal shows in issue_scan_deferred, and a started issue with no PR and no live worker starts again."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import REPO, issue_row, scan_config  # noqa: E402

DELIVERED = fw.BabysitStartResult(
    1, 'worker-startup: refused: acme/app#9655 already delivered by merged PR #10055 '
       'close the issue or pass --allow-delivered REASON')
OPEN_PR = {'number': 9, 'state': 'OPEN', 'isDraft': False, 'headRefOid': 'c' * 40, 'headRefName': 'x',
           'body': 'Closes #5', 'comments': [], 'statusCheckRollup': [], 'labels': []}


def row(number, labels=('ready-for-agent',)):
    out = issue_row(number, '2026-01-02T00:00:00Z')
    out['labels'] = [{'name': name} for name in labels]
    return out


def run_pass(issues, state, start=0, workers=(), prs=(), claimed=(), now=1, act_code=0):
    starts, edits = [], []
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        notices, bits = fw.issue_scan_pass(
            scan_config('/work/app'), state, now, list(workers),
            pr_fetch=lambda _r: None if prs is None else list(prs), list_issues=lambda _r: list(issues),
            list_claimed=lambda _r: [{'number': n} for n in claimed],
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=lambda command: starts.append(command) or start,
            act=lambda command: edits.append(command) or act_code,
        )
    return starts, edits, bits, notices


def base_state(**extra):
    state = {'issue_scan_backlog_sweep_at': 1}
    state.update(extra)
    return state


class DeliveredRefusal(unittest.TestCase):
    def test_reason_is_parsed(self):
        self.assertEqual(fw.start_delivered_refusal(DELIVERED.reason), 'delivered by merged PR #10055')
        self.assertEqual(fw.start_delivered_refusal('already delivered by merged PR #1, #2'), 'delivered by merged PR #1 #2')
        self.assertIsNone(fw.start_delivered_refusal('consumer_fenced'))

    def test_refusal_is_deferred_with_its_reason_not_parked(self):
        state = base_state()
        _starts, edits, bits, _n = run_pass([row(5)], state, start=DELIVERED)
        entry = state['issue_scan_deferred'][REPO]['5']
        self.assertEqual(entry['reason'], 'delivered by merged PR #10055')
        self.assertIn('issue_start_delivered=5', bits)
        self.assertFalse(any('needs-triage' in c for c in edits), edits)
        self.assertNotIn(5, state.get('issue_scan_started', {}).get(REPO, []))

    def test_third_pass_escalates_to_elon(self):
        state = base_state()
        notices = []
        for now in (1, 2, 3):
            *_, notices = run_pass([row(5)], state, start=DELIVERED, now=now)
        self.assertTrue(any('deferred 3 passes' in str(n) and 'delivered' in str(n) for n in notices), notices)


class StartedRestart(unittest.TestCase):
    def test_ready_started_issue_starts_again_and_stays_recorded(self):
        state = base_state(issue_scan_started={REPO: [5]})
        starts, _e, bits, notices = run_pass([row(5)], state)
        self.assertEqual(len(starts), 1)
        self.assertIn('issue_restart=5:ready', bits)
        self.assertTrue(any('#5 restarted' in str(n) for n in notices), notices)
        self.assertEqual(state['issue_scan_started'][REPO], [5])

    def test_recent_start_blocks_until_the_grace_ends(self):
        state = base_state()
        starts, *_ = run_pass([row(5)], state, now=100)
        self.assertEqual(len(starts), 1)
        starts, edits, _b, _n = run_pass([row(5)], state, claimed=[5], now=101)
        self.assertEqual((starts, edits), ([], []))
        starts, *_ = run_pass([row(5)], state, now=100 + fw.ISSUE_RESTART_GRACE_SECONDS)
        self.assertEqual(len(starts), 1)

    def test_open_pr_still_blocks(self):
        state = base_state(issue_scan_started={REPO: [5]})
        starts, _e, bits, _n = run_pass([row(5)], state, prs=[OPEN_PR])
        self.assertEqual(starts, [])
        self.assertEqual(state['issue_scan_started'][REPO], [5])

    def test_live_worker_still_blocks(self):
        state = base_state(issue_scan_started={REPO: [5]})
        worker = {'_task_title': '#5|fullstack-dev', 'status': 'running'}
        with patch.object(fw, 'worker_row_is_live', return_value=True):
            starts, edits, _b, _n = run_pass([row(5)], state, workers=[worker], claimed=[5])
        self.assertEqual(starts, [])
        self.assertEqual(edits, [])
        self.assertEqual(state['issue_scan_started'][REPO], [5])

    def test_orphaned_claimed_issue_is_relabelled_then_started_next_pass(self):
        state = base_state(issue_scan_started={REPO: [5]})
        starts, edits, bits, _n = run_pass([], state, claimed=[5])
        self.assertEqual(starts, [])
        self.assertIn(['gh', 'issue', 'edit', '5', '--repo', REPO,
                       '--add-label', 'ready-for-agent', '--remove-label', 'status:進行中'], edits)
        self.assertIn('issue_restart=5:orphaned', bits)
        self.assertEqual(state['issue_scan_started'][REPO], [])
        starts2, *_ = run_pass([row(5)], state, now=2)
        self.assertEqual(len(starts2), 1)

    def test_unreadable_pr_list_blocks_both_restarts(self):
        state = base_state(issue_scan_started={REPO: [5]})
        starts, edits, bits, _n = run_pass([row(5)], state, prs=None)
        self.assertEqual(starts, [])
        self.assertIn('issue_restart_skipped=5:pr_list', bits)
        _s, edits, bits, _n = run_pass([], state, claimed=[5], prs=None)
        self.assertEqual(edits, [])
        self.assertIn('issue_restart_skipped=5:pr_list', bits)
        self.assertEqual(state['issue_scan_started'][REPO], [5])

    def test_failed_relabel_keeps_the_issue_in_started(self):
        state = base_state(issue_scan_started={REPO: [5]})
        _s, _e, bits, _n = run_pass([], state, claimed=[5], act_code=1)
        self.assertEqual(state['issue_scan_started'][REPO], [5])
        self.assertNotIn('issue_restart=5:orphaned', bits)

    def test_blocked_started_issue_is_not_restarted(self):
        state = base_state(issue_scan_started={REPO: [5]})
        with patch.object(fw, 'issue_open_blockers', return_value=([(REPO, 3)], [])):
            starts, _e, bits, notices = run_pass([row(5)], state)
        self.assertEqual(starts, [])
        self.assertNotIn('issue_restart=5:ready', bits)
        self.assertFalse(any('restarted' in str(n) for n in notices), notices)
        self.assertEqual(state['issue_scan_started'][REPO], [5])

    def test_orphan_with_open_pr_or_not_started_is_left_alone(self):
        state = base_state(issue_scan_started={REPO: [5]})
        _s, edits, _b, _n = run_pass([], state, claimed=[5], prs=[OPEN_PR])
        self.assertEqual(edits, [])
        _s, edits, _b, _n = run_pass([], base_state(issue_scan_started={REPO: [6]}), claimed=[5])
        self.assertEqual(edits, [])


if __name__ == '__main__':
    unittest.main()
