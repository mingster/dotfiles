"""#1220: a remote worker's settled dispatch is reconciled on the coordinator."""
import sys
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))  # sibling test modules, for path invocation
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

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
        order = [c[1] for c in rec.calls if c[1] in ('worker-stop', 'worker-release')]
        self.assertEqual(order[0], 'worker-stop')
        self.assertIn('worker-release', order)

    def test_release_error_does_not_raise(self):
        def boom(*_a):
            raise OSError('x')
        fw.reconcile_remote_completions({}, {}, [remote_row('ctx_n')], [], boom)


class DeferredPrRelease(unittest.TestCase):
    """A settled PR worker whose checks are pending on pass 1 is still released once they turn green."""

    def test_pending_then_green_releases_on_pass_two(self):
        config, state, released = {'repo': 'o/r'}, {}, []
        rejected = {'id': 'm1', 'type': 'worker_done',
                    'payload': {'dispatchId': 'ctx_d',
                                '_orcaLifecycleRejection': {'code': 'unknown_dispatch'}}}
        checks = {'green': False}

        def pr_of(_repo, _number):
            return {'statusCheckRollup': [{'conclusion': 'SUCCESS' if checks['green'] else None,
                                           'status': 'COMPLETED' if checks['green'] else 'IN_PROGRESS'}]}
        with patch.object(fw, 'repo_for_worker', return_value='o/r'), \
                patch.object(fw, 'pr_checks_all_success', side_effect=lambda row: checks['green']):
            for green in (False, True):
                checks['green'] = green
                messages = [dict(rejected)]
                workers = [remote_row('ctx_d', pr=7)]
                fw.reconcile_remote_completions(config, state, workers, messages, Recorder())
                fw.release_green_successes(messages, workers, config, state, (lambda row: released.append(row['dispatchId']) or 'closed'), pr_of)
                if not green:
                    self.assertEqual(released, [])
        self.assertEqual(released, ['ctx_d'])
        self.assertIn('ctx_d', state['auto_released'])

    def test_not_resynthesized_after_release(self):
        state = {'remote_reconciled': ['ctx_d'], 'auto_released': ['ctx_d']}
        messages = []
        fw.reconcile_remote_completions({}, state, [remote_row('ctx_d', pr=7)], messages, Recorder())
        self.assertEqual(messages, [])


def local_row(dispatch, **extra):
    row = {'dispatchId': dispatch, 'dispatchStatus': 'completed', 'workerState': 'succeeded',
           'terminalState': 'retained', 'projection': {'host': {'id': 'host-a'}, 'resource': {'state': 'absent'}},
           '_task_title': '#1|fullstack-dev'}
    row.update(extra)
    return row


SEAT_CONFIG = {'local_host': 'host-a', 'host_caps': {'host-a': 3, 'host-b': 2}}


class ReleasedWorkersFreeSeats(unittest.TestCase):
    def occupies(self, row, **kw):
        return fw.classify_worker(row, None, kw.get('config') or SEAT_CONFIG, {})[0]

    def test_released_unpushed_row_holds_no_seat(self):
        row = local_row('d1', dispatchStatus='released', pushed=False, terminalState='released')
        self.assertFalse(self.occupies(row))

    def test_completed_retained_row_with_an_absent_resource_holds_no_seat(self):
        self.assertFalse(self.occupies(local_row('d2')))

    def test_persisted_released_ids_free_the_seat_on_admit(self):
        row = {'dispatchId': 'd3', 'dispatchStatus': 'completed', 'workerState': 'succeeded',
               'terminalState': 'retained', 'projection': {'host': {'id': 'host-b'}},
               'resource': {'ownershipState': 'owned', 'releaseState': 'retained'}}
        with patch.object(fw, 'coordinator_load_per_core', return_value=0.1):
            held = fw.admit('host-b', SEAT_CONFIG, workers=[dict(row)])
            freed = fw.admit('host-b', SEAT_CONFIG, workers=[dict(row)], released_ids={'d3'})
        self.assertEqual((held['occupied'], freed['occupied']), (1, 0))

    def test_persisted_released_ids_come_from_the_state_file(self):
        import json
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as handle:
            json.dump({'auto_released': ['a'], 'remote_reconciled': ['b'], 'followup_released': ['c'], 'other': ['z']}, handle)
        self.assertEqual(fw.persisted_released_ids(handle.name), {'a', 'b', 'c'})
        self.assertEqual(fw.persisted_released_ids(None), set())


class SeatReport(unittest.TestCase):
    def workers(self):
        live = {'dispatchId': 'd_live', 'dispatchStatus': 'running', 'terminalState': 'active',
                'projection': {'host': {'id': 'host-a'}, 'liveness': {'verdict': 'live'}, 'outcome': 'in_progress'},
                '_task_title': '#5|fullstack-dev'}
        held = {'dispatchId': 'd_held', 'dispatchStatus': 'completed', 'workerState': 'succeeded',
                'terminalState': 'retained', 'projection': {'host': {'id': 'host-b'}},
                'resource': {'ownershipState': 'owned', 'releaseState': 'retained'}, '_task_title': '#6|qa-sdet'}
        return [live, held, local_row('d_freed')]

    def test_report_counts_live_and_names_retained_workers_per_host(self):
        with patch.object(fw, 'coordinator_load_per_core', return_value=0.1), \
                patch.object(fw, 'coordinator_free_gb', return_value=64.0):
            report = fw.fleet_seat_report(dict(SEAT_CONFIG), None, None, workers=self.workers())
        self.assertEqual((report['host-a']['occupied'], report['host-a']['live_count'], report['host-a']['retained_count']), (1, 1, 0))
        self.assertEqual((report['host-b']['occupied'], report['host-b']['retained_count']), (1, 1))
        held = report['host-b']['retained_workers'][0]
        self.assertEqual((held['dispatchId'], held['title']), ('d_held', '#6|qa-sdet'))
        text = fw.format_seat_report(report)
        self.assertIn('host-a: 1/3 live=1 retained=0 retained_workers=none', text)
        self.assertIn('host-b: 1/2 live=0 retained=1 retained_workers=d_held(#6|qa-sdet,', text)


class ReleaseWorkerEnvironment(unittest.TestCase):
    def test_default_release_passes_environment_for_remote(self):
        with patch.object(fw, 'rpc', return_value={}) as rpc:
            fw._release_row({'dispatchId': 'ctx_a', '_host': 'env-1'})
        rpc.assert_any_call('orchestration', 'worker-release', '--dispatch', 'ctx_a', '--environment', 'env-1')
        rpc.assert_any_call('orchestration', 'worker-release', '--dispatch', 'ctx_a')

    def test_default_release_local_unchanged(self):
        with patch.object(fw, 'rpc', return_value={}) as rpc:
            fw._release_row({'dispatchId': 'ctx_a', '_host': ''})
        releases = [c.args for c in rpc.call_args_list if c.args[1] == 'worker-release']
        self.assertEqual(releases, [('orchestration', 'worker-release', '--dispatch', 'ctx_a')])


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
