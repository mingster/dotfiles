"""Three short supply passes in a row force the supply worker, clear stale blocked labels and hand it stale claims (#1876)."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_1876', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402
import test_fleet_watch_triage as triage  # noqa: E402  (a module import keeps its TestCases out of this file)
NOW, pick = triage.NOW, triage.pick

REPO = scan_config('/work/app')['issue_scan']['repos'][0]
ORDER = {'min_active': 3, 'target_workers': 10}
BRIEF = Path(__file__).parent.parent.parent / 'docs/agents/supply-worker-brief.md'


def live(n, title='#99|fullstack-dev'):
    return triage.TriageWorker.live(None, n, title=title)


def run_pass(state, issues=(), workers=(), open_count=5, blocked=(), ref_states=None, claimed=(), acts=None, now=NOW):
    config = scan_config('/work/app')
    config['work_order'] = dict(ORDER)
    starts = []
    acts = [] if acts is None else acts

    def start(command):
        starts.append(command)
        return 0

    def act(command):
        acts.append(command)
        return 0

    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            config, state, now, list(workers), pr_fetch=lambda _r: [], list_issues=lambda _r: list(issues),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=start, act=act, repo_id_lookup=lambda _h, _r: 'repo-id',
            pick_fn=pick, list_backlog=lambda _r: 3,
            count_open=lambda _r: open_count, list_blocked=lambda _r: list(blocked),
            ref_state=lambda r, n: (ref_states or {}).get((r, n)), list_claimed=lambda _r: list(claimed),
        )
    supply = [c for c in starts if 'supply-architect-pm' in c]
    return supply, bits


def recent_state():
    # A supply worker started 10 minutes ago, so the interval still holds.
    return {'issue_scan_backlog_sweep_at': NOW, 'work_order_supply_at': NOW - 600}


class ShortPassCount(unittest.TestCase):
    def test_count_increments_on_short_passes_and_resets_when_supply_fills_the_seats(self):
        state = recent_state()
        for expected in (1, 2):
            supply, bits = run_pass(state)
            self.assertEqual(supply, [], bits)
            self.assertIn('supply_skip_recent', bits)
            self.assertEqual(state['work_order_short_passes'], expected)
        _s, bits = run_pass(state, issues=[row(n) for n in range(1, 4)], workers=live(7))
        self.assertIn('supply_enough=3:3', bits)
        self.assertEqual(state['work_order_short_passes'], 0)

    def test_third_short_pass_forces_supply_despite_the_interval(self):
        state = recent_state()
        run_pass(state)
        run_pass(state)
        supply, bits = run_pass(state)
        self.assertEqual(len(supply), 1, bits)
        self.assertIn('supply_force=3', bits)
        self.assertNotIn('supply_skip_recent', bits)
        self.assertEqual(state['work_order_supply_at'], NOW)
        self.assertEqual(state['work_order_short_passes'], 0)

    def test_forced_pass_still_respects_a_live_supply_worker(self):
        state = dict(recent_state(), work_order_short_passes=2)
        supply, bits = run_pass(state, workers=live(1, title='#0|architect-pm|supply'))
        self.assertEqual(supply, [])
        self.assertIn('supply_force=3', bits)
        self.assertIn('supply_skip_live', bits)
        self.assertEqual(state['work_order_short_passes'], 3)  # the next pass tries again

    def test_zero_open_issues_means_no_trigger(self):
        state = dict(recent_state(), work_order_short_passes=2)
        acts = []
        blocked = [{'number': 7, 'body': 'Blocked by #6'}]
        supply, bits = run_pass(state, open_count=0, blocked=blocked, ref_states={(REPO, 6): 'CLOSED'}, acts=acts)
        self.assertEqual(supply, [])
        self.assertIn('supply_force_no_issues', bits)
        self.assertIn('supply_skip_recent', bits)
        self.assertEqual(acts, [])

    def test_unreadable_open_count_is_not_zero_and_not_a_trigger(self):
        state = dict(recent_state(), work_order_short_passes=2)
        supply, bits = run_pass(state, open_count=None)
        self.assertEqual(supply, [])
        self.assertIn('supply_force_unknown', bits)


class StaleBlocked(unittest.TestCase):
    def clear(self, rows, states, edit_rc=0):
        acts = []

        def act(command):
            acts.append(command)
            return edit_rc if 'edit' in command else 0

        bits = fw.clear_stale_blocked([REPO], lambda _r: rows, lambda r, n: states.get((r, n)), act)
        return bits, acts

    def test_cleared_only_when_every_blocker_is_closed(self):
        rows = [
            {'number': 10, 'body': 'Blocked by #8\nBlocked by other/repo#3'},
            {'number': 11, 'body': '## Blocked by\n- #8\n- #9'},
        ]
        states = {(REPO, 8): 'CLOSED', ('other/repo', 3): 'CLOSED', (REPO, 9): 'OPEN'}
        bits, acts = self.clear(rows, states)
        self.assertEqual(bits, ['unblock=10'])
        self.assertEqual(acts[0], ['gh', 'issue', 'edit', '10', '--repo', REPO, '--remove-label', 'blocked'])
        self.assertEqual(acts[1][:4], ['gh', 'issue', 'comment', '10'])
        self.assertIn('#8, other/repo#3', acts[1][-1])
        self.assertEqual(len(acts), 2)

    def test_left_alone_when_unparseable_unknown_or_without_refs(self):
        rows = [
            {'number': 20, 'body': 'Blocked by the owner decision'},
            {'number': 21, 'body': 'Blocked by #8\nBlocked by the staging deploy'},
            {'number': 22, 'body': 'Blocked by #5'},
            {'number': 23, 'body': 'waiting on something'},
            {'number': 24, 'body': 'Blocked by #8', 'blockedBy': {'nodes': [{'state': 'OPEN'}]}},
        ]
        bits, acts = self.clear(rows, {(REPO, 8): 'CLOSED'})  # #5 unreadable
        self.assertEqual((bits, acts), ([], []))

    def test_failed_edit_does_not_comment(self):
        bits, acts = self.clear([{'number': 30, 'body': 'Blocked by #8'}], {(REPO, 8): 'CLOSED'}, edit_rc=1)
        self.assertEqual(bits, ['unblock_fail=30'])
        self.assertEqual(len(acts), 1)

    def test_merged_pr_reads_closed(self):
        class Proc:
            returncode = 0
            stdout = 'closed\n'
        self.assertEqual(fw.fetch_ref_state(REPO, 5, run=lambda *_a, **_k: Proc()), 'CLOSED')

    def test_forced_pass_clears_stale_blocked(self):
        state = dict(recent_state(), work_order_short_passes=2)
        acts = []
        _s, bits = run_pass(state, blocked=[{'number': 7, 'body': 'Blocked by #6'}], ref_states={(REPO, 6): 'CLOSED'}, acts=acts)
        self.assertIn('unblock=7', bits)
        self.assertIn(['gh', 'issue', 'edit', '7', '--repo', REPO, '--remove-label', 'blocked'], acts)


class SupplyBrief(unittest.TestCase):
    def test_brief_grills_the_coordinator_not_the_owner(self):
        text = BRIEF.read_text(encoding='utf-8')
        for needle in ('orca orchestration ask', 'ready-for-human', 'needs-triage', 'owner-decisions.sh',
                       'Never ask the owner directly', 'cost of B', 'status:進行中'):
            self.assertIn(needle, text)

    def test_stale_claims_are_listed_in_the_supply_brief(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        supply, bits = run_pass(state, claimed=[{'number': 41}, {'number': 42}],
                                workers=[dict(live(1)[0], _task_title='#42|fullstack-dev')])
        self.assertEqual(len(supply), 1, bits)
        text = Path(supply[0][supply[0].index('--spec') + 1]).read_text(encoding='utf-8')
        self.assertIn('## Claimed with no live worker\n\n- %s#41\n' % REPO, text)
        self.assertNotIn('#42\n', text.split('## Claimed with no live worker')[1])


if __name__ == '__main__':
    unittest.main()
