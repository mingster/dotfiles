"""#1258: a start refused only by the usage gate keeps ready-for-agent. Other start failures still go to needs-triage."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_1258', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_1204 import fake_rpc  # noqa: E402
from test_fleet_watch_park import scan_config  # noqa: E402
from test_fleet_watch_1216 import row  # noqa: E402


def scan(result):
    edits = []

    def act(command):
        edits.append(command)
        return 0

    state = {'issue_scan_backlog_sweep_at': 1}
    with patch.object(fw, 'rpc', side_effect=fake_rpc):
        _n, bits = fw.issue_scan_pass(
            scan_config('/work/app'), state, 1, [], pr_fetch=lambda _r: [], list_issues=lambda _r: [row(1)],
            gate_check=lambda _c: True, admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
            start_worker=lambda _command: result, act=act, repo_id_lookup=lambda _h, _r: 'repo-id',
        )
    demoted = [e for e in edits if 'needs-triage' in e]
    return demoted, bits


class GateRefusalKeepsReady(unittest.TestCase):
    def test_gate_exit_code_keeps_ready(self):
        demoted, _bits = scan(fw.BabysitStartResult(3, 'worker-startup: refused by the usage gate'))
        self.assertEqual(demoted, [])

    def test_gate_refusal_text_under_another_exit_code_keeps_ready(self):
        demoted, bits = scan(fw.BabysitStartResult(1, 'worker-startup: refused by the usage gate'))
        self.assertEqual(demoted, [])
        self.assertTrue(any(b.startswith('issue_start_deferred=') for b in bits), bits)

    def test_other_failure_still_goes_to_needs_triage(self):
        demoted, bits = scan(fw.BabysitStartResult(1, 'worktree create failed'))
        self.assertEqual(len(demoted), 1)
        self.assertTrue(any(b.startswith('issue_start_fail=') for b in bits), bits)


if __name__ == '__main__':
    unittest.main()
