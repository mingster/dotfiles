import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

T0 = 1_700_000_000
OLD_MS = int((T0 - 4000) * 1000)


def base_worker(**kw):
    w = {
        'dispatchId': 'disp_fixture',
        'taskId': 'task_fix',
        'terminalState': 'retained',
        'dispatchStatus': 'dispatched',
        'agentTerminalHandle': 'term_fix',
        'githubPullRequestNumber': 99,
        'agent': 'claude',
        'resource': {'worktreeId': 'repo-x::/p'},
        'projection': {
            'host': {'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        },
    }
    w.update(kw)
    return w


class WorkerStallHelpers(unittest.TestCase):
    def test_normalize_zero_is_unknown(self):
        self.assertIsNone(fw._normalize_terminal_time_ms(0))

    def test_projection_host_id_accepts_string_or_object(self):
        self.assertEqual(fw.projection_host_id({'host': 'remote-1'}), 'remote-1')
        self.assertEqual(fw.projection_host_id({'projection': {'host': {'id': 'x'}}}), 'x')

    def test_terminal_branch_map_from_refs_heads(self):
        result = {
            'terminals': [
                {'handle': 't1', 'branch': 'refs/heads/mingster/fsd-watchdog-fold'},
                {'handle': 't2'},
            ],
        }
        self.assertEqual(fw.terminal_branch_map(result), {'t1': 'mingster/fsd-watchdog-fold'})

    def test_retry_start_args_uses_agent_not_terminal_after_stop(self):
        w = base_worker(taskId='t1', resource={'worktreeId': 'id::path'})
        args = fw.worker_stall_restart_start_args(w, 'd1')
        self.assertIsNotNone(args)
        self.assertIn('--task', args)
        self.assertIn('--agent', args)
        self.assertNotIn('--terminal', args)
        self.assertIn('claude', args)
        w2 = base_worker(taskId='t1', resource={'worktreeId': 'id::path'},
                         agentTerminalHandle='', agent='', projection={
                             'host': {'id': 'local'},
                             'outcome': 'in_progress',
                             'liveness': {'verdict': 'idle'},
                         })
        self.assertIsNone(fw.worker_stall_restart_start_args(w2, 'd1'))

    def test_worker_pr_number_accepts_string_digits(self):
        w = base_worker(githubPullRequestNumber='42')
        self.assertEqual(fw.worker_pr_number(w), 42)

    def test_resolve_pr_uses_terminal_branch_hint(self):
        w = base_worker(headRefName='', resource={'worktreeId': 'wt::/p'}, githubPullRequestNumber=None)
        gh_cmd = []

        def fake_run(cmd, **kwargs):
            gh_cmd.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout='[{"number": 7}]')

        def act(cmd):
            return 0

        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            n = fw.resolve_pr_number_for_worker(w, 'o/r', act, branch_hint='feature-x')
        self.assertEqual(n, 7)
        self.assertTrue(any('feature-x' in c for c in gh_cmd))


class WorkerStallPass(unittest.TestCase):
    def test_live_verdict_skips_restart_despite_quiet_terminal(self):
        """liveness.verdict live means the agent is active; do not stop/restart for stale lastOutputAt."""
        calls = []
        w = base_worker(projection={
            'host': {'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'live'},
        })
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        state = {}
        notices, bits = fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r'}}, state, T0, [w], term_times, rpc)
        self.assertEqual(notices, [])
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertNotIn('stall_restart=', ' '.join(bits))

    def test_idle_verdict_restarts_on_terminal_stall(self):
        """Non-live liveness and old lastOutputAt still trigger one stop/restart."""
        calls = []
        w = base_worker(projection={
            'host': {'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        })
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        state = {}
        notices, bits = fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r'}}, state, T0, [w], term_times, rpc)
        self.assertEqual(notices, [])
        self.assertTrue(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertIn('stall_restart=', ' '.join(bits))

    def test_terminal_list_failure_skips_stall_detection(self):
        calls = []
        w = base_worker()

        def rpc(*a):
            calls.append(a)
            return {}

        notices, bits = fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r'}}, {}, T0, [w], {}, rpc, terminal_list_ok=False)
        self.assertEqual(notices, [])
        self.assertIn('terminal_list_failed', bits)
        self.assertEqual(calls, [])

    def test_one_restart_per_task_survives_dispatch_change(self):
        calls = []
        w1 = base_worker(dispatchId='disp_old')
        w2 = base_worker(dispatchId='disp_new')
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        fw.worker_stall_pass(cfg, state, T0, [w1], term_times, rpc)
        stops_after_first = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_first), 1)
        calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w2], term_times, rpc)
        stops_after_second = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_second), 0)

    def test_pending_start_retries_after_row_not_live(self):
        """If start fails right after stop, retry on a later pass with snapshot row."""
        seq = []
        starts = []
        start_attempts = 0

        def rpc(*a):
            seq.append(a)
            if a[:2] == ('orchestration', 'worker-start'):
                starts.append(a)
                nonlocal start_attempts
                start_attempts += 1
                if start_attempts == 1:
                    raise RuntimeError('start failed')
            return {}

        w = base_worker(dispatchId='d1', taskId='t_retry', resource={'worktreeId': 'wt::/p'})
        term_times = {'term_fix': OLD_MS}
        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r'}}
        _, bits1 = fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc)
        self.assertIn('stall_stop_start_retry_next=d1', bits1)
        self.assertIn('t_retry', state.get('stall_pending_start', {}))

        seq.clear()
        starts.clear()
        _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 2, [], term_times, rpc)
        self.assertIn('stall_restart=d1', bits2)
        self.assertEqual(len(starts), 1)
        self.assertIn('--agent', starts[0])
        self.assertNotIn('--terminal', starts[0])

    def test_remote_row_logs_remote_only(self):
        calls = []
        w = base_worker(projection={
            'host': {'id': 'remote-host'},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        })
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        notices, bits = fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r'}}, {}, T0, [w], term_times, rpc)
        self.assertFalse(calls)
        self.assertTrue(any(b.startswith('remote_stall_unknown=') for b in bits))


class MainTerminalListFailure(unittest.TestCase):
    def test_main_logs_terminal_list_failure_and_exits_ok(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': [], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                raise RuntimeError('list failed')
            return {}

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps({
                'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
                'worker_stall': {'label_repo': 'o/r'},
            }))
            state.write_text('{}')
            log_path = Path(directory) / 'log'
            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'fetch_workers', return_value=[]), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.object(fw, 'fleet_watch_log_path', return_value=log_path), \
                    patch.dict(os.environ, {'HOME': str(directory)}), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
                text = log_path.read_text()
                self.assertIn('terminal_list_failed', text)
                self.assertIn('pass ok', text)


if __name__ == '__main__':
    unittest.main()
