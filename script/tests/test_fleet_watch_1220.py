"""#1220: a remote worker's settled dispatch is reconciled on the coordinator."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

SERVER = {'environmentId': 'env-1', 'name': 'remote-host', 'asOf': '2026-11-19T09:00:00Z'}


def remote_row(dispatch, state='succeeded', pr=None):
    """Worker-list --include-remote row for a settled remote dispatch: no terminal, no resource key."""
    row = {
        'dispatchId': dispatch, 'taskId': 'task_x', 'runId': 'run_x',
        'workerState': state, 'dispatchStatus': 'completed', 'server': SERVER,
    }
    if pr:
        row['githubPullRequestNumber'] = pr
    return row


class Recorder:
    def __init__(self):
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        return {}


class ReconcileRemoteCompletions(unittest.TestCase):
    def test_synthesizes_worker_done_for_settled_remote_row(self):
        messages, state = [], {}
        fw.reconcile_remote_completions({}, state, [remote_row('ctx_a', pr=7)], messages, Recorder())
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]['type'], 'worker_done')
        payload = fw._message_payload(messages[0])
        self.assertEqual(payload['dispatchId'], 'ctx_a')
        self.assertEqual(fw._message_outcome(messages[0], payload), 'succeeded')
        self.assertIn('ctx_a', state['remote_reconciled'])

    def test_skips_when_worker_done_already_arrived(self):
        messages = [{'id': 'm1', 'type': 'worker_done', 'payload': {'dispatchId': 'ctx_a', 'outcome': 'succeeded'}}]
        fw.reconcile_remote_completions({}, {}, [remote_row('ctx_a', pr=7)], messages, Recorder())
        self.assertEqual(len(messages), 1)

    def test_runs_once_per_dispatch(self):
        messages, state = [], {}
        fw.reconcile_remote_completions({}, state, [remote_row('ctx_a', pr=7)], messages, Recorder())
        fw.reconcile_remote_completions({}, state, [remote_row('ctx_a', pr=7)], messages, Recorder())
        self.assertEqual(len(messages), 1)

    def test_ignores_local_and_running_rows(self):
        local = {'dispatchId': 'ctx_l', 'workerState': 'succeeded', 'dispatchStatus': 'completed',
                 'projection': {'host': {'id': 'local'}}}
        running = remote_row('ctx_r')
        running.update(workerState='running', dispatchStatus='running')
        messages = []
        fw.reconcile_remote_completions({}, {}, [local, running], messages, Recorder())
        self.assertEqual(messages, [])

    def test_no_pr_task_is_released_on_remote_and_coordinator_with_notice(self):
        rec, messages = Recorder(), []
        notices = fw.reconcile_remote_completions({}, {}, [remote_row('ctx_n')], messages, rec)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_n', '--environment', 'env-1'), rec.calls)
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_n'), rec.calls)
        self.assertEqual(len(notices), 1)

    def test_failed_remote_worker_is_failed_outcome_and_released(self):
        rec, messages = Recorder(), []
        notices = fw.reconcile_remote_completions({}, {}, [remote_row('ctx_f', state='failed', pr=9)], messages, rec)
        payload = fw._message_payload(messages[0])
        self.assertEqual(fw._message_outcome(messages[0], payload), 'failed')
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_f'), rec.calls)
        self.assertEqual(len(notices), 1)

    def test_pr_task_is_left_for_release_green_successes(self):
        rec = Recorder()
        notices = fw.reconcile_remote_completions({}, {}, [remote_row('ctx_p', pr=7)], [], rec)
        self.assertEqual(rec.calls, [])
        self.assertEqual(notices, [])

    def test_unsettled_home_row_is_stopped_before_release(self):
        row = remote_row('ctx_s', state='succeeded')
        row['dispatchStatus'] = 'running'
        rec = Recorder()
        fw.reconcile_remote_completions({}, {}, [row], [], rec)
        order = [c[1] for c in rec.calls]
        self.assertEqual(order[0], 'worker-stop')
        self.assertIn('worker-release', order)

    def test_release_error_does_not_raise(self):
        def boom(*_a):
            raise OSError('x')
        fw.reconcile_remote_completions({}, {}, [remote_row('ctx_n')], [], boom)


class ReleaseWorkerEnvironment(unittest.TestCase):
    def test_default_release_passes_environment_for_remote(self):
        with patch.object(fw, 'rpc') as rpc:
            fw._default_release_worker('ctx_a', 'env-1')
        rpc.assert_any_call('orchestration', 'worker-release', '--dispatch', 'ctx_a', '--environment', 'env-1')
        rpc.assert_any_call('orchestration', 'worker-release', '--dispatch', 'ctx_a')

    def test_default_release_local_unchanged(self):
        with patch.object(fw, 'rpc') as rpc:
            fw._default_release_worker('ctx_a')
        rpc.assert_called_once_with('orchestration', 'worker-release', '--dispatch', 'ctx_a')


class RemoteSeatFreed(unittest.TestCase):
    def test_settled_remote_row_is_freed(self):
        occupies, info, _ = fw.classify_worker(remote_row('ctx_a', pr=7), None, {}, {})
        self.assertFalse(occupies)
        self.assertEqual(info['category'], 'freed')

    def test_running_remote_row_still_occupies(self):
        row = remote_row('ctx_a')
        row.update(workerState='running', dispatchStatus='running')
        occupies, _, _ = fw.classify_worker(row, None, {}, {})
        self.assertTrue(occupies)


if __name__ == '__main__':
    unittest.main()
