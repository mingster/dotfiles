import importlib.util
import os
import unittest
from unittest.mock import patch
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HOST_CONFIG = {'host_caps': {'local': 1}}
SERVER = {'environmentId': 'env', 'name': 'host', 'asOf': '2026-11-13T09:19:01Z'}


def gone_row(dispatch):
    """Worker-list --full row for a dispatch Orca already released (ctx_d892381772db shape)."""
    return {
        'dispatchId': dispatch, 'taskId': 'task_x', 'runId': 'run_x',
        'workerState': 'succeeded', 'dispatchStatus': 'completed',
        'agentTerminalHandle': None, 'terminalState': None, 'resource': None,
        'server': SERVER,
    }


def released_verifier_row(dispatch):
    """Completed no-push worker whose resource Orca released, without a projection."""
    return {
        'dispatchId': dispatch, 'taskId': 'task_y', 'runId': 'run_x',
        'workerState': 'succeeded', 'dispatchStatus': 'completed',
        'agentTerminalHandle': 'term_x', 'terminalState': 'released',
        'resource': {
            'id': 'wtr_x', 'ownershipState': 'released', 'releaseState': 'released',
            'retainedReason': None, 'terminalHandle': 'term_x',
            'releaseCompletedAt': '2026-11-13 11:03:29', 'releaseError': None,
        },
        'server': SERVER,
    }


def unreleased_row(dispatch):
    return {
        'dispatchId': dispatch, 'taskId': 'task_z', 'runId': 'run_x',
        'workerState': 'succeeded', 'dispatchStatus': 'completed',
        'agentTerminalHandle': 'term_y', 'terminalState': 'release_pending',
        'resource': {'id': 'wtr_y', 'ownershipState': 'owned', 'releaseState': 'pending',
                     'retainedReason': 'unpushed'},
        'server': SERVER,
    }


class ReleasedDispatchesHoldNoSeat(unittest.TestCase):
    def setUp(self):
        # Pin host load and free memory so a busy coordinator cannot fail admission.
        env = patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.10',
            'FLEET_WATCH_TEST_FREE_GB': '16.0',
        })
        env.start()
        self.addCleanup(env.stop)

    def test_already_released_rows_hold_no_seat(self):
        receipt = fw.admit('local', HOST_CONFIG, workers=[gone_row('d1'), released_verifier_row('d2')])
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 0)

    def test_completed_unreleased_worker_still_holds_its_seat(self):
        receipt = fw.admit('local', HOST_CONFIG, workers=[unreleased_row('d3')])
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 1)

    def test_freed_evidence_reports_real_pushed_value(self):
        _, info, _ = fw.classify_worker(released_verifier_row('d2'))
        self.assertEqual(info['category'], 'freed')
        self.assertIs(info['evidence']['pushed'], False)
        _, info, _ = fw.classify_worker(dict(released_verifier_row('d4'), pushed=True))
        self.assertIs(info['evidence']['pushed'], True)


if __name__ == '__main__':
    unittest.main()
