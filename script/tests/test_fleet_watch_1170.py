"""#1170: Orca fences a worker start from fleet-watch's terminal. The start is handed to the coordinator."""
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

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import test_fleet_watch_park as park  # noqa: E402
from test_fleet_watch_park import HEAD, REPO, issue_row, scan_config  # noqa: E402

FENCED = fw.BabysitStartResult(
    1,
    'consumer_fenced: worker-start needs the coordinator bound to the Run or a worker on an active Dispatch in it',
)


class FencedStartHandoff(unittest.TestCase):
    def setUp(self):
        fleet_env.guard_gh_writes(self)
        gh = patch.object(fw, 'run_gh', return_value=0)
        gh.start()
        self.addCleanup(gh.stop)

    def test_issue_start_is_handed_to_the_coordinator_with_the_ready_command(self):
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            rows = [issue_row(5, '2026-01-01T00:00:00Z')]
            starts = []

            def start_worker(command):
                starts.append(command)
                return FENCED

            common = dict(
                pr_fetch=lambda _repo: [],
                list_issues=lambda _repo: rows,
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
            )
            notices, _log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
            self.assertEqual(len(notices), 1, notices)
            text = str(notices[0])
            self.assertTrue(text.startswith('handoff issue %s#5' % REPO), text)
            self.assertIn('coordinator', text)
            self.assertIn('--run run_x', text)
            self.assertIn('worker-startup.sh', text)
            self.assertNotIn('parked', text)
            self.assertIsInstance(notices[0], fw.Urgent)
            fw.issue_scan_pass(scan_config(root), state, 2, [], **common)
            self.assertEqual(len(starts), 1, 'a handed off start is not tried again')

    def test_verifier_start_is_handed_to_the_coordinator(self):
        with tempfile.TemporaryDirectory() as root:
            notices, _lines, _log, starts = park.VerifierPark('pass_with').pass_with({}, FENCED, root, HEAD, 1)
            self.assertEqual(starts, [1])
            self.assertEqual(len(notices), 1, notices)
            self.assertTrue(str(notices[0]).startswith('handoff verifier %s#7' % REPO), notices)
            self.assertIn('--run run_live', str(notices[0]))

    def _scan(self, result):
        with tempfile.TemporaryDirectory() as root:
            edits = []
            _n, log = fw.issue_scan_pass(
                scan_config(root), {'issue_scan_backlog_sweep_at': 1}, 1, [],
                pr_fetch=lambda _repo: [],
                list_issues=lambda _repo: [issue_row(5, '2026-01-01T00:00:00Z')],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda _c: result,
                act=lambda argv: edits.append(argv),
            )
            return edits, log

    def test_gate_refusals_defer_and_keep_ready_for_agent(self):
        for reason in (
            'refused: dotfiles issue 12 is ready and not started; start it first, or pass --skip-dotfiles-first REASON',
            'refused: o/r#5 overlaps other work in flight; bundle it into one issue, or pass --allow-overlap REASON',
        ):
            edits, log = self._scan(fw.BabysitStartResult(1, reason))
            self.assertFalse([e for e in edits if 'needs-triage' in e], edits)
            self.assertTrue(any('issue_start_deferred=5' in b for b in log), log)

    def test_real_start_failure_still_relabels_needs_triage(self):
        edits, log = self._scan(fw.BabysitStartResult(1, 'brief is broken'))
        self.assertTrue([e for e in edits if 'needs-triage' in e], edits)
        self.assertTrue(any('issue_start_fail=5' in b for b in log), log)

    def test_other_failures_still_say_parked(self):
        notice = fw.park_notice('issue', 'o/r#5', 'some other error', ['bash', 'x'])
        self.assertTrue(str(notice).startswith('parked issue o/r#5'), notice)


if __name__ == '__main__':
    unittest.main()
