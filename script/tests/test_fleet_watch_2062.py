"""#2062: issue_scan skips starts that worker-startup would refuse, so the pass spends its start budget on startable issues."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fleet_watch_test_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fleet_watch_test_env)

spec = importlib.util.spec_from_file_location('fleet_watch_2062', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

sys.path.insert(0, str(Path(__file__).parent))
from test_fleet_watch_1204 import fake_rpc, live_worker  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402

OVERLAP = fw.BabysitStartResult(2, 'worker-startup: refused: #20 overlaps other work in flight; bundle it')


def run_pass(rows, workers=(), prs=(), state=None, results=None, now=1):
    """One pass. results maps an issue number to the start result; any other start succeeds."""
    starts = []
    state = {'issue_scan_backlog_sweep_at': 1} if state is None else state

    def start(command):
        number = int(command[command.index('--title') + 1].split('|')[0].lstrip('#'))
        starts.append(number)
        return (results or {}).get(number, 0)

    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            scan_config('/work/app'), state, now, list(workers),
            pr_fetch=lambda _r: list(prs), list_issues=lambda _r: list(rows),
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=start, act=lambda _c: 0,
        )
    return starts, bits, state


class SkipKnownRefusals(unittest.TestCase):
    def setUp(self):
        fleet_watch_test_env.guard_gh_writes(self)
        gh = patch.object(fw, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)

    def test_live_worker_issue_never_reaches_worker_startup(self):
        rows = [row(10), row(11)]
        starts, bits, _s = run_pass(rows, workers=[live_worker('#10|fullstack-dev')])
        self.assertNotIn(10, starts)
        self.assertIn(11, starts)
        self.assertIn('issue_live=10', bits)

    def test_issue_whose_brief_refs_a_live_issue_is_skipped_and_logged(self):
        bundled = row(12)
        bundled['body'] = 'Do the thing.\n\nRefs #10\n\n## Acceptance\n- [ ] done\n'
        starts, bits, _s = run_pass([bundled, row(13)], workers=[live_worker('#10|fullstack-dev')])
        self.assertEqual(starts, [13])
        self.assertIn('issue_live=12:ref=10', bits)

    def test_overlap_refusal_is_not_retried_while_nothing_changed(self):
        rows = [row(20), row(21)]
        state = {'issue_scan_backlog_sweep_at': 1}
        starts, _bits, state = run_pass(rows, state=state, results={20: OVERLAP}, now=1)
        self.assertEqual(starts, [20, 21])
        starts, bits, state = run_pass(rows, state=state, results={20: OVERLAP}, now=2)
        self.assertEqual(starts, [])  # 21 started on pass 1
        self.assertIn('issue_deferred=20:overlap_held', bits)

    def test_overlap_refusal_retries_when_the_open_pr_set_changes(self):
        rows = [row(20)]
        state = {'issue_scan_backlog_sweep_at': 1}
        run_pass(rows, state=state, results={20: OVERLAP}, now=1)
        starts, _bits, _s = run_pass(rows, state=state, prs=[{'number': 5, 'headRefOid': 'abc'}], results={20: OVERLAP}, now=2)
        self.assertEqual(starts, [20])

    def test_overlap_refusal_retries_when_the_body_changes(self):
        state = {'issue_scan_backlog_sweep_at': 1}
        run_pass([row(20)], state=state, results={20: OVERLAP}, now=1)
        edited = row(20)
        edited['body'] = row(20)['body'].replace('prove it', 'prove it twice')
        starts, _bits, _s = run_pass([edited], state=state, results={20: OVERLAP}, now=2)
        self.assertEqual(starts, [20])

    def test_overlap_refusal_retries_after_the_hold_passes(self):
        rows = [row(20)]
        state = {'issue_scan_backlog_sweep_at': 1}
        run_pass(rows, state=state, results={20: OVERLAP}, now=1)
        tried = []
        for n in range(2, 2 + fw.OVERLAP_HOLD_PASSES + 1):
            starts, _b, _s = run_pass(rows, state=state, results={20: OVERLAP}, now=n)
            tried.append(bool(starts))
        self.assertEqual(tried, [False] * fw.OVERLAP_HOLD_PASSES + [True])

    def test_budget_goes_to_startable_issues(self):
        """One live-worker issue and one overlap-held issue: both ready startable issues start."""
        rows = [row(10), row(20), row(30), row(31)]
        state = {'issue_scan_backlog_sweep_at': 1}
        run_pass(rows[:2], workers=[live_worker('#10|fullstack-dev')], state=state, results={20: OVERLAP}, now=1)
        starts, bits, _s = run_pass(rows, workers=[live_worker('#10|fullstack-dev')], state=state, results={20: OVERLAP}, now=2)
        self.assertEqual(starts, [30, 31])
        self.assertIn('issue_live=10', bits)
        self.assertIn('issue_deferred=20:overlap_held', bits)


if __name__ == '__main__':
    unittest.main()
