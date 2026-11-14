import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
fw_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(fw_env)

CONFIG = {'host_caps': {'blueDevil': 5, 'local': 5}, 'local_host': 'mini6'}


def exited_row(dispatch, status, worker_state, detail, outcome):
    """worker-list --full shape from mini6 on 2026-11-14. Resource is absent. Liveness is exited."""
    return {
        'dispatchId': dispatch,
        'taskId': 'task_x',
        'runId': 'run_x',
        'workerState': worker_state,
        'dispatchStatus': status,
        'terminalState': 'retained',
        'agentTerminalHandle': 'term_' + dispatch,
        'host': 'blueDevil',
        'projection': {
            'role': 'worker',
            'outcome': outcome,
            'host': {'kind': 'remote', 'id': 'blueDevil'},
            'stage': {'worker': worker_state, 'dispatch': status, 'detail': detail},
            'liveness': {'verdict': 'exited', 'source': 'execution_host'},
            'resource': {'state': 'absent', 'reason': 'not_materialized'},
        },
    }


def dispatched_exited(dispatch):
    return exited_row(dispatch, 'dispatched', 'ready', 'input_accepted', 'in_progress')


def completed_exited(dispatch):
    return exited_row(dispatch, 'completed', 'succeeded', 'settled', 'succeeded')


def git(repo, *args):
    env = os.environ.copy()
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = '/dev/null'
    env['GIT_AUTHOR_NAME'] = 't'
    env['GIT_AUTHOR_EMAIL'] = 't@example.invalid'
    env['GIT_COMMITTER_NAME'] = 't'
    env['GIT_COMMITTER_EMAIL'] = 't@example.invalid'
    subprocess.run(['git', '-C', repo, *args], check=True, env=env, capture_output=True, text=True)


class ExitedLivenessSeats(unittest.TestCase):
    def setUp(self):
        fw_env.quiet_host(self, fw)

    def admit(self, workers, host='blueDevil'):
        return fw.admit(host, CONFIG, workers=workers)

    def test_exited_dispatches_and_absent_completed_rows_hold_no_seat(self):
        workers = [dispatched_exited('ctx_4424236f2bdc'), dispatched_exited('ctx_5bd9c2ae25c7'),
                   dispatched_exited('ctx_f88444be6518'), dispatched_exited('ctx_70ec71a32a8d'),
                   completed_exited('ctx_c9056b3f9c11'), completed_exited('ctx_b5d5bfa34ac0'),
                   completed_exited('ctx_2f86e325d5f3'), completed_exited('ctx_a7559998bb43'),
                   completed_exited('ctx_138c0efb3f75')]
        receipt = self.admit(workers)
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 0)
        self.assertEqual(receipt['live_count'], 0)
        self.assertEqual(receipt['retained_count'], 0)

    def test_null_workspace_does_not_raise_and_holds_no_seat(self):
        row = dispatched_exited('ctx_null_ws')
        row['projection']['workspace'] = None
        receipt = self.admit([row])
        self.assertEqual(receipt['occupied'], 0)
        self.assertEqual(receipt['live_count'], 0)

    def test_live_dispatch_still_holds_a_live_seat(self):
        row = dispatched_exited('ctx_live')
        row['projection']['liveness'] = {'verdict': 'live', 'source': 'agent_status'}
        receipt = self.admit([row])
        self.assertEqual(receipt['occupied'], 1)
        self.assertEqual(receipt['live_count'], 1)
        self.assertEqual(receipt['retained_count'], 0)

    def test_exited_worker_with_an_owned_unpushed_resource_stays_retained(self):
        row = completed_exited('ctx_keep')
        row['terminalState'] = 'release_pending'
        row['resource'] = {
            'ownershipState': 'owned',
            'releaseState': 'pending',
            'retainedReason': 'unpushed',
        }
        receipt = self.admit([row])
        self.assertEqual(receipt['occupied'], 1)
        self.assertEqual(receipt['live_count'], 0)
        self.assertEqual(receipt['retained_count'], 1)

    def test_visible_unpushed_commits_keep_a_retained_seat(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = str(Path(tmp) / 'work')
            subprocess.run(['git', 'init', '-q', '-b', 'main', repo], check=True)
            git(repo, 'config', 'user.email', 't@example.invalid')
            git(repo, 'config', 'user.name', 't')
            Path(repo, 'f').write_text('a\n', encoding='utf-8')
            git(repo, 'add', 'f')
            git(repo, 'commit', '-qm', 'work')
            row = dispatched_exited('ctx_ahead')
            row['host'] = 'local'
            row['worktreeId'] = 'wt::' + repo
            row['projection']['host'] = {'kind': 'local', 'id': 'local'}
            receipt = self.admit([row], host='local')
        self.assertEqual(receipt['occupied'], 1, receipt['reason'])
        self.assertEqual(receipt['live_count'], 0)
        self.assertEqual(receipt['retained_count'], 1)

    def test_visible_worktree_with_no_unpushed_commits_holds_no_seat(self):
        with tempfile.TemporaryDirectory() as tmp:
            bare = str(Path(tmp) / 'bare.git')
            repo = str(Path(tmp) / 'work')
            subprocess.run(['git', 'init', '--bare', '-q', '-b', 'main', bare], check=True)
            subprocess.run(['git', 'init', '-q', '-b', 'main', repo], check=True)
            git(repo, 'config', 'user.email', 't@example.invalid')
            git(repo, 'config', 'user.name', 't')
            Path(repo, 'f').write_text('a\n', encoding='utf-8')
            git(repo, 'add', 'f')
            git(repo, 'commit', '-qm', 'work')
            git(repo, 'remote', 'add', 'origin', bare)
            git(repo, 'push', '-q', '-u', 'origin', 'main')
            row = dispatched_exited('ctx_pushed')
            row['host'] = 'local'
            row['worktreeId'] = 'wt::' + repo
            row['projection']['host'] = {'kind': 'local', 'id': 'local'}
            receipt = self.admit([row], host='local')
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 0)
        self.assertEqual(receipt['live_count'], 0)


if __name__ == '__main__':
    unittest.main()
