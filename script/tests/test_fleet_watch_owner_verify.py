"""An owner-gated PR still gets a verifier; only ship waits for the owner."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

SCRIPT = Path(__file__).resolve().parents[1] / 'fleet-watch.py'
spec = importlib.util.spec_from_file_location('fleet_watch_owner_verify', SCRIPT)
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HEAD = 'b' * 40


class OwnerGatedVerifier(unittest.TestCase):
    def run_pass(self, state, rc=0):
        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {'o/r': root}},
                'babysit': {'repos': ['o/r'], 'startup': '/bin/true'},
            }
            pr = {
                'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': HEAD, 'headRefName': 'b',
                'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
                'comments': [{'body': 'Review: PASS head=%s' % HEAD}], 'labels': [], 'mergeable': 'MERGEABLE',
                'body': '## Self-check\n$ bash script/checks-local.sh\nexit 0\nBuilder: agent=claude model=sonnet',
            }
            notices, lines, _log = fw.babysit_pass(
                config, state, [], pr_fetch=lambda _repo: [pr],
                start_worker=lambda command: starts.append(command) or rc,
                pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
                owner_check=lambda _pr: 'PR touches .claude/hooks/x.py, which waits for the owner through Elon',
            )
        return starts, notices, lines

    def test_reports_once_and_starts_verifier(self):
        state = {}
        starts, notices, lines = self.run_pass(state)
        self.assertEqual(len(starts), 1, lines)
        self.assertEqual(len(notices), 1)
        self.assertIn('owner-only path', str(notices[0]))
        self.assertTrue(any('action=verifier' in line for line in lines), lines)

        starts, notices, lines = self.run_pass(state)
        self.assertEqual(starts, [])
        self.assertEqual(notices, [])

    def test_report_from_an_earlier_pass_does_not_block_the_verifier(self):
        state = {'babysit': {'o/r': {'7': {'head': HEAD, 'action': 'report'}}}}
        starts, notices, lines = self.run_pass(state)
        self.assertEqual(len(starts), 1, lines)
        self.assertEqual(notices, [])


if __name__ == '__main__':
    unittest.main()
