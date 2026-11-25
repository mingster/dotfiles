import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

_spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', Path(__file__).parent / 'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_spec_env)
_spec_env.loader.exec_module(_fwe)
isolated_main_env = _fwe.isolated_main_env

T0 = 1_700_000_000
OLD_MS = int((T0 - 4000) * 1000)

STALL_RUNS = [{'id': 'run_fixture', 'terminal': 'term_stall_sender', 'waiter_pattern': 'fw-stall-wait'}]


def stall_test_config(worker_stall_extra=None):
    """Minimal config: stall restarts need a matching runs[].terminal for --from."""
    cfg = {'runs': list(STALL_RUNS), 'worker_stall': {'label_repo': 'o/r'}}
    if worker_stall_extra:
        cfg['worker_stall'] = {**cfg['worker_stall'], **worker_stall_extra}
    return cfg


def mark_own(state, *ids, kind='verifier'):
    bucket = state.setdefault('own_dispatches', {})
    for did in ids:
        bucket.setdefault(did, {'kind': kind})
    return state


def base_worker(**kw):
    w = {
        'dispatchId': 'disp_fixture',
        'taskId': 'task_fix',
        'runId': 'run_fixture',
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
        remote_row = {
            'dispatchId': 'ctx_remote_1',
            'workerState': 'ready',
            'dispatchStatus': 'dispatched',
            'agentTerminalHandle': None,
            'terminalState': None,
            'resource': None,
            'server': {'environmentId': 'env-1', 'name': 'remote-host', 'asOf': '2023-11-14T21:00:00Z'},
        }
        self.assertEqual(fw.projection_host_id(remote_row), 'remote-host')
        self.assertTrue(fw.worker_row_is_live(remote_row))
        state = {}
        notices, log_bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [remote_row], {}, lambda *_a: {},
        )
        self.assertIn('remote_stall_check=ctx_remote_1:silent', log_bits)
        self.assertEqual(len(notices), 1)
        self.assertIn('ctx_remote_1', notices[0])

    def test_terminal_branch_map_from_refs_heads(self):
        result = {
            'terminals': [
                {'handle': 't1', 'branch': 'refs/heads/mingster/fsd-watchdog-fold'},
                {'handle': 't2'},
            ],
        }
        self.assertEqual(fw.terminal_branch_map(result), {'t1': 'mingster/fsd-watchdog-fold'})

    def test_retry_start_args_uses_agent_not_terminal_after_stop(self):
        cfg = {'runs': STALL_RUNS}
        w = base_worker(taskId='t1', resource={'worktreeId': 'id::path'})
        args = fw.worker_stall_restart_start_args(w, 'd1', 'run_ignored', cfg)
        self.assertIsNotNone(args)
        self.assertEqual(args[0], 'bash')
        self.assertTrue(str(args[1]).endswith('worker-startup.sh'))
        self.assertNotIn('worker-start', args)
        self.assertIn('--task', args)
        self.assertIn('--run', args)
        self.assertEqual(args[args.index('--run') + 1], 'run_fixture')
        self.assertIn('--agent', args)
        self.assertNotIn('--terminal', args)
        self.assertIn('--from', args)
        self.assertEqual(args[args.index('--from') + 1], 'term_stall_sender')
        self.assertIn('claude', args)
        w_no_run = base_worker(taskId='t1', resource={'worktreeId': 'id::path'})
        del w_no_run['runId']
        w_no_run['_fleet_watch_list_run'] = 'run_from_list'
        cfg_list = {'runs': [{'id': 'run_from_list', 'terminal': 't_other', 'waiter_pattern': 'w'}]}
        args2 = fw.worker_stall_restart_start_args(w_no_run, 'd1', 'run_persisted', cfg_list)
        self.assertIsNotNone(args2)
        self.assertEqual(args2[args2.index('--run') + 1], 'run_from_list')
        self.assertEqual(args2[args2.index('--from') + 1], 't_other')
        w3 = base_worker(taskId='t1', resource={'worktreeId': 'id::path'})
        del w3['runId']
        cfg_persist = {'runs': [{'id': 'run_persisted', 'terminal': 't_persist', 'waiter_pattern': 'w'}]}
        args3 = fw.worker_stall_restart_start_args(w3, 'd1', 'run_persisted', cfg_persist)
        self.assertIsNotNone(args3)
        self.assertEqual(args3[args3.index('--run') + 1], 'run_persisted')
        self.assertEqual(args3[args3.index('--from') + 1], 't_persist')
        w2 = base_worker(taskId='t1', resource={'worktreeId': 'id::path'},
                         agentTerminalHandle='', agent='', projection={
                             'host': {'id': 'local'},
                             'outcome': 'in_progress',
                             'liveness': {'verdict': 'idle'},
                         })
        self.assertIsNone(fw.worker_stall_restart_start_args(w2, 'd1', 'run_z', cfg))

    def test_retry_start_args_none_without_configured_sender_terminal(self):
        w = base_worker(taskId='t1', resource={'worktreeId': 'id::path'})
        cfg_no_row = {'runs': [{'id': 'other', 'terminal': 't1', 'waiter_pattern': 'w'}]}
        self.assertIsNone(fw.worker_stall_restart_start_args(w, 'd1', 'run_ignored', cfg_no_row))
        cfg_blank = {'runs': [{'id': 'run_fixture', 'terminal': '', 'waiter_pattern': 'w'}]}
        self.assertIsNone(fw.worker_stall_restart_start_args(w, 'd1', 'run_ignored', cfg_blank))

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
            stall_test_config(), state, T0, [w], term_times, rpc)
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

        state = mark_own({}, 'disp_fixture')
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], term_times, rpc)
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
            stall_test_config(), {}, T0, [w], {}, rpc, terminal_list_ok=False)
        self.assertEqual(notices, [])
        self.assertIn('terminal_list_failed', bits)
        self.assertEqual(calls, [])

    def test_one_restart_per_task_survives_dispatch_change(self):
        """One restart of the recorded dispatch. A later dispatch id is reported, not stopped or labeled."""
        calls = []
        w1 = base_worker(dispatchId='disp_old')
        w2 = base_worker(dispatchId='disp_new')
        term_times = {'term_fix': OLD_MS}

        def rpc(*a):
            calls.append(a)
            return {}

        state = mark_own({}, 'disp_old')
        cfg = stall_test_config({'label_cooldown_seconds': 0})
        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        fw.worker_stall_pass(cfg, state, T0, [w1], term_times, rpc, act=fake_act)
        stops_after_first = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_first), 1)
        calls.clear()
        gh_calls.clear()
        notices, _bits = fw.worker_stall_pass(cfg, state, T0 + 1, [w2], term_times, rpc, act=fake_act)
        stops_after_second = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops_after_second), 0)
        edits = [c for c in gh_calls if len(c) >= 4 and c[0] == 'gh' and c[1] == 'pr' and c[2] == 'edit']
        self.assertEqual(edits, [])
        self.assertTrue(any('disp_new' in n for n in notices))

    def test_failed_start_after_stop_is_parked(self):
        """A failed restart of our own worker is parked once and is not tried again."""
        starts = []

        def rpc(*a):
            if '--retry-of' in a:
                starts.append(a)
                body = json.dumps({'ok': False, 'error': {'code': 'no_active_sender_terminal',
                                                         'message': 'no active sender terminal'}})
                proc_err = subprocess.CalledProcessError(1, ['orca'], body, '}\n')
                err = fw.OrcaReadError('no_active_sender_terminal')
                err.orca_error_code = 'no_active_sender_terminal'
                raise err from proc_err
            return {}

        w = base_worker(dispatchId='d1', taskId='t_retry', resource={'worktreeId': 'wt::/p'})
        term_times = {'term_fix': OLD_MS}
        state = mark_own({}, 'd1')
        cfg = stall_test_config()
        notices, bits1 = fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc)
        self.assertEqual(len(notices), 1)
        self.assertIn('no active sender terminal', notices[0])
        self.assertIn('no_active_sender_terminal', notices[0])
        self.assertIn('stall_parked=d1', bits1)
        self.assertTrue(any(bit.startswith('stall_restart_fail=d1:') for bit in bits1), bits1)
        self.assertTrue(state['own_dispatches']['d1']['parked'])
        self.assertNotIn('t_retry', state.get('stall_pending_start', {}))
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][0], 'bash')
        self.assertTrue(str(starts[0][1]).endswith('worker-startup.sh'))
        self.assertIn('--agent', starts[0])
        self.assertIn('--run', starts[0])
        self.assertEqual(starts[0][starts[0].index('--run') + 1], 'run_fixture')
        self.assertNotIn('--terminal', starts[0])
        self.assertIn('--from', starts[0])
        self.assertEqual(starts[0][starts[0].index('--from') + 1], 'term_stall_sender')

        notices2, bits2 = fw.worker_stall_pass(cfg, state, T0 + 2, [w], term_times, rpc)
        self.assertEqual(notices2, [])
        self.assertEqual(len(starts), 1)
        self.assertFalse(any(bit.startswith('stall_restart_retry=') for bit in bits2), bits2)

    def test_pending_start_retries_old_record_without_stored_run_uses_single_config_run(self):
        """Legacy pending (no stall_restart_run_id): retry uses the sole configured run id."""
        seq = []

        def rpc(*a):
            seq.append(a)
            return {}

        wt_sel = 'wt::/p'
        state = {
            'stall_pending_start': {
                't_legacy': {
                    'old_dispatch': 'd_old',
                    'row_snapshot': {
                        'taskId': 't_legacy',
                        'resource': {'worktreeId': wt_sel},
                        'projection': {
                            'provider': {'id': 'claude', 'model': None},
                        },
                    },
                    'started': False,
                },
            },
        }
        cfg = {
            'runs': [{'id': 'solo_run', 'terminal': 't', 'waiter_pattern': 'w'}],
            'worker_stall': {'label_repo': 'o/r'},
        }
        _, bits = fw.worker_stall_pass(cfg, state, T0, [], {'term_fix': OLD_MS}, rpc)
        self.assertIn('stall_restart=d_old', bits)
        starts = [a for a in seq if len(a) >= 4 and '--retry-of' in a]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0][0], 'bash')
        self.assertTrue(str(starts[0][1]).endswith('worker-startup.sh'))
        self.assertIn('--run', starts[0])
        self.assertEqual(starts[0][starts[0].index('--run') + 1], 'solo_run')

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
            stall_test_config(), {}, T0, [w], term_times, rpc)
        self.assertEqual(calls[0][:2], ('orchestration', 'worker-read'))
        self.assertIn('--environment', calls[0])
        self.assertTrue(any(b.startswith('remote_stall_check=disp_fixture:silent') for b in bits))

    def test_stall_no_sender_terminal_skips_restart_and_logs(self):
        """Without runs[].terminal for the resolved run, do not stop; log and keep trying next pass."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        w = base_worker(dispatchId='d_ns', projection={
            'host': {'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        })
        term_times = {'term_fix': OLD_MS}
        cfg = {'runs': [{'id': 'run_fixture', 'waiter_pattern': 'w'}], 'worker_stall': {'label_repo': 'o/r'}}
        notices, bits = fw.worker_stall_pass(cfg, mark_own({}, 'd_ns'), T0, [w], term_times, rpc)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertTrue(any(b == 'stall_no_sender_terminal=d_ns' for b in bits))

    def test_orchestration_failure_log_code_prefers_json_code(self):
        body = json.dumps({'ok': False, 'error': {'code': 'task_gone'}})
        proc = subprocess.CalledProcessError(1, ['orca'], '', body)
        err = fw.OrcaReadError('task_gone')
        err.orca_error_code = 'task_gone'
        self.assertEqual(fw.orchestration_failure_log_code(err), 'task_gone')
        wrapped = RuntimeError('wrapper')
        wrapped.__cause__ = proc
        self.assertEqual(fw.orchestration_failure_log_code(wrapped), 'task_gone')

    def test_non_live_sibling_same_task_one_restart_then_label(self):
        """Two rows same task: only the live own row restarts, and a later pass does not label it."""
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

        state = mark_own({}, 'disp_live')
        cfg = stall_test_config({'label_cooldown_seconds': 0})
        fw.worker_stall_pass(cfg, state, T0, [w_old, w_live], term_times, rpc, act=fake_act)
        stops = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0][3], 'disp_live')
        calls.clear()
        gh_calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w_old, w_live], term_times, rpc, act=fake_act)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        edits = [c for c in gh_calls if len(c) >= 4 and c[0] == 'gh' and c[1] == 'pr' and c[2] == 'edit']
        self.assertEqual(edits, [])

    def test_inventory_failure_skipped_pass_preserves_restart_state(self):
        """Orca inventory failure skips stall logic without clearing one-restart state."""
        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': False, 'restart_at': T0}}}
        w = base_worker()
        notices, bits = fw.worker_stall_pass(
            stall_test_config({'label_cooldown_seconds': 0}),
            state, T0 + 10, [w], {'term_fix': OLD_MS}, lambda *a: None,
            inventory_ok=False)
        self.assertIn('orca_inventory_failed_stall_skipped', bits)
        self.assertIn('task_fix', state['worker_stall'])
        self.assertTrue(state['worker_stall']['task_fix']['restarted'])

    def test_failed_inventory_between_passes_then_label_no_second_restart(self):
        """After restart, a failed inventory pass preserves state; the next ok pass does not stop again."""
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
        state = mark_own({}, 'd1')
        cfg = stall_test_config({'label_cooldown_seconds': 0})
        fw.worker_stall_pass(cfg, state, T0, [w], term_times, rpc, act=fake_act)
        self.assertTrue(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        calls.clear()
        gh_calls.clear()
        fw.worker_stall_pass(cfg, state, T0 + 1, [w], term_times, rpc, act=fake_act,
                             inventory_ok=False)
        self.assertEqual(calls, [])
        self.assertTrue(state['own_dispatches']['d1'].get('restarted'))
        fw.worker_stall_pass(cfg, state, T0 + 2, [w], term_times, rpc, act=fake_act,
                             inventory_ok=True)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertFalse(any(c for c in gh_calls if 'pr' in c and 'edit' in c))

    def test_fresh_terminal_after_restart_clears_stall_no_label(self):
        """Fresh output after a restart does not park the dispatch or stop it again."""
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
        state = mark_own({}, 'd1')
        cfg = stall_test_config({'label_cooldown_seconds': 0})
        fw.worker_stall_pass(cfg, state, T0, [w], {'term_fix': OLD_MS}, rpc, act=fake_act)
        calls.clear()
        gh_calls.clear()
        _, bits2 = fw.worker_stall_pass(cfg, state, T0 + 60, [w], {'term_fix': fresh_ms}, rpc, act=fake_act)
        self.assertEqual(gh_calls, [])
        self.assertFalse(any('stall_parked' in b for b in bits2))
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        st = state['own_dispatches'].get('d1')
        self.assertIsInstance(st, dict)
        self.assertTrue(st.get('restarted'))
        self.assertFalse(st.get('parked'))

    def test_recovery_then_stall_again_labels_once_no_second_restart(self):
        """After fresh output, silence for another 30 minutes parks once and does not restart again."""
        calls = []

        def rpc(*a):
            calls.append(a)
            return {}

        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        w = base_worker(dispatchId='d1')
        state = mark_own({}, 'd1')
        cfg = stall_test_config({
            'label_cooldown_seconds': 0,
            'stall_restart_record_ttl_seconds': 24 * 3600,
        })
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
        self.assertEqual(edits, [])
        self.assertEqual(len([b for b in bits3 if b == 'stall_parked=d1']), 1)

    def test_labeled_worker_next_pass_does_not_label_again(self):
        gh_calls = []

        def fake_act(cmd):
            gh_calls.append(cmd)
            return 0

        state = {'worker_stall': {'task_fix': {'restarted': True, 'labeled': True, 'restart_at': T0}}}
        w = base_worker()
        fw.worker_stall_pass(
            stall_test_config({'label_cooldown_seconds': 0}),
            state, T0 + 4000, [w], {'term_fix': OLD_MS}, lambda *a: None, act=fake_act)
        edits = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'pr', 'edit']]
        self.assertEqual(len(edits), 0)

    def test_record_ttl_expiry_does_not_restart_a_foreign_dispatch(self):
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
        cfg = stall_test_config({
            'label_cooldown_seconds': 0,
            'stall_restart_record_ttl_seconds': 3600,
        })
        notices, _bits = fw.worker_stall_pass(cfg, state, T0, [w], {'term_fix': OLD_MS}, rpc)
        stops = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(stops, [])
        self.assertTrue(any('d_after_ttl' in n for n in notices))

    def test_silent_own_worker_parks_without_github_calls(self):
        """A silent restart is a notice. Fleet watch does not label the PR or open an issue."""
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

        w = base_worker(dispatchId='d_gh', githubPullRequestNumber=None, headRefName='feature-retry')
        state = {'own_dispatches': {
            'd_gh': {'kind': 'verifier', 'restarted': True, 'restart_at': T0 - 4000},
        }}
        with patch.object(fw.subprocess, 'run', side_effect=fake_run):
            notices, bits = fw.worker_stall_pass(
                stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, rpc, act=fake_act)
            again, bits2 = fw.worker_stall_pass(
                stall_test_config(), state, T0 + 100, [w], {'term_fix': OLD_MS}, rpc, act=fake_act)
        self.assertIn('stall_parked=d_gh', bits)
        self.assertNotIn('stall_parked=d_gh', bits2)
        self.assertEqual(len(notices), 1)
        self.assertEqual(again, [])
        self.assertEqual(gh_calls, [])
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))


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
            log_path = Path(directory) / 'fleet-watch-test.log'
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
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
            log_path = Path(directory) / 'fleet-watch-test.log'
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
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
            log_path = Path(directory) / 'fleet-watch-test.log'
            home_root = Path(directory) / 'home'
            home_root.mkdir()
            default_log = home_root / '.orca' / 'logs' / 'fleet-watch.log'
            default_log.parent.mkdir(parents=True)
            default_log.write_text('untouched\n')
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'fetch_workers', return_value=[]), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
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
            log_path = Path(directory) / 'fleet-watch-test.log'
            home_root = Path(directory) / 'home'
            home_root.mkdir()
            default_log = home_root / '.orca' / 'logs' / 'fleet-watch.log'
            default_log.parent.mkdir(parents=True)
            default_log.write_text('seed\n')
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'fetch_workers', return_value=[]), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.object(fw.time, 'time', return_value=T0):
                code = fw.main()
                self.assertEqual(code, 0)
            self.assertTrue(log_path.is_file())
            self.assertIn('pass ok', log_path.read_text())
            self.assertEqual(default_log.read_text(), 'seed\n')


if __name__ == '__main__':
    unittest.main()


def remote_worker(**kw):
    """A supervised worker on a paired server; its clock reads stale until its transcript proves activity."""
    w = base_worker(
        server='niteking',
        projection={
            'host': {'id': 'niteking'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        },
    )
    w.update(kw)
    return w


def transcript_rpc(calls, messages):
    """Fake rpc: worker-read returns one transcript page; every other call returns an empty result."""
    def rpc(*a):
        calls.append(a)
        if a[:2] == ('orchestration', 'worker-read'):
            return {'dispatchId': 'disp_fixture', 'transcript': {'messages': messages, 'nextCursor': None}}
        return {}
    return rpc


def tool_message(timestamp_ms):
    return {'id': 'm%d' % timestamp_ms, 'role': 'tool', 'timestamp': timestamp_ms,
            'blocks': [{'type': 'tool-result', 'output': 'ok'}]}


class RemoteWorkerStall(unittest.TestCase):
    def test_active_remote_worker_is_not_flagged_or_stopped(self):
        calls = []
        w = remote_worker()
        recent = [tool_message(int((T0 - 60) * 1000))]
        state = mark_own({}, 'disp_fixture')
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, transcript_rpc(calls, recent))
        self.assertEqual(notices, [])
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertIn('remote_stall_check=disp_fixture:active', bits)

    def test_silent_remote_worker_is_flagged_once(self):
        calls = []
        w = remote_worker(dispatchId='disp_silent')
        old = [tool_message(OLD_MS)]
        state = {}
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, transcript_rpc(calls, old))
        self.assertEqual(len(notices), 1)
        self.assertIn('stall_report=disp_silent', bits)
        self.assertIn('~/dotfiles/.agents/skills/orca-team/worker-watch.sh', notices[0])
        again, _ = fw.worker_stall_pass(
            stall_test_config(), state, T0 + 60, [w], {'term_fix': OLD_MS}, transcript_rpc(calls, old))
        self.assertEqual(again, [])

    def test_unreadable_remote_transcript_is_not_flagged(self):
        calls = []

        def rpc(*a):
            calls.append(a)
            if a[:2] == ('orchestration', 'worker-read'):
                raise fw.OrcaReadError('orca CLI failed')
            return {}

        notices, bits = fw.worker_stall_pass(
            stall_test_config(), {}, T0, [remote_worker()], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(notices, [])
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertIn('remote_stall_check=disp_fixture:unknown', bits)


WINDOW = fw.STALL_IDLE_LIMIT_DEFAULT


class StallLadder(unittest.TestCase):
    """Owner Q6 (#1842): nudge after 2 stall windows, stop and release after 3, never with unpushed work."""

    def setUp(self):
        self.calls = []
        self.edits = []

    def rpc(self, *a):
        self.calls.append(a)
        return {}

    def act(self, argv):
        self.edits.append(argv)
        return 0

    def run_pass(self, state, now, last_s, w, head='sha1', holds=False, pr_rows=()):
        term = {'term_fix': int(last_s * 1000)}
        return fw.worker_stall_pass(
            stall_test_config(), state, now, [w], term, self.rpc, act=self.act,
            head_of=lambda _w: head, holds_work=lambda _w: holds, pr_list=lambda _repo: list(pr_rows))

    def stops(self):
        return [c for c in self.calls if c[:2] == ('orchestration', 'worker-stop')]

    def sends(self):
        return [c for c in self.calls if c[:2] == ('terminal', 'send')]

    def issue_worker(self):
        return base_worker(dispatchId='disp_ladder', githubPullRequestNumber=None, title='#77|fullstack-dev')

    def climb_to_nudge(self, state, w, **kw):
        start = T0 - WINDOW - 60
        self.run_pass(state, T0, start, w, **kw)
        self.assertEqual(self.sends(), [])
        _, bits = self.run_pass(state, start + 2 * WINDOW, start, w, **kw)
        self.assertIn('stall_nudge=disp_ladder', bits)
        return start

    def test_nudges_once_after_two_windows(self):
        state, w = {}, self.issue_worker()
        start = self.climb_to_nudge(state, w)
        self.assertEqual(len(self.sends()), 1)
        self.assertIn('no new commit', self.sends()[0][5])
        self.run_pass(state, start + 2 * WINDOW + 60, start, w)
        self.assertEqual(len(self.sends()), 1)
        self.assertEqual(self.stops(), [])

    def test_stops_and_releases_after_third_window(self):
        state, w = {}, self.issue_worker()
        start = self.climb_to_nudge(state, w)
        # The nudge made fresh output; that must not reset the ladder.
        fresh = start + 3 * WINDOW
        notices, bits = self.run_pass(state, start + 3 * WINDOW + 1, fresh, w)
        self.assertIn('stall_release=disp_ladder', bits)
        self.assertEqual(len(self.stops()), 1)
        self.assertTrue(any(c[:2] == ('orchestration', 'worker-release') for c in self.calls))
        board = [c for c in self.calls if c[:2] == ('worktree', 'set')]
        self.assertEqual(board, [('worktree', 'set', '--worktree', 'path:/p', '--workspace-status', 'archived')])
        self.assertEqual(self.edits, [['gh', 'issue', 'edit', '77', '--repo', 'o/r', '--add-label', 'ready-for-agent',
                                       '--remove-label', fw.ISSUE_CLAIM_LABEL]])
        released = [n for n in notices if 'stopped and released' in n]
        self.assertEqual(len(released), 1)
        self.assertIn('#77', released[0])
        again, _ = self.run_pass(state, start + 5 * WINDOW, start, w)
        self.assertEqual(len(self.stops()), 1)
        self.assertFalse(any('stopped and released' in n for n in again))

    def test_unpushed_work_is_never_stopped(self):
        state, w = {}, self.issue_worker()
        start = self.climb_to_nudge(state, w, holds=True)
        notices, bits = self.run_pass(state, start + 3 * WINDOW + 1, start, w, holds=True)
        self.assertIn('stall_hold=disp_ladder', bits)
        self.assertEqual(self.stops(), [])
        self.assertEqual(self.edits, [])
        self.assertEqual(len([n for n in notices if 'did not stop' in n]), 1)
        again, _ = self.run_pass(state, start + 4 * WINDOW, start, w, holds=True)
        self.assertFalse(any('did not stop' in n for n in again))

    def test_unpushed_resource_holds_with_real_checker(self):
        self.assertTrue(fw.stall_holds_work(base_worker(resource={'worktreeId': 'r::/p', 'retainedReason': 'unpushed'})))
        self.assertTrue(fw.stall_holds_work(base_worker(resource={'worktreeId': 'r::/no/such/checkout'})))

    def test_new_commit_resets_the_ladder(self):
        state, w = {}, self.issue_worker()
        start = self.climb_to_nudge(state, w)
        _, bits = self.run_pass(state, start + 3 * WINDOW + 1, start, w, head='sha2')
        self.assertNotIn('stall_release=disp_ladder', bits)
        self.assertEqual(self.stops(), [])

    def test_open_pr_keeps_the_issue_claimed(self):
        state, w = {}, self.issue_worker()
        rows = [{'number': 5, 'state': 'OPEN', 'body': 'Closes #77', 'headRefName': 'b',
                 'closingIssuesReferences': [{'number': 77}]}]
        start = self.climb_to_nudge(state, w, pr_rows=rows)
        _, bits = self.run_pass(state, start + 3 * WINDOW + 1, start, w, pr_rows=rows)
        self.assertIn('stall_release=disp_ladder', bits)
        self.assertEqual(self.edits, [])

    def test_waiting_on_coordinator_is_not_nudged(self):
        state, w = {}, self.issue_worker()
        start = T0 - 2 * WINDOW - 60
        fw.worker_stall_pass(stall_test_config(), state, T0, [w], {'term_fix': int(start * 1000)}, self.rpc,
                             act=self.act, head_of=lambda _w: 'sha1', holds_work=lambda _w: False,
                             waiting={'disp_ladder'})
        self.assertEqual(self.sends(), [])

    def test_failed_nudge_never_leads_to_a_stop(self):
        state, w = {}, self.issue_worker()
        start = T0 - WINDOW - 60
        self.run_pass(state, T0, start, w)

        def no_send(*a):
            self.calls.append(a)
            if a[:2] == ('terminal', 'send'):
                raise fw.OrcaReadError('send failed')
            return {}

        for now in (start + 2 * WINDOW, start + 3 * WINDOW + 1, start + 4 * WINDOW):
            _, bits = fw.worker_stall_pass(
                stall_test_config(), state, now, [w], {'term_fix': int(start * 1000)}, no_send, act=self.act,
                head_of=lambda _w: 'sha1', holds_work=lambda _w: False)
            self.assertNotIn('stall_nudge=disp_ladder', bits)
        self.assertEqual(self.stops(), [])

    def test_remote_worker_with_clean_local_path_is_not_stopped(self):
        state = {}
        w = self.issue_worker()
        w['projection'] = dict(w['projection'], host={'id': 'otherHost'})
        silent = [tool_message(int((T0 - 10 * WINDOW) * 1000))]

        def rpc(*a):
            self.calls.append(a)
            if a[:2] == ('orchestration', 'worker-read'):
                return {'transcript': {'messages': silent, 'nextCursor': None}}
            return {}

        start = T0 - WINDOW - 60
        notices = []
        for now in (T0, start + 2 * WINDOW, start + 3 * WINDOW + 1):
            n, _bits = fw.worker_stall_pass(
                stall_test_config(), state, now, [w], {'term_fix': int(start * 1000)}, rpc, act=self.act,
                head_of=lambda _w: 'sha1', holds_work=lambda _w: False)
            notices += n
        self.assertEqual(self.stops(), [])
        self.assertTrue(any('did not stop' in str(n) for n in notices), notices)

    def test_remote_worker_that_resumes_leaves_the_ladder(self):
        state = {}
        w = self.issue_worker()
        w['projection'] = dict(w['projection'], host={'id': 'otherHost'})
        start = T0 - WINDOW - 60
        reads = {'stamp': int((T0 - 2 * WINDOW) * 1000)}

        def rpc(*a):
            self.calls.append(a)
            if a[:2] == ('orchestration', 'worker-read'):
                return {'transcript': {'messages': [tool_message(reads['stamp'])], 'nextCursor': None}}
            return {}

        def run(now):
            return fw.worker_stall_pass(
                stall_test_config(), state, now, [w], {'term_fix': int(start * 1000)}, rpc, act=self.act,
                head_of=lambda _w: 'sha1', holds_work=lambda _w: False)[1]

        run(T0)
        self.assertEqual(state['stall_ladder']['disp_ladder']['since'], T0 - 2 * WINDOW)
        reads['stamp'] = int((T0 + WINDOW) * 1000)
        bits = run(T0 + WINDOW + 60)
        self.assertIn('remote_stall_check=disp_ladder:active', bits)
        self.assertNotIn('disp_ladder', state['stall_ladder'])
        self.assertEqual(self.stops(), [])
        self.assertEqual(self.sends(), [])

    def test_remote_worker_quiet_one_window_after_an_hour_is_not_nudged(self):
        state = {}
        w = self.issue_worker()
        w['projection'] = dict(w['projection'], host={'id': 'otherHost'})
        # server.asOf is an hour old, but the transcript shows tool activity until one window ago.
        start = T0 - 3 * WINDOW
        quiet = T0 - WINDOW - 60

        def rpc(*a):
            self.calls.append(a)
            if a[:2] == ('orchestration', 'worker-read'):
                return {'transcript': {'messages': [tool_message(int(quiet * 1000))], 'nextCursor': None}}
            return {}

        for now in (T0, T0 + 120):
            fw.worker_stall_pass(
                stall_test_config(), state, now, [w], {'term_fix': int(start * 1000)}, rpc, act=self.act,
                head_of=lambda _w: 'sha1', holds_work=lambda _w: False)
        self.assertEqual(state['stall_ladder']['disp_ladder']['since'], quiet)
        self.assertEqual(self.sends(), [])

    def test_settled_worker_leaves_the_ladder(self):
        state, w = {}, self.issue_worker()
        self.climb_to_nudge(state, w)
        settled = dict(w, workerState='succeeded')
        self.run_pass(state, T0 + 10 * WINDOW, T0 - 2 * WINDOW, settled)
        self.assertEqual(self.stops(), [])
        self.assertNotIn('disp_ladder', state['stall_ladder'])

    def test_own_verifier_still_restarts_instead(self):
        state = mark_own({}, 'disp_ladder')
        w = self.issue_worker()
        _, bits = self.run_pass(state, T0, T0 - 4 * WINDOW, w)
        self.assertNotIn('stall_nudge=disp_ladder', bits)
        self.assertEqual(len(self.stops()), 1)


class RemoteReadRetry(unittest.TestCase):
    def test_failed_read_is_retried_once(self):
        calls = []

        def rpc(*a):
            calls.append(a)
            if len(calls) == 1:
                raise fw.OrcaReadError('blip')
            return {'transcript': {'messages': [tool_message(int((T0 - 60) * 1000))], 'nextCursor': None}}

        self.assertEqual(fw.remote_worker_activity(rpc, 'd', 'env', T0, WINDOW), 'active')
        self.assertEqual(len(calls), 2)

    def test_two_failed_reads_are_unknown(self):
        calls = []

        def rpc(*a):
            calls.append(a)
            raise fw.OrcaReadError('down')

        self.assertEqual(fw.remote_worker_activity(rpc, 'd', 'env', T0, WINDOW), 'unknown')
        self.assertEqual(len(calls), 2)


def done_message(mid='m1', dispatch='disp_done', body='', outcome='succeeded'):
    return {'id': mid, 'type': 'worker_done', 'body': body, 'payload': {'dispatchId': dispatch, 'outcome': outcome}}


class DoneRelayBoard(unittest.TestCase):
    def setUp(self):
        self.set_calls = []

    def set_status(self, worker, status):
        self.set_calls.append((worker['dispatchId'], status))
        return True

    def relay(self, worker, board='in-progress', pr_row=None, state=None, messages=None):
        state = {} if state is None else state
        with patch.object(fw, 'repo_for_worker', return_value='o/r'):
            return fw.relay_done_board(
                messages or [done_message()], [worker], stall_test_config(), state,
                lambda _w: board, self.set_status, lambda _repo, _n: pr_row), state

    def test_open_pr_moves_to_in_review(self):
        moved, state = self.relay(base_worker(dispatchId='disp_done'), pr_row={'number': 99, 'state': 'OPEN'})
        self.assertEqual(self.set_calls, [('disp_done', 'in-review')])
        self.assertEqual(moved, ['disp_done:in-review'])
        self.relay(base_worker(dispatchId='disp_done'), pr_row={'number': 99, 'state': 'OPEN'}, state=state)
        self.assertEqual(len(self.set_calls), 1)

    def test_no_pr_moves_to_completed(self):
        self.relay(base_worker(dispatchId='disp_done', githubPullRequestNumber=None))
        self.assertEqual(self.set_calls, [('disp_done', 'completed')])

    def test_board_the_worker_set_is_left_alone(self):
        self.relay(base_worker(dispatchId='disp_done'), board='in-review', pr_row={'number': 99, 'state': 'OPEN'})
        self.assertEqual(self.set_calls, [])

    def test_unknown_board_or_pr_waits_for_next_pass(self):
        moved, state = self.relay(base_worker(dispatchId='disp_done'), board=None)
        self.assertEqual((moved, self.set_calls, state['board_done']), ([], [], []))
        moved, state = self.relay(base_worker(dispatchId='disp_done'), pr_row=None)
        self.assertEqual((moved, self.set_calls, state['board_done']), ([], [], []))

    def test_checkout_missing_from_board_is_marked_handled(self):
        moved, state = self.relay(base_worker(dispatchId='disp_done'), board='absent',
                                  pr_row={'number': 99, 'state': 'OPEN'})
        self.assertEqual((moved, self.set_calls, state['board_done']), ([], [], ['m1']))

    def test_main_pass_lists_the_board_and_sets_the_card(self):
        calls = []
        worker = base_worker(dispatchId='disp_done', githubPullRequestNumber=None,
                             resource={'worktreeId': 'repo-x::/w/fixture/done'})
        inventory = {'messages': [done_message()], 'workers': [worker], 'alive': {'run_fixture': True}, 'leads': {}}

        def rpc(*args):
            calls.append(args)
            if args[:2] == ('worktree', 'list'):
                return {'worktrees': [{'path': '/w/fixture/done', 'workspaceStatus': 'in-progress'}]}
            return {}

        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps({'runs': list(STALL_RUNS), 'worker_stall': {'label_repo': 'o/r'}}))
            state.write_text('{}')
            with isolated_main_env(directory), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.object(fw, 'read_orca_inventory', return_value=inventory), \
                    patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(fw, 'pr_notices', return_value=[]), \
                    patch.object(fw, 'usage_notices', return_value=[]), \
                    patch.object(fw, 'deliver_notices', return_value=None), \
                    patch.object(fw.time, 'time', return_value=T0):
                fw.main()
                saved = json.loads(state.read_text())
        sets = [c for c in calls if c[:2] == ('worktree', 'set')]
        self.assertIn(('worktree', 'set', '--worktree', 'path:/w/fixture/done', '--workspace-status', 'completed'), sets)
        self.assertEqual(saved.get('board_done'), ['m1'])

    def test_bounced_or_failed_done_is_skipped(self):
        self.relay(base_worker(dispatchId='disp_done'), state={'bounced_done': ['m1']},
                   pr_row={'number': 99, 'state': 'OPEN'})
        self.relay(base_worker(dispatchId='disp_done'), messages=[done_message(outcome='failed')],
                   pr_row={'number': 99, 'state': 'OPEN'})
        self.assertEqual(self.set_calls, [])


class ReleaseBoardStatus(unittest.TestCase):
    def run_release(self, pr_state):
        calls = []
        pr_row = {'number': 99, 'state': pr_state, 'statusCheckRollup': [
            {'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}]}
        with patch.object(fw, 'repo_for_worker', return_value='o/r'):
            freed = fw.release_green_successes(
                [done_message()], [base_worker(dispatchId='disp_done')], stall_test_config(), {},
                lambda _d: None, lambda _r, _n: pr_row, set_status=lambda w, s: calls.append(s) or True)
        return freed, calls

    def test_merged_pr_release_sets_completed(self):
        freed, calls = self.run_release('MERGED')
        self.assertEqual(freed, ['disp_done'])
        self.assertEqual(calls, ['completed'])

    def test_open_pr_release_keeps_the_card(self):
        freed, calls = self.run_release('OPEN')
        self.assertEqual(freed, ['disp_done'])
        self.assertEqual(calls, [])


# A test loads fleet-watch.py when it execs the module or runs it with python. A mere mention does not count.
LOADS_FLEET_WATCH = re.compile(
    r"spec_from_file_location\([^)]*fleet-watch\.py|load\('fleet_watch', 'fleet-watch\.py'\)"
    r"|\$\{?PYTHON\b[^\n]*fleet-watch\.py|\bpython3?\b[^\n]*(?<![\w-])fleet-watch\.py")
ISOLATION_CHILD = 'FLEET_WATCH_LOG_ISOLATION_CHILD'
# Load fleet-watch.py without logging, and sit outside the fleet-watch test globs (#1864).
LOG_EXEMPT = frozenset({'agy-signin.test.sh', 'worker-startup.test.sh',
                        'test_pr_body_gate_builder.py', 'test_tier0_audit_1730.py'})


class TestLogIsolation(unittest.TestCase):
    """#1864: no fleet-watch test writes its fixture lines to ~/.orca/logs/fleet-watch.log."""
    TESTS = Path(__file__).resolve().parent
    RUNS = ('fleet-watch-babysit.test.sh', 'fleet-watch-wake.test.sh', 'test_fleet_watch_1016.py',
            'test_fleet_watch_1199.py', 'test_fleet_watch_1706.py', 'test_fleet_watch_986.py',
            'test_fleet_watch_stall.py')

    def test_every_file_that_loads_fleet_watch_isolates_the_log(self):
        missing = []
        for path in sorted(self.TESTS.iterdir()):
            if path.suffix not in ('.py', '.sh') or path.name in LOG_EXEMPT or path == Path(__file__).resolve():
                continue
            text = path.read_text()
            if not LOADS_FLEET_WATCH.search(text):
                continue
            if 'FLEET_WATCH_LOG_PATH' not in text and 'fleet_watch_test_env' not in text:
                missing.append(path.name)
        self.assertEqual(missing, [])

    def test_blank_log_path_gets_a_temp_file(self):
        code = ('import os, fleet_watch_test_env; p = os.environ["FLEET_WATCH_LOG_PATH"]; '
                'print(p); print(os.path.isdir(os.path.dirname(p)))')
        for blank in (None, '', '  '):
            env = {k: v for k, v in os.environ.items() if k != 'FLEET_WATCH_LOG_PATH'}
            if blank is not None:
                env['FLEET_WATCH_LOG_PATH'] = blank
            out = subprocess.run(['python3', '-c', code], cwd=self.TESTS, env=env,
                                 capture_output=True, text=True, check=True).stdout.split()
            self.assertEqual(out[1], 'True')
            self.assertNotIn('.orca', out[0])
            self.assertFalse(os.path.exists(os.path.dirname(out[0])), 'temp dir not removed at exit')

    @unittest.skipIf(os.environ.get(ISOLATION_CHILD), 'child run of the isolation check')
    def test_runs_with_log_path_unset_write_no_default_log_line(self):
        with tempfile.TemporaryDirectory() as home:
            env = {k: v for k, v in os.environ.items() if k != 'FLEET_WATCH_LOG_PATH'}
            env.update({'HOME': home, ISOLATION_CHILD: '1',
                        'ASDF_DATA_DIR': os.environ.get('ASDF_DATA_DIR') or str(Path.home() / '.asdf')})
            for name in self.RUNS:
                cmd = ['bash', str(self.TESTS / name)] if name.endswith('.sh') else ['python3', str(self.TESTS / name)]
                result = subprocess.run(cmd, cwd=self.TESTS, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, '%s failed:\n%s' % (name, result.stderr[-2000:]))
            self.assertFalse((Path(home) / '.orca' / 'logs' / 'fleet-watch.log').exists())
