import sys
import importlib.util
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

CONFIG = {'host_caps': {'local': 5, 'niteking': 5, 'blueDevil': 5}}


def settled_row(i):
    """Flat worker-list row: succeeded, terminal still retained, no resource, no worktree on disk."""
    return {
        'dispatchId': 'ctx_settled_%d' % i, 'taskId': 'task_s%d' % i,
        'state': 'succeeded', 'liveness': 'unverifiable', 'terminalState': 'retained',
        'workspace': 'repo::/nonexistent/settled-%d' % i, 'host': 'local',
    }


def live_row():
    return {
        'dispatchId': 'ctx_live', 'taskId': 'task_live',
        'state': 'ready', 'outcome': 'in_progress', 'liveness': 'live', 'terminalState': 'retained',
        'workspace': 'repo::/nonexistent/live', 'host': 'local',
    }


class SettledRowsHoldNoSeat(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.10',
            'FLEET_WATCH_TEST_FREE_GB': '16.0',
        })
        env.start()
        self.addCleanup(env.stop)

    def test_34_settled_plus_1_live_is_admitted_under_cap_5(self):
        workers = [settled_row(i) for i in range(34)] + [live_row()]
        receipt = fw.admit('local', CONFIG, workers=workers)
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 1)
        self.assertEqual(receipt['live_count'], 1)

    def test_full_local_overflows_to_first_admitted_remote(self):
        live = []
        for i in range(5):
            row = live_row()
            row['dispatchId'] = 'ctx_live_%d' % i
            row['taskId'] = 'task_live_%d' % i
            live.append(row)
        workers = [settled_row(i) for i in range(34)] + live
        receipt = fw.admit('local', CONFIG, workers=workers)
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 5)
        self.assertEqual(receipt['overflow_host'], 'niteking')


def retained_user_requested_row(i, path='/Users/x/orca/workspaces/repo/gone-%d'):
    """Live coordinator shape: succeeded, terminal retained by user request, owned resource, not live, worktree gone."""
    path = path % i if '%d' in path else path
    return {
        'dispatchId': 'ctx_ret_%d' % i, 'taskId': 'task_r%d' % i,
        'workerState': 'succeeded', 'dispatchStatus': 'completed', 'terminalState': 'retained',
        'resource': {'id': 'wtr_%d' % i, 'ownershipState': 'owned', 'releaseState': 'retained',
                     'retainedReason': 'user_requested', 'worktreeId': 'wt::' + path},
        'projection': {'host': {'kind': 'local', 'id': 'local'}, 'workspace': {'id': 'wt::' + path},
                       'liveness': {'verdict': 'unverifiable', 'reason': 'missing_status'},
                       'resource': {'state': 'owned'}},
    }


class RetainedRowsHoldSeatOnlyWhileLive(unittest.TestCase):
    def setUp(self):
        env = patch.dict(os.environ, {'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.10', 'FLEET_WATCH_TEST_FREE_GB': '16.0'})
        env.start()
        self.addCleanup(env.stop)

    def test_33_user_requested_retained_gone_worktrees_hold_no_seat(self):
        workers = [retained_user_requested_row(i) for i in range(33)] + [live_row()]
        receipt = fw.admit('local', CONFIG, workers=workers)
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 1)

    def test_retained_row_with_dirty_worktree_keeps_seat(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'a', 'b', 'wt')
            os.makedirs(path)
            subprocess.check_call(['git', '-C', path, 'init', '-q', '-b', 'main'])
            with open(os.path.join(path, 'x'), 'w') as handle:
                handle.write('x')
            receipt = fw.admit('local', CONFIG, workers=[retained_user_requested_row(0, path)])
            self.assertEqual(receipt['occupied'], 1)

    def test_retained_row_with_live_terminal_keeps_seat(self):
        row = retained_user_requested_row(0)
        row['projection']['liveness'] = {'verdict': 'live'}
        self.assertEqual(fw.admit('local', CONFIG, workers=[row])['occupied'], 1)


if __name__ == '__main__':
    unittest.main()
