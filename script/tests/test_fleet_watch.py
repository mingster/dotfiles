import importlib.util
from pathlib import Path
import subprocess
import tempfile
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


SHOWN = {'dispatchId': 'd_show', 'server': 'blueDevil', 'stage': 'server_record', 'state': 'succeeded',
         'status': 'completed'}


def settled_local(status='completed', state='succeeded', **extra):
    row = {'dispatchId': 'd_loc', 'dispatchStatus': status, 'workerState': state,
           'projection': {'host': {'id': 'local'}}}
    row.update(extra)
    return row


def dirty_repo(tmp):
    subprocess.run(['git', 'init', '-q', tmp], check=True)
    Path(tmp, 'x').write_text('dirty')


class SettledRowCapTests(unittest.TestCase):
    cfg = {'local_host': 'hostA', 'host_caps': {'local': 3}}

    def setUp(self):
        env = patch.dict('os.environ', {'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.10', 'FLEET_WATCH_TEST_FREE_GB': '16.0'})
        env.start()
        self.addCleanup(env.stop)

    def test_worker_show_server_record_is_a_remote_row_and_freed(self):
        row = fw._shown_remote_worker('d_show', lambda *a: dict(SHOWN))
        self.assertTrue(fw._remote_server_row(row))
        self.assertEqual(fw.projection_host_id(row), 'blueDevil')
        self.assertEqual(fw.remote_environment(row), 'blueDevil')
        occupies, info, _ = fw.classify_worker(row, None, self.cfg, {})
        self.assertFalse(occupies)
        self.assertEqual(info['category'], 'freed')

    def test_reconcile_records_show_row_and_adds_only_remote_rows(self):
        workers, state = [], {}
        msgs = [{'id': 'm1', 'type': 'worker_done',
                 'body': 'Orca rejected this worker_done: worker_done references unknown dispatch',
                 'payload': {'dispatchId': 'd_show'}}]
        fw.reconcile_remote_completions(self.cfg, state, workers, msgs, lambda *a: dict(SHOWN))
        self.assertIn('d_show', state['remote_reconciled'])
        self.assertEqual(len(workers), 1)
        self.assertFalse(fw.classify_worker(workers[0], None, self.cfg, {})[0])

    def test_settled_local_row_without_checkout_or_liveness_is_freed(self):
        for state in ('succeeded', 'failed', 'stopped'):
            occupies, info, _ = fw.classify_worker(settled_local(state=state), None, self.cfg, {})
            self.assertFalse(occupies, state)
            self.assertEqual(info['category'], 'freed')

    def test_settled_local_row_with_gone_worktree_is_freed(self):
        row = settled_local(resource={'worktreeId': 'r::/nonexistent/wt-1394'})
        self.assertFalse(fw.classify_worker(row, None, self.cfg, {})[0])

    def test_settled_local_row_with_dirty_worktree_stays_retained(self):
        with tempfile.TemporaryDirectory() as d:
            dirty_repo(d)
            row = settled_local(resource={'worktreeId': 'r::' + d})
            occupies, info, _ = fw.classify_worker(row, None, self.cfg, {})
            self.assertTrue(occupies)
            self.assertEqual(info['category'], 'retained')

    def test_cap_reason_reports_live_and_retained(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as e:
            dirty_repo(d)
            dirty_repo(e)
            rows = [settled_local(dispatchId="r%d" % i, resource={"worktreeId": "r::" + p}) for i, p in enumerate((d, e))]
            rows.append({'dispatchId': 'live1', 'dispatchStatus': 'running', 'projection': {'host': {'id': 'local'}}})
            cfg = {'local_host': 'hostA', 'host_caps': {'local': 1}}
            res = fw.admit('local', cfg, workers=rows, env_names={})
            self.assertFalse(res['admitted'])
            self.assertEqual((res['live_count'], res['retained_count']), (1, 2))
            self.assertIn('3/1 (live=1 retained=2)', res['reason'])


class BodyGateFallbackTests(unittest.TestCase):
    pr = {'number': 7, 'headRefName': 'mingster/b7', 'body': 'Builder: agent=claude model=sonnet\nno check'}

    def run_gate(self, workers, dry=False):
        sent, lines, bits, state = [], [], [], {}
        blocked = fw.body_gate_blocks_verifier(
            self.pr, workers, state, 'o/r', dry, lambda t, m: sent.append((t, m)), lines, 'abc', bits)
        return blocked, sent, lines, bits

    def test_no_builder_lets_the_verifier_start(self):
        blocked, sent, lines, bits = self.run_gate([])
        self.assertFalse(blocked)
        self.assertEqual((sent, lines, bits), ([], [], []))

    def test_settled_builder_lets_the_verifier_start(self):
        w = {'dispatchId': 'b', 'dispatchStatus': 'completed', 'workerState': 'succeeded', 'branch': 'mingster/b7'}
        self.assertFalse(self.run_gate([w])[0])

    def test_live_builder_matched_by_branch_is_mailed_and_blocks(self):
        w = {'dispatchId': 'b', 'dispatchStatus': 'running', 'branch': 'mingster/b7',
             'agentTerminalHandle': 'term_b'}
        blocked, sent, lines, bits = self.run_gate([w])
        self.assertTrue(blocked)
        self.assertEqual(len(sent), 1)
        self.assertEqual(bits, ['body_gate=7'])
        self.assertTrue(any('body-gate' in line for line in lines))


class BabysitReposFallbackTests(unittest.TestCase):
    def test_repos_and_roots_come_from_repo_roots_before_bind(self):
        with patch.object(fw, 'repos_from_roots', return_value=(['o/r'], {'o/r': '/p'})):
            cfg = {'repo_roots': ['/p']}
            self.assertEqual(fw.babysit_repos(cfg), ['o/r'])
            self.assertEqual(fw.babysit_settings(cfg)[3], {'o/r': '/p'})


if __name__ == '__main__':
    unittest.main()
