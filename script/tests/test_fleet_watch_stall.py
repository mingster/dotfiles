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
    def test_fleet_watch_log_path_env_override(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'fw.log'
            with patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(p), 'HOME': directory}):
                self.assertEqual(fw.fleet_watch_log_path(), p)

    def test_fleet_watch_log_path_default_ignores_empty_override(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'h'
            home.mkdir()
            with patch.dict(os.environ, {'HOME': str(home), 'FLEET_WATCH_LOG_PATH': '   '}):
                self.assertEqual(
                    fw.fleet_watch_log_path(),
                    home / '.orca' / 'logs' / 'fleet-watch.log',
                )

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
            n, status = fw.resolve_pr_number_for_worker(w, 'o/r', act, branch_hint='feature-x')
        self.assertEqual(n, 7)
        self.assertEqual(status, 'ok')
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
        """Replacement on same task id: one stop/restart; next pass labels once, no second restart."""
        calls = []
        w1 = base_worker(dispatchId='disp_old')
        w2 = base_worker(dispatchId='disp_new')
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        fw.worker_stall_pass(cfg, state, T0, [w1], term_times, rpc, act=fake_act)
        stops_after_first = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_first), 1)
        calls.clear()
        gh_calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w2], term_times, rpc, act=fake_act)
        stops_after_second = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_second), 0)
        edits = [c for c in gh_calls if len(c) >= 4 and c[0] == 'gh' and c[1] == 'pr' and c[2] == 'edit']
        self.assertEqual(len(edits), 1)
        self.assertIn('needs-elon', edits[0])

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

    def test_non_live_sibling_same_task_one_restart_then_label(self):
        """Two rows same task: only the live stalled row restarts; one label after cooldown."""
        calls = []
        w_old = base_worker(
            dispatchId='disp_completed',
            taskId='task_shared',
            agentTerminalHandle='term_other',
            dispatchStatus='completed',
        )
        w_live = base_worker(dispatchId='disp_live', taskId='task_shared')
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        fw.worker_stall_pass(cfg, state, T0, [w_old, w_live], term_times, rpc, act=fake_act)
        stops = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0][3], 'disp_live')
        calls.clear()
        gh_calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w_old, w_live], term_times, rpc, act=fake_act)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        edits = [c for c in gh_calls if len(c) >= 4 and c[0] == 'gh' and c[1] == 'pr' and c[2] == 'edit']
        self.assertEqual(len(edits), 1)

    def test_inventory_failure_skipped_pass_preserves_restart_state(self):
        """Orca inventory failure skips stall logic without clearing one-restart state."""
        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': False, 'restart_at': T0}}}
        w = base_worker()
        notices, bits = fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}},
            state, T0 + 10, [w], {'term_fix': OLD_MS}, lambda *a: None,
            inventory_ok=False)
        self.assertIn('orca_inventory_failed_stall_skipped', bits)
        self.assertIn('task_fix', state['worker_stall'])
        self.assertTrue(state['worker_stall']['task_fix']['restarted'])

    def test_failed_inventory_between_passes_then_label_no_second_restart(self):
        """After restart, a failed inventory pass preserves state; next ok pass labels, no second stop."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(dispatchId='d1')
        term_times = {'term_fix': OLD_MS}
        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc, act=fake_act)
        self.assertTrue(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        calls.clear()
        gh_calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w], term_times, rpc, act=fake_act,
                             inventory_ok=False)
        self.assertEqual(calls, [])
        fw.worker_stall_pass(cfg, state, T0 + 2, [w], term_times, rpc, act=fake_act,
                             inventory_ok=True)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertTrue(any(c for c in gh_calls if 'pr' in c and 'edit' in c))

    def test_fresh_terminal_after_restart_clears_stall_no_label(self):
        """Replacement shows progress (fresh lastOutputAt): no label/restart; one-restart record kept until TTL."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(dispatchId='d1')
        fresh_ms = int(T0 * 1000)
        state = {}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        fw.worker_stall_pass(cfg, state, T0, [w], {'term_fix': OLD_MS}, rpc, act=fake_act)
        calls.clear()
        gh_calls.clear()
        _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 60, [w], {'term_fix': fresh_ms}, rpc, act=fake_act)
        self.assertEqual(gh_calls, [])
        self.assertFalse(any('stall_label_pr' in b for b in bits2))
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        st = state['worker_stall'].get('task_fix')
        self.assertIsInstance(st, dict)
        self.assertTrue(st.get('restarted'))

    def test_recovery_then_stall_again_labels_once_no_second_restart(self):
        """After fresh output, stall again inside record TTL: label once, no second stop/restart."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(dispatchId='d1')
        state = {}
        cfg = {
            'worker_stall': {
                'label_repo': 'o/r',
                'label_cooldown_seconds': 0,
                'stall_restart_record_ttl_seconds': 24 * 3600,
            },
        }
        # Pass 1: stalled -> one restart
        fw.worker_stall_pass(cfg, state, T0, [w], {'term_fix': OLD_MS}, rpc, act=fake_act)
        stops_pass1 = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_pass1), 1)
        calls.clear()
        gh_calls.clear()
        # Pass 2: replacement prints (fresh output) -> no label, no restart; record retained
        fresh_ms = int((T0 + 120) * 1000)
        _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 120, [w], {'term_fix': fresh_ms}, rpc, act=fake_act)
        self.assertEqual(gh_calls, [])
        self.assertFalse(any('stall_label_pr' in b for b in bits2))
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        calls.clear()
        gh_calls.clear()
        # Pass 3: stuck again for 30+ minutes, still inside 24h TTL -> label, no second restart
        t3 = T0 + 3 * 3600
        stuck_ms = int((t3 - 2000) * 1000)
        _, bits3 = fw.worker_stall_pass(cfg, state, t3, [w], {'term_fix': stuck_ms}, rpc, act=fake_act)
        stops_pass3 = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_pass3), 0)
        edits = [c for c in gh_calls if len(c) >= 4 and c[0] == 'gh' and c[1] == 'pr' and c[2] == 'edit']
        self.assertEqual(len(edits), 1)
        self.assertIn('needs-elon', edits[0])
        self.assertEqual(len([b for b in bits3 if 'stall_label_pr' in b]), 1)

    def test_labeled_worker_next_pass_does_not_label_again(self):
        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': True, 'restart_at': T0}}}
        w = base_worker()
        fw.worker_stall_pass(
            {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}},
            state, T0 + 4000, [w], {'term_fix': OLD_MS}, lambda *a: None, act=fake_act)
        edits = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'pr', 'edit']]
        self.assertEqual(len(edits), 0)

    def test_record_ttl_expiry_allows_new_stall_restart(self):
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        state = {
            'worker_stall': {
                'task_fix': {'restarted': True, 'labeled': True, 'restart_at': T0 - 4000},
            }
        }
        w = base_worker(dispatchId='d_after_ttl')
        cfg = {
            'worker_stall': {
                'label_repo': 'o/r',
                'label_cooldown_seconds': 0,
                'stall_restart_record_ttl_seconds': 3600,
            },
        }
        fw.worker_stall_pass(cfg, state, T0, [w], {'term_fix': OLD_MS}, rpc)
        stops = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0][3], 'd_after_ttl')

    def test_gh_pr_list_fails_then_succeeds_labels_once_second_pass(self):
        """Lookup failure does not open an issue or set labeled; next pass labels the PR."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []
        run_seq = []

        def fake_run(cmd, **kwargs):
            run_seq.append(cmd)
            if len(run_seq) == 1:
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout='[{"number": 88}]')

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(
            dispatchId='d_gh',
            githubPullRequestNumber=None,
            headRefName='feature-retry',
        )
        term_times = {'term_fix': OLD_MS}
        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': False, 'restart_at': T0 - 200}}}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            _, bits1 = fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc, act=fake_act)
        issues1 = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        edits1 = [c for c in gh_calls if len(c) >= 4 and c[:4] == ['gh', 'pr', 'edit', '88']]
        self.assertIn('stall_pr_lookup_failed=d_gh', bits1)
        self.assertEqual(issues1, [])
        self.assertEqual(edits1, [])
        self.assertFalse(state['worker_stall']['task_fix'].get('labeled'))

        gh_calls.clear()
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 5, [w], term_times, rpc, act=fake_act)
        issues2 = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        edits2 = [c for c in gh_calls if len(c) >= 4 and c[:4] == ['gh', 'pr', 'edit', '88']]
        self.assertEqual(issues2, [])
        self.assertEqual(len(edits2), 1)
        self.assertIn('needs-elon', edits2[0])
        self.assertTrue(state['worker_stall']['task_fix'].get('labeled'))

    def test_gh_pr_list_timeout_then_empty_opens_fallback_once(self):
        """Timeout is lookup failure (no issue); empty list is no_pr -> one fallback issue next pass."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []
        run_seq = []

        def fake_run(cmd, **kwargs):
            run_seq.append(cmd)
            if len(run_seq) == 1:
                raise subprocess.TimeoutExpired(cmd, kwargs.get('timeout', 30))
            return subprocess.CompletedProcess(cmd, 0, stdout='[]')

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(
            dispatchId='d_to',
            githubPullRequestNumber=None,
            headRefName='gone-branch',
        )
        term_times = {'term_fix': OLD_MS}
        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': False, 'restart_at': T0 - 200}}}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            _, bits1 = fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc, act=fake_act)
        issues1 = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertIn('stall_pr_lookup_failed=d_to', bits1)
        self.assertEqual(issues1, [])
        self.assertFalse(state['worker_stall']['task_fix'].get('labeled'))

        gh_calls.clear()
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 5, [w], term_times, rpc, act=fake_act)
        issues2 = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'issue', 'create']]
        self.assertEqual(len(issues2), 1)
        self.assertTrue(state['worker_stall']['task_fix'].get('labeled'))
        self.assertIn('stall_no_pr=d_to', bits2)

    def test_lookup_fails_every_pass_no_label_no_issue(self):
        """Repeated gh failures never set labeled, never open issues, and do not crash."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_run(cmd, **kwargs):
            raise subprocess.CalledProcessError(1, cmd)

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(
            dispatchId='d_bad',
            githubPullRequestNumber=None,
            headRefName='any',
        )
        term_times = {'term_fix': OLD_MS}
        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': False, 'restart_at': T0 - 200}}}
        cfg = {'worker_stall': {'label_repo': 'o/r', 'label_cooldown_seconds': 0}}
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            _, bits1 = fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc, act=fake_act)
            _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 100, [w], term_times, rpc, act=fake_act)
        self.assertIn('stall_pr_lookup_failed=d_bad', bits1)
        self.assertIn('stall_pr_lookup_failed=d_bad', bits2)
        self.assertEqual(gh_calls, [])
        st = state['worker_stall'].get('task_fix')
        self.assertIsInstance(st, dict)
        self.assertTrue(st.get('restarted'))
        self.assertFalse(st.get('labeled'))


class MainStallInventory(unittest.TestCase):
    def test_main_skips_stall_when_inventory_fails(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox':
                raise RuntimeError('inventory failed')
            return {}

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps({
                'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
                'worker_stall': {'label_repo': 'o/r'},
            }))
            state.write_text(json.dumps({'worker_stall': {'task_x': {'restarted': True}}}))
            log_path = Path(directory) / 'log'
            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.dict(os.environ, {'HOME': str(directory), 'FLEET_WATCH_LOG_PATH': str(log_path)}), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
                text = log_path.read_text()
                self.assertIn('orca_inventory_failed_stall_skipped', text)
                saved = json.loads(state.read_text())
                self.assertIn('task_x', saved.get('worker_stall', {}))

    def test_main_skips_stall_when_worker_list_empty(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': [], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': []}
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
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.dict(os.environ, {'HOME': str(directory), 'FLEET_WATCH_LOG_PATH': str(log_path)}), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
                text = log_path.read_text()
                self.assertIn('stall_skipped_empty_workers', text)


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
            home_root = Path(directory) / 'home'
            home_root.mkdir()
            default_log = home_root / '.orca' / 'logs' / 'fleet-watch.log'
            default_log.parent.mkdir(parents=True)
            default_log.write_text('untouched\n')
            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'fetch_workers', return_value=[]), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.dict(os.environ, {'HOME': str(home_root), 'FLEET_WATCH_LOG_PATH': str(log_path)}), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
                text = log_path.read_text()
                self.assertIn('terminal_list_failed', text)
                self.assertIn('pass ok', text)
                self.assertEqual(default_log.read_text(), 'untouched\n')

    def test_main_pass_writes_to_log_env_and_leaves_default_path_untouched(self):
        """A full pass appends only to FLEET_WATCH_LOG_PATH, not the default under HOME."""

        def rpc(*args):
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
            log_path = Path(directory) / 'override.log'
            home_root = Path(directory) / 'home'
            home_root.mkdir()
            default_log = home_root / '.orca' / 'logs' / 'fleet-watch.log'
            default_log.parent.mkdir(parents=True)
            default_log.write_text('seed\n')
            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'fetch_workers', return_value=[]), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.dict(os.environ, {'HOME': str(home_root), 'FLEET_WATCH_LOG_PATH': str(log_path)}), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
            self.assertTrue(log_path.is_file())
            self.assertIn('pass ok', log_path.read_text())
            self.assertEqual(default_log.read_text(), 'seed\n')


if __name__ == '__main__':
    unittest.main()
