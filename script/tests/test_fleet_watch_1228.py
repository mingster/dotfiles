"""#1228: a relayed remote worker_done that the coordinator rejected as unknown_dispatch is settled by fleet-watch."""
import sys
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

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


def unknown_task_rejection(dispatch, full=True):
    if full:
        return {'id': 'msg_3', 'type': 'worker_done', 'subject': 'done', 'body': '',
                'payload': json.dumps({'taskId': 'task_x', 'dispatchId': dispatch, 'outcome': 'succeeded',
                                       '_orcaLifecycleRejection': {'code': 'unknown_task', 'reason': 'x'}})}
    return {'id': 'msg_4', 'type': 'worker_done', 'subject': 'Rejected', 'payload': {'dispatchId': dispatch},
            'body': 'Orca rejected this worker_done: worker_done references unknown task task_x.'}


class UnknownTaskRejection(unittest.TestCase):
    def test_unknown_task_is_rejected_both_views(self):
        self.assertTrue(fw.worker_done_rejected(unknown_task_rejection('ctx_r', full=True)))
        self.assertTrue(fw.worker_done_rejected(unknown_task_rejection('ctx_r', full=False)))

    def test_unknown_task_rejection_is_settled_and_released(self):
        rec, messages = Recorder(), [unknown_task_rejection('ctx_r')]
        notices = fw.reconcile_remote_completions({}, {}, [remote_row('ctx_r')], messages, rec)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_r'), rec.calls)
        self.assertEqual(len(notices), 1)
        self.assertIn('no hand release', notices[0])

    def test_rejected_copy_does_not_release_or_bounce(self):
        worker = remote_row('ctx_r')
        worker['githubPullRequestNumber'] = 7
        worker.pop('resource')
        released = []
        with patch.object(fw, 'repo_for_worker', return_value='o/r'), \
                patch.object(fw, 'pr_checks_all_success', return_value=True):
            fw.release_green_successes([dict(unknown_task_rejection('ctx_r'), payload={'dispatchId': 'ctx_r', 'outcome': 'succeeded', '_orcaLifecycleRejection': {'code': 'unknown_task'}})], [worker], {}, {},
                                       (lambda row: released.append(row['dispatchId']) or 'closed'), lambda *_: {'x': 1})
        self.assertEqual(released, [])


class RejectedDispatchMissingFromWorkerList(unittest.TestCase):
    def test_worker_show_settles_and_releases(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if args[:2] == ('orchestration', 'worker-show'):
                return {'worker': {'state': 'succeeded', 'status': 'completed', 'server': SERVER}}
            return {}
        workers, state = [], {}
        notices = fw.reconcile_remote_completions({}, state, workers, [full_rejection('ctx_gone')], rpc)
        self.assertIn(('orchestration', 'worker-show', '--dispatch', 'ctx_gone'), calls)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_gone', '--environment', 'env-1'), calls)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_gone'), calls)
        self.assertEqual(len(notices), 1)
        self.assertIn('ctx_gone', state['remote_reconciled'])

    def test_unshowable_dispatch_is_skipped(self):
        rec = Recorder()
        notices = fw.reconcile_remote_completions({}, {}, [], [full_rejection('ctx_gone')], rec)
        self.assertEqual(notices, [])
        self.assertEqual([c for c in rec.calls if c[1] == 'worker-release'], [])


if __name__ == '__main__':
    unittest.main()
