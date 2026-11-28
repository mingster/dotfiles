import sys
import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

CONFIG = {'host_caps': {'local': 5, 'remote-1': 3}}


def exited_unreleased_row(status, outcome):
    """Settled worker: liveness exited, terminal not released, Orca still lists an owned resource."""
    return {
        'dispatchId': 'ctx_%s' % status, 'taskId': 'task_%s' % status,
        'dispatchStatus': status, 'outcome': outcome,
        'projection': {'liveness': {'verdict': 'exited'}, 'host': 'remote-1'},
        'terminalState': 'retained', 'host': 'remote-1',
        'resource': {'id': 'wtr_%s' % status, 'ownershipState': 'owned', 'releaseState': 'retained',
                     'retainedReason': 'user_requested', 'worktreeId': 'wt::/nonexistent/%s' % status},
        'workspace': 'repo::/nonexistent/%s' % status,
    }


class SettledExitedWorkerHoldsNoSeat(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.10',
            'FLEET_WATCH_TEST_FREE_GB': '16.0',
        })
        env.start()
        self.addCleanup(env.stop)

    def test_exited_unreleased_settled_worker_is_not_occupied(self):
        for status, outcome in (('completed', 'succeeded'), ('failed', 'failed'), ('cancelled', 'cancelled')):
            with self.subTest(status=status):
                receipt = fw.admit('remote-1', CONFIG, workers=[exited_unreleased_row(status, outcome)])
                self.assertEqual(receipt['occupied'], 0, receipt)
                self.assertTrue(receipt['admitted'])

    def test_exited_dispatched_worker_still_holds_seat(self):
        receipt = fw.admit('remote-1', CONFIG, workers=[exited_unreleased_row('running', 'in_progress')])
        self.assertEqual(receipt['occupied'], 1)


if __name__ == '__main__':
    unittest.main()
