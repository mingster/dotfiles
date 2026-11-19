"""#1228: a relayed remote worker_done that the coordinator rejected as unknown_dispatch is settled by fleet-watch."""
import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

SERVER = {'environmentId': 'env-1', 'name': 'remote-host', 'asOf': '2026-11-19T12:29:20Z'}


def remote_row(dispatch):
    return {
        'dispatchId': dispatch, 'taskId': 'task_x', 'runId': 'run_x', 'workerState': 'succeeded',
        'dispatchStatus': 'completed', 'agentTerminalHandle': None, 'terminalState': None,
        'resource': None, 'server': SERVER,
    }


def concise_rejection(dispatch):
    """inbox --json without --full: payload keeps ids only, the rejection shows in subject and body."""
    return {
        'id': 'msg_1', 'type': 'worker_done', 'priority': 'high',
        'subject': 'Rejected worker_done: repro done',
        'body': 'Orca rejected this worker_done: worker_done references unknown dispatch %s.\n\nOriginal body:\n...' % dispatch,
        'payload': {'taskId': 'task_x', 'dispatchId': dispatch},
    }


def full_rejection(dispatch):
    """inbox --json --full: payload is a JSON string carrying _orcaLifecycleRejection."""
    return {
        'id': 'msg_2', 'type': 'worker_done', 'priority': 'high', 'subject': 'done', 'body': '',
        'payload': json.dumps({'taskId': 'task_x', 'dispatchId': dispatch, 'outcome': 'succeeded',
                               '_orcaLifecycleRejection': {'code': 'unknown_dispatch', 'reason': 'x'}}),
    }


class Recorder:
    def __init__(self):
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        return {}


class RejectedRemoteWorkerDone(unittest.TestCase):
    def assert_settled(self, rejection):
        rec, messages = Recorder(), [rejection]
        notices = fw.reconcile_remote_completions({}, {}, [remote_row('ctx_r')], messages, rec)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_r', '--environment', 'env-1'), rec.calls)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_r'), rec.calls)
        accepted = [m for m in messages if m['type'] == 'worker_done' and not fw.worker_done_rejected(m)]
        self.assertEqual([fw._message_payload(m)['dispatchId'] for m in accepted], ['ctx_r'])
        self.assertEqual(len(notices), 1)
        self.assertIn('ctx_r', notices[0])
        self.assertIn('no hand release', notices[0])

    def test_concise_inbox_rejection_is_settled(self):
        self.assert_settled(concise_rejection('ctx_r'))

    def test_full_inbox_rejection_is_settled(self):
        self.assert_settled(full_rejection('ctx_r'))

    def test_accepted_worker_done_is_not_rejected(self):
        message = {'type': 'worker_done', 'subject': 'PR #7 green', 'body': 'done',
                   'payload': {'dispatchId': 'ctx_r', 'outcome': 'succeeded'}}
        self.assertFalse(fw.worker_done_rejected(message))

    def test_other_rejection_codes_are_left_alone(self):
        message = {'type': 'worker_done', 'payload': json.dumps({
            'dispatchId': 'ctx_r', '_orcaLifecycleRejection': {'code': 'worker_identity_changed'}})}
        self.assertFalse(fw.worker_done_rejected(message))


if __name__ == '__main__':
    unittest.main()
