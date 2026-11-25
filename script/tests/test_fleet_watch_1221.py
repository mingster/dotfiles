"""#1221: a verifier that dies at startup is retried once, and a dead 'New messages' follow-up is released."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_park import HEAD, REPO, verifier_pr  # noqa: E402

PICK = lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731


def run_pass(state, root, start_worker, workers=None):
    config = {
        'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
        'babysit': {'repos': [REPO], 'startup': '/bin/true'},
    }
    return fw.babysit_pass(
        config, state, workers or [], pr_fetch=lambda _repo: [verifier_pr()],
        start_worker=start_worker, pick=PICK, owner_check=lambda _pr: None,
    )


def failed_worker(did, **extra):
    row = {'dispatchId': did, 'dispatchStatus': 'failed', 'terminalState': 'released',
           'projection': {'stage': {'detail': 'agent_readiness'}}}
    row.update(extra)
    return row


class StartupRetry(unittest.TestCase):
    def test_synchronous_startup_exit_is_retried_once_then_parked(self):
        results = [fw.BabysitStartResult(1, 'terminal_exited at agent_readiness')] * 3
        calls = []

        def start(command):
            calls.append(command)
            return results[len(calls) - 1]

        with tempfile.TemporaryDirectory() as root:
            state = {}
            run_pass(state, root, start)
        self.assertEqual(len(calls), 2, 'one start plus one retry')

    def test_synchronous_startup_exit_that_recovers_records_the_verifier(self):
        results = [fw.BabysitStartResult(1, 'agent_not_in_foreground'), 0]
        calls = []

        def start(command):
            calls.append(command)
            return results[len(calls) - 1]

        with tempfile.TemporaryDirectory() as root:
            state = {}
            _n, lines, _l = run_pass(state, root, start)
        self.assertEqual(len(calls), 2)
        self.assertEqual(state['babysit'][REPO]['7']['action'], 'verifier')
        self.assertTrue(any('verifier' in str(line) and 'start-failed' not in str(line) for line in lines), lines)

    def test_other_failure_is_not_retried(self):
        calls = []

        def start(command):
            calls.append(command)
            return fw.BabysitStartResult(1, 'budget exhausted')

        with tempfile.TemporaryDirectory() as root:
            run_pass({}, root, start)
        self.assertEqual(len(calls), 1)

    def test_verifier_that_vanished_after_start_is_started_again_once(self):
        starts = []

        class Started(int):
            pass

        def start(command):
            starts.append(command)
            result = Started(0)
            result.dispatch_id = 'ctx_v%d' % len(starts)
            return result

        with tempfile.TemporaryDirectory() as root:
            state = {}
            run_pass(state, root, start)
            self.assertEqual(len(starts), 1)
            self.assertEqual(state['own_dispatches']['ctx_v1']['head'], HEAD)
            run_pass(state, root, start, workers=[failed_worker('ctx_v1')])
            self.assertEqual(len(starts), 2, 'the vanished verifier is replaced')
            run_pass(state, root, start, workers=[failed_worker('ctx_v1'), failed_worker('ctx_v2')])
            self.assertEqual(len(starts), 2, 'only one startup retry per head')

    def test_verifier_that_failed_for_another_reason_is_not_replaced(self):
        starts = []

        def start(command):
            starts.append(command)
            result = fw.BabysitStartResult(0, '')
            result.dispatch_id = 'ctx_v1'
            return result

        other = failed_worker('ctx_v1', projection={'stage': {'detail': 'settled'}})
        with tempfile.TemporaryDirectory() as root:
            state = {}
            run_pass(state, root, start)
            run_pass(state, root, start, workers=[other])
        self.assertEqual(len(starts), 1)


class DeadFollowup(unittest.TestCase):
    def test_new_messages_followup_on_a_succeeded_parent_is_released_once(self):
        parent = {'dispatchId': 'ctx_p', 'dispatchStatus': 'completed', 'terminalState': 'active',
                  'projection': {'outcome': 'succeeded'}}
        child = failed_worker('ctx_f', terminalState='active', follow_up_of_dispatch_id='ctx_p')
        released = []
        state = {}
        done = fw.release_dead_followups([parent, child], state, released.append)
        self.assertEqual(done, ['ctx_f'])
        self.assertEqual(fw.release_dead_followups([parent, child], state, released.append), [])
        self.assertEqual(released, ['ctx_f'])

    def test_followup_of_a_failed_parent_is_kept(self):
        parent = {'dispatchId': 'ctx_p', 'dispatchStatus': 'failed', 'terminalState': 'active'}
        child = failed_worker('ctx_f', terminalState='active', follow_up_of_dispatch_id='ctx_p')
        self.assertEqual(fw.release_dead_followups([parent, child], {}, lambda _d: None), [])


def bare_failed_row(did, **extra):
    """worker-list --include-remote row for a failed dispatch: no stage, no lastError."""
    row = {'dispatchId': did, 'dispatchStatus': 'failed', 'workerState': 'failed',
           'server': {'environmentId': 'env-1', 'name': 'remote-host'}}
    row.update(extra)
    return row


class ShowRpc:
    def __init__(self, shown):
        self.shown, self.calls = shown, []

    def __call__(self, *args):
        self.calls.append(args)
        return self.shown


class WorkerShowEnrichment(unittest.TestCase):
    def own(self, did):
        return {'own_dispatches': {did: {'kind': 'verifier', 'repo': REPO, 'pr': 7, 'head': HEAD}}}

    def test_failed_row_without_stage_is_enriched_from_worker_show(self):
        for stage, err in (('agent_readiness', 'agent_not_in_foreground'), ('dispatch_input', 'terminal_exited'),
                           ('agent_readiness', 'timeout')):
            row, state = bare_failed_row('ctx_v1'), self.own('ctx_v1')
            self.assertFalse(fw.worker_startup_failed(row))
            rpc = ShowRpc({'worker': {'stage': stage, 'lastError': err}})
            fw.enrich_failed_worker_show(row, state, rpc)
            self.assertEqual(rpc.calls, [('orchestration', 'worker-show', '--dispatch', 'ctx_v1')])
            self.assertTrue(fw.worker_startup_failed(row), (stage, err))

    def test_enrichment_is_checked_once_and_reapplied_from_state(self):
        state, rpc = self.own('ctx_v1'), ShowRpc({'stage': 'agent_readiness', 'lastError': 'terminal_exited'})
        fw.enrich_failed_worker_show(bare_failed_row('ctx_v1'), state, rpc)
        again = bare_failed_row('ctx_v1')
        fw.enrich_failed_worker_show(again, state, rpc)
        self.assertEqual(len(rpc.calls), 1)
        self.assertTrue(fw.worker_startup_failed(again))

    def test_non_startup_failure_is_cached_and_not_retried(self):
        for shown in ({'stage': 'server_record', 'lastError': 'worker_report failed'},
                      {'stage': 'settled', 'lastError': None}):
            row, state = bare_failed_row('ctx_v1'), self.own('ctx_v1')
            rpc = ShowRpc(shown)
            fw.enrich_failed_worker_show(row, state, rpc)
            fw.enrich_failed_worker_show(bare_failed_row('ctx_v1'), state, rpc)
            self.assertEqual(len(rpc.calls), 1)
            self.assertFalse(fw.worker_startup_failed(row))
            self.assertIn('ctx_v1', state['show_checked'])

    def test_unrelated_failed_row_is_not_queried(self):
        rpc = ShowRpc({'stage': 'agent_readiness'})
        fw.enrich_failed_worker_show(bare_failed_row('ctx_other'), {}, rpc)
        self.assertEqual(rpc.calls, [])

    def test_remote_verifier_release_passes_environment_and_retries(self):
        starts, releases = [], []

        def start(command):
            starts.append(command)
            result = fw.BabysitStartResult(0, '')
            result.dispatch_id = 'ctx_v%d' % len(starts)
            return result

        def release(did, environment=None):
            releases.append((did, environment))
        with tempfile.TemporaryDirectory() as root:
            state = {}
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            kwargs = dict(pr_fetch=lambda _repo: [verifier_pr()], start_worker=start, pick=PICK,
                          owner_check=lambda _pr: None, release_worker=release)
            fw.babysit_pass(config, state, [], **kwargs)
            failed = bare_failed_row('ctx_v1')
            fw.enrich_failed_worker_show(failed, state, ShowRpc({'stage': 'agent_readiness', 'lastError': 'terminal_exited'}))
            fw.babysit_pass(config, state, [failed], **kwargs)
        self.assertEqual(len(starts), 2)
        self.assertEqual(releases, [('ctx_v1', 'env-1')])


if __name__ == '__main__':
    unittest.main()
