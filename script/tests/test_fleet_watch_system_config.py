"""The pass reads the coordinator Run and repos from Orca and git.

Orca replies are the recordings under script/tests/fixtures/fleet-watch/.
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fleet_watch', ROOT / 'script' / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

_env_spec = importlib.util.spec_from_file_location(
    'fleet_watch_test_env', ROOT / 'script' / 'tests' / 'fleet_watch_test_env.py')
_env = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(_env)
isolated_main_env = _env.isolated_main_env

T0 = 1_700_000_000
OLD_MS = int((T0 - 4000) * 1000)
DOC = ROOT / 'docs' / 'agents' / 'fleet-watch.md'
HAND_KEPT = (
    'Hand-kept keys: `repo_roots`, `host_caps`, `backup.stamp`, '
    '`heavy_gate.hosts`, `wrap_up.hosts`.'
)


def recorded_result(name):
    """The result object from one recorded Orca reply. The file is not rewritten."""
    fixtures = ROOT / 'script' / 'tests' / 'fixtures' / 'fleet-watch'
    dirs = sorted(path for path in fixtures.iterdir() if path.is_dir() and path.name.startswith('orca-'))
    if not dirs:
        raise FileNotFoundError('no recorded replies in %s' % fixtures)
    raw = json.loads((dirs[-1] / (name + '.json')).read_text(encoding='utf-8'))
    for key in ('exit_code', 'stdout'):
        if key not in raw:
            raise AssertionError('%s missing %s' % (name, key))
    if raw['exit_code'] != 0:
        raise AssertionError('%s exit %s' % (name, raw['exit_code']))
    body = json.loads(raw['stdout'])
    if body.get('ok') is not True or 'result' not in body:
        raise AssertionError('%s is not an ok Orca reply' % name)
    return body['result']


def git_checkout(url):
    tmp = tempfile.TemporaryDirectory()
    path = Path(tmp.name) / 'repo'
    path.mkdir()
    subprocess.run(['git', 'init', '-q', str(path)], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', url], check=True, capture_output=True)
    return tmp, path


def stalled_worker(**extra):
    row = {
        'dispatchId': 'disp_fixture',
        'taskId': 'task_fix',
        'runId': 'run_placeholder',
        'terminalState': 'retained',
        'dispatchStatus': 'dispatched',
        'agentTerminalHandle': 'term_fix',
        'agent': 'claude',
        'resource': {'worktreeId': 'missing::/no/such/checkout'},
        'projection': {
            'host': {'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        },
    }
    row.update(extra)
    return row


class RecordedRun(unittest.TestCase):
    def test_full_list_picks_a_run_with_a_coordinator_terminal(self):
        chosen = fw.select_coordinator_run(recorded_result('run-list-full')['runs'])
        self.assertIsNotNone(chosen)
        self.assertEqual(chosen['id'], 'run_placeholder')
        self.assertEqual(chosen['coordinator_handle'], 'term_placeholder')

    def test_concise_list_has_no_coordinator_terminal(self):
        self.assertIsNone(fw.select_coordinator_run(recorded_result('run-list')['runs']))

    def test_run_show_supplies_the_terminal(self):
        shown = recorded_result('run-show')
        self.assertEqual(fw.coordinator_terminal_from_show(shown, 'term_other'), 'term_placeholder')


class SystemConfig(unittest.TestCase):
    def test_file_runs_and_repos_are_replaced_from_the_recordings(self):
        held = tempfile.TemporaryDirectory()
        self.addCleanup(held.cleanup)
        checkout_tmp, checkout = git_checkout('git@github.com:owner/app.git')
        self.addCleanup(checkout_tmp.cleanup)
        stamp = Path(held.name) / 'stamp'
        stamp.write_text('x')
        config = {
            'runs': [{'id': 'run_stale', 'terminal': 'term_stale', 'waiter_pattern': 'old'}],
            'repo_roots': [str(checkout)],
            'issue_scan': {'enabled': False, 'repos': ['owner/wrong']},
            'pr_watch': {'repos': ['owner/wrong']},
            'worker_stall': {'label_repo': 'owner/wrong', 'label_cooldown_seconds': 0},
            'backup': {'stamp': str(stamp), 'issue_repo': 'owner/wrong'},
            'heavy_gate': {'hosts': {'h': str(Path(held.name) / 'wait')}, 'issue_repo': 'owner/wrong'},
            'wrap_up': {'hosts': {'h': str(Path(held.name) / 'wrap')}, 'issue_repo': 'owner/wrong'},
        }
        full = recorded_result('run-list-full')
        show = recorded_result('run-show')
        asked = []

        def rpc(*args):
            asked.append(args)
            if args[:3] == ('orchestration', 'run-list', '--full'):
                return full
            if args[:2] == ('orchestration', 'run-show'):
                return show
            raise AssertionError(args)

        log_path = Path(held.name) / 'fleet-watch.log'
        with patch.object(fw, 'rpc', side_effect=rpc), \
                patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(log_path)}):
            self.assertEqual(fw.bind_pass_config(config), 'run')
        self.assertIn('coordinator run run_placeholder terminal term_placeholder', log_path.read_text(encoding='utf-8'))
        self.assertEqual(config['runs'], [{
            'id': 'run_placeholder',
            'terminal': 'term_placeholder',
            'waiter_pattern': 'orchestration check --run run_placeholder',
        }])
        self.assertTrue(any(call[:2] == ('orchestration', 'run-show') for call in asked))
        self.assertEqual(config['issue_scan']['enabled'], True)
        self.assertEqual(config['issue_scan']['run'], 'run_placeholder')
        self.assertEqual(config['issue_scan']['from_terminal'], 'term_placeholder')
        self.assertEqual(config['issue_scan']['repos'], ['owner/app'])
        self.assertEqual(config['issue_scan']['repo_roots'], {'owner/app': str(checkout)})
        self.assertEqual(config['pr_watch']['repos'], ['owner/app'])
        self.assertNotIn('label_repo', config['worker_stall'])
        self.assertTrue(config['worker_stall']['from_system'])
        self.assertEqual(config['worker_stall']['label_cooldown_seconds'], 0)
        for key in ('backup', 'heavy_gate', 'wrap_up'):
            self.assertEqual(config[key]['issue_repo'], fw.FAULT_REPO)
            self.assertNotIn('owner/wrong', json.dumps(config[key]))

    def test_unreadable_orca_leaves_the_file_alone(self):
        config = {
            'runs': [{'id': 'file-run', 'terminal': 'term_file'}],
            'issue_scan': {'enabled': False},
            'worker_stall': {'label_repo': 'owner/file'},
        }
        self.assertEqual(fw.bind_pass_config(config, read_run=lambda: ('unread', None)), 'unread')
        self.assertEqual(config['runs'][0]['id'], 'file-run')
        self.assertFalse(config['issue_scan']['enabled'])
        self.assertEqual(config['worker_stall']['label_repo'], 'owner/file')

    def test_no_coordinator_run_keeps_the_queue_and_exits_0(self):
        page = json.loads(json.dumps(recorded_result('run-list')))
        page['nextCursor'] = None
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / 'config.json'
            state = directory / 'state.json'
            config.write_text(json.dumps({
                'runs': [{'id': 'run_stale', 'terminal': 'term_stale', 'waiter_pattern': 'old'}],
            }))
            queued = {
                'notice_queue': {
                    'term_old': [{'text': 'queued notice', 'urgent': False, 'passes': 0}],
                },
            }
            state.write_text(json.dumps(queued))

            def rpc(*args):
                if args[:3] == ('orchestration', 'run-list', '--full'):
                    return page
                raise AssertionError('pass continued: %r' % (args,))

            with isolated_main_env(str(directory)), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(state.read_text()), queued)
            log = (directory / 'fleet-watch-test.log').read_text(encoding='utf-8')
            self.assertIn(fw.NO_COORDINATOR_RUN, log)

    def test_unreadable_orca_with_no_file_runs_still_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            config = directory / 'config.json'
            state = directory / 'state.json'
            config.write_text('{}')
            state.write_text('{}')

            def rpc(*_args):
                return {}

            with isolated_main_env(str(directory)), \
                    patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                    patch.object(fw, 'rpc', side_effect=rpc):
                code = fw.main()
            self.assertEqual(code, 1)
            log = (directory / 'fleet-watch-test.log').read_text(encoding='utf-8')
            self.assertIn('has no runs; refusing this pass', log)
            self.assertNotIn(fw.NO_COORDINATOR_RUN, log)


class StallRepo(unittest.TestCase):
    def stall_config(self):
        return {
            'runs': [{'id': 'run_placeholder', 'terminal': 'term_placeholder', 'waiter_pattern': 'w'}],
            'worker_stall': {'from_system': True, 'label_cooldown_seconds': 0},
        }

    def test_stalled_own_worker_parks_against_its_checkout_repo(self):
        checkout_tmp, checkout = git_checkout('https://github.com/owner/app.git')
        self.addCleanup(checkout_tmp.cleanup)
        worker = stalled_worker(
            githubPullRequestNumber=99,
            resource={'worktreeId': 'wt::' + str(checkout)},
        )
        state = {
            'own_dispatches': {
                'disp_fixture': {'kind': 'verifier', 'restarted': True, 'restart_at': T0 - 4000},
            },
        }
        calls = []

        def act(command):
            calls.append(list(command))
            return 0

        notices, log_bits = fw.worker_stall_pass(
            self.stall_config(), state, T0, [worker], {'term_fix': OLD_MS}, lambda *_args: None, act=act,
        )
        self.assertTrue(any(str(notice).startswith('parked stall ') for notice in notices))
        self.assertTrue(any('stall_parked=disp_fixture' in bit for bit in log_bits))
        row = next(value for value in state['parked'].values() if value.get('dispatch') == 'disp_fixture')
        self.assertEqual(row.get('repo'), 'owner/app')
        self.assertEqual(row.get('pr'), 99)
        self.assertNotEqual(row.get('repo'), fw.FAULT_REPO)
        self.assertFalse(any(call[:3] == ['gh', 'pr', 'edit'] for call in calls))

    def test_stall_without_a_pr_parks_in_the_fleet_repo(self):
        worker = stalled_worker()
        state = {
            'own_dispatches': {
                'disp_fixture': {'kind': 'verifier', 'restarted': True, 'restart_at': T0 - 4000},
            },
        }
        calls = []

        def act(command):
            calls.append(list(command))
            return 0

        _notices, log_bits = fw.worker_stall_pass(
            self.stall_config(), state, T0, [worker], {'term_fix': OLD_MS}, lambda *_args: None, act=act,
        )
        row = next(value for value in state['parked'].values() if value.get('dispatch') == 'disp_fixture')
        self.assertEqual(row.get('repo'), fw.FAULT_REPO)
        self.assertNotIn('pr', row)
        self.assertTrue(any('stall_parked=disp_fixture' in bit for bit in log_bits))
        self.assertFalse(any(call[:3] == ['gh', 'issue', 'create'] for call in calls))
        self.assertFalse(any(call[:3] == ['gh', 'pr', 'edit'] for call in calls))

    def test_restart_failure_is_parked(self):
        calls = []

        def act(command):
            calls.append(list(command))
            return 0

        def rpc_call(*_args):
            raise fw.OrcaReadError('down')

        worker = stalled_worker()
        notices, log_bits = fw.worker_stall_pass(
            self.stall_config(),
            {'worker_stall': {}, 'own_dispatches': {'disp_fixture': {'kind': 'verifier'}}},
            T0, [worker], {'term_fix': OLD_MS}, rpc_call, act=act,
        )
        self.assertFalse(any(call[:3] == ['gh', 'issue', 'create'] for call in calls))
        self.assertTrue(any(str(notice).startswith('parked stall ') for notice in notices))
        self.assertTrue(any(bit.startswith('stall_restart_fail=') for bit in log_bits))


class BackupRepo(unittest.TestCase):
    def test_backup_alert_opens_in_the_fleet_repo(self):
        with tempfile.TemporaryDirectory() as directory:
            stamp = Path(directory) / 'stamp'
            stamp.write_text('x')
            os.utime(stamp, (T0 - 4000, T0 - 4000))
            config = {
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/wrong'},
                'repo_roots': [],
            }
            full = recorded_result('run-list-full')
            show = recorded_result('run-show')

            def rpc(*args):
                if args[:3] == ('orchestration', 'run-list', '--full'):
                    return full
                if args[:2] == ('orchestration', 'run-show'):
                    return show
                raise AssertionError(args)

            with patch.object(fw, 'rpc', side_effect=rpc), \
                    patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(Path(directory) / 'fleet-watch.log')}):
                self.assertEqual(fw.bind_pass_config(config), 'run')
            calls = []
            notices = fw.backup_notices(
                config, {}, T0, stamp_time=os.path.getmtime,
                act=lambda command: calls.append(list(command)) or 0,
                backup_issue_exists=lambda _repo: False,
            )
            self.assertTrue(notices)
            self.assertEqual(calls[0][calls[0].index('--repo') + 1], fw.FAULT_REPO)


class DocKeys(unittest.TestCase):
    def test_fleet_watch_doc_lists_the_hand_kept_keys(self):
        text = DOC.read_text(encoding='utf-8')
        self.assertIn(HAND_KEPT, text)
        self.assertNotIn('label_repo', text)
        self.assertNotIn('issue_repo', text)


if __name__ == '__main__':
    unittest.main()
