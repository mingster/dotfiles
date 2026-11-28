"""#1192: handoff lines carry no --from, and a host fault Checks FAIL is a rerun, not a rework."""
import sys
import importlib.util
import shlex
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_park import HEAD, REPO, scan_config  # noqa: E402

FENCED = fw.BabysitStartResult(1, 'consumer_fenced: worker-start needs the coordinator bound to the Run')

HOST_FAULT_COMMENT = (
    'Checks: FAIL head=%s\n\n'
    '## Database step\n'
    'Result: host fault; this host has no reachable local Postgres.\n'
)
ZERO_TESTS_COMMENT = (
    'Checks: FAIL head=%s\n\n'
    '## Database step\n'
    'Tests executed: 0\n'
    'Load errors: 0\n'
)
REAL_FAIL_COMMENT = (
    'Checks: FAIL head=%s\n\n'
    '## Database step\n'
    'Tests executed: 12\n'
    'Load errors: 0\n'
    'FAIL test_orders\n'
)


def checks_fail_pr(number, comment):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': False,
        'headRefOid': HEAD,
        'headRefName': 'feature/pr',
        'statusCheckRollup': [],
        'comments': [{'body': comment % HEAD, 'createdAt': '2026-11-19T10:00:00Z'}],
        'labels': [],
    }


class HandoffHasNoFrom(unittest.TestCase):
    def test_printed_line_leaves_out_the_fleet_watch_terminal(self):
        command = ['bash', 'worker-startup.sh', '--run', 'run_x', '--from', 'term_fleet_watch', '--name', 'issue-5']
        text = str(fw.park_notice('issue', 'o/r#5', 'consumer_fenced: x', command))
        self.assertNotIn('--from', text)
        self.assertNotIn('term_fleet_watch', text)
        line = text.split('coordinator: ', 1)[1]
        self.assertEqual(shlex.split(line), ['bash', 'worker-startup.sh', '--run', 'run_x', '--name', 'issue-5'])


class HostFaultIsARerun(unittest.TestCase):
    def run_scan(self, comment):
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            starts = []
            reruns = []
            common = dict(
                pr_fetch=lambda _repo: [checks_fail_pr(4, comment)],
                list_issues=lambda _repo: [],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda command: starts.append(command) or FENCED,
                start_detached=lambda command, *_a, **_k: reruns.append(command) or 0,
                checks_lock_live=lambda _root: False,
            )
            notices, log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
            again, _log = fw.issue_scan_pass(scan_config(root), state, 2, [], **common)
            return notices, again, log, starts

    def test_host_fault_comment_prints_a_rerun_line(self):
        notices, again, log, starts = self.run_scan(HOST_FAULT_COMMENT)
        self.assertEqual(starts, [], 'no rework worker for a host fault')
        texts = [str(n) for n in notices]
        self.assertTrue(any(t.startswith('rerun checks %s#4' % REPO) for t in texts), texts)
        self.assertFalse(any('rework' in t.replace('not a rework', '') for t in texts), texts)
        self.assertFalse(any(str(n).startswith('rerun checks') for n in again), 'one rerun line per head')

    def test_zero_tests_executed_prints_a_rerun_line(self):
        notices, _again, _log, starts = self.run_scan(ZERO_TESTS_COMMENT)
        self.assertEqual(starts, [])
        self.assertTrue(any(str(n).startswith('rerun checks') for n in notices), notices)

    def test_a_real_test_failure_is_still_a_rework(self):
        notices, _again, _log, starts = self.run_scan(REAL_FAIL_COMMENT)
        self.assertEqual(len(starts), 1, 'a real failure still starts a rework')
        self.assertFalse(any(str(n).startswith('rerun checks') for n in notices), notices)


if __name__ == '__main__':
    unittest.main()
