import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


class StallRestartViaWorkerStartupTests(unittest.TestCase):
    def test_stall_restart_start_args_uses_worker_startup_instead_of_direct_worker_start(self):
        cfg = {'runs': [{'id': 'run_1', 'terminal': 'term_sender', 'waiter_pattern': 'w'}]}
        w = {
            'dispatchId': 'disp_old',
            'taskId': 'task_1',
            'runId': 'run_1',
            'agent': 'claude',
            'resource': {'worktreeId': 'repo::/wt'},
            'projection': {
                'host': {'id': 'local'},
                'provider': {'id': 'claude', 'model': 'claude-sonnet-5-5-medium'},
                'outcome': 'in_progress',
                'liveness': {'verdict': 'idle'},
            },
        }
        args = fw.worker_stall_restart_start_args(w, 'disp_old', 'run_1', cfg)
        self.assertIsNotNone(args)
        self.assertEqual(args[0], 'bash')
        self.assertTrue(str(args[1]).endswith('worker-startup.sh'))
        self.assertNotIn('worker-start', args)
        self.assertNotIn('orchestration', args)
        self.assertEqual(args[args.index('--run') + 1], 'run_1')
        self.assertEqual(args[args.index('--task') + 1], 'task_1')
        self.assertEqual(args[args.index('--retry-of') + 1], 'disp_old')
        self.assertEqual(args[args.index('--worktree') + 1], 'repo::/wt')
        self.assertEqual(args[args.index('--agent') + 1], 'claude')
        self.assertEqual(args[args.index('--from') + 1], 'term_sender')
        self.assertEqual(args[args.index('--model') + 1], 'claude-sonnet-5-5-medium')

    def test_rpc_executes_worker_startup_command_without_prepending_orca(self):
        seen = []

        def fake_run(cmd, **kwargs):
            seen.append(cmd)
            return subprocess.CompletedProcess(
                cmd, 0, stdout='{"ok": true, "result": {"dispatchId": "disp_new"}}', stderr='',
            )

        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            res = fw.rpc('bash', '/path/to/worker-startup.sh', '--run', 'r1', '--task', 't1')
        self.assertEqual(res, {'dispatchId': 'disp_new'})
        self.assertEqual(seen, [['bash', '/path/to/worker-startup.sh', '--run', 'r1', '--task', 't1']])


if __name__ == '__main__':
    unittest.main()
