#!/usr/bin/env python3
"""When Orca inbox fails, main still runs backup checks and does not abort."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

_clean_spec = importlib.util.spec_from_file_location('fleet_watch_unpatched', Path(__file__).parent.parent / 'fleet-watch.py')
_fw_clean = importlib.util.module_from_spec(_clean_spec)
_clean_spec.loader.exec_module(_fw_clean)
DELIVER_NOTICES_REAL = _fw_clean.deliver_notices

REPO = 'mingster/dotfiles'
HEAD = 'a' * 40


def _stale_stamp_file(directory, now):
    stamp = directory / 'stamp'
    stamp.write_text('x')
    os.utime(stamp, (now - 4000, now - 4000))
    return stamp


class MainOrcaInventoryFailure(unittest.TestCase):
    def test_inbox_timeout_skips_worker_alerts_but_runs_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)

            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO], 'stuck_minutes': 30},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            rpc_calls = []
            gh_calls = []
            delivered = []

            def rpc_side_effect(*args):
                rpc_calls.append(args)
                if args[:2] == ('orchestration', 'inbox'):
                    raise subprocess.TimeoutExpired('orca', 15)
                return {}

            def run_gh_side_effect(command):
                gh_calls.append(command)
                return 0

            fetch_repos = []

            def fetch_prs_side_effect(repo):
                fetch_repos.append(repo)
                return [
                    {
                        'number': 1,
                        'state': 'OPEN',
                        'headRefOid': HEAD,
                        'comments': [],
                        'statusCheckRollup': [],
                        'mergeCommit': None,
                    }
                ]

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered.extend(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', side_effect=run_gh_side_effect), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', fetch_prs_side_effect), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertTrue(any(c[:2] == ('orchestration', 'inbox') for c in rpc_calls))
            self.assertTrue(any('issue' in c and 'create' in c for c in gh_calls))
            self.assertTrue(any(fw.ORCA_SKIP_NOTICE in line for line in delivered))
            self.assertIn(REPO, fetch_repos)
            state = json.loads(state_path.read_text())
            self.assertTrue(state.get('orca_inventory_skip_latched'))

    def test_second_failed_pass_does_not_repeat_skip_notice_line(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)
            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO]},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            delivered_passes = []

            def rpc_side_effect(*args):
                if args[:2] == ('orchestration', 'inbox'):
                    raise subprocess.TimeoutExpired('orca', 15)
                return {}

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered_passes.append(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', return_value=0), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', return_value=[]), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                fw.main()
                fw.main()
            skip_lines = [p for p in delivered_passes if any(fw.ORCA_SKIP_NOTICE in x for x in p)]
            self.assertEqual(len(skip_lines), 1)

    def test_worker_list_failure_skips_alerts_and_runs_pr_check(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)
            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO]},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            gh_calls = []
            fetch_repos = []

            delivered = []

            def rpc_side_effect(*args):
                if args[:2] == ('orchestration', 'inbox'):
                    return {'messages': []}
                if len(args) >= 2 and args[1] == 'worker-list':
                    raise ValueError('bad page')
                return {}

            def run_gh_side_effect(command):
                gh_calls.append(command)
                return 0

            def fetch_prs_side_effect(repo):
                fetch_repos.append(repo)
                return []

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered.extend(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', side_effect=run_gh_side_effect), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', side_effect=fetch_prs_side_effect), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertEqual(fetch_repos, [REPO])
            self.assertTrue(any(fw.ORCA_SKIP_NOTICE in line for line in delivered))

    def test_malformed_inbox_missing_messages_field_skips_and_runs_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)
            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO]},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            gh_calls = []
            fetch_repos = []

            def rpc_side_effect(*args):
                if args[:2] == ('orchestration', 'inbox'):
                    return {}
                return {'workers': [], 'page': {'hasMore': False}}

            def run_gh_side_effect(command):
                gh_calls.append(command)
                return 0

            def fetch_prs_side_effect(repo):
                fetch_repos.append(repo)
                return []

            delivered = []

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered.extend(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', side_effect=run_gh_side_effect), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', side_effect=fetch_prs_side_effect), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertEqual(fetch_repos, [REPO])
            self.assertTrue(any(fw.ORCA_SKIP_NOTICE in line for line in delivered))

    def test_terminal_show_refused_skips_alerts_with_skip_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)
            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'leads': [{'name': 'lead1', 'terminal': 'term_lead'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO]},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            delivered = []

            def rpc_side_effect(*args):
                if args[:2] == ('orchestration', 'inbox'):
                    return {'messages': []}
                if len(args) >= 2 and args[1] == 'worker-list':
                    return {'workers': [], 'page': {'hasMore': False}}
                if args[:2] == ('terminal', 'show'):
                    raise fw.OrcaReadError('terminal refused')
                return {}

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered.extend(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', return_value=0), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', return_value=[]), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertTrue(any(fw.ORCA_SKIP_NOTICE in line for line in delivered))

    def test_pgrep_failure_skips_alerts_with_skip_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            now = 1_000_000.0
            stamp = _stale_stamp_file(directory, now)
            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
                'pr_watch': {'repos': [REPO]},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            delivered = []
            real_run = fw.subprocess.run

            def rpc_side_effect(*args):
                if args[:2] == ('orchestration', 'inbox'):
                    return {'messages': []}
                if len(args) >= 2 and args[1] == 'worker-list':
                    return {'workers': [], 'page': {'hasMore': False}}
                return {}

            def subprocess_run_side_effect(cmd, **kwargs):
                if cmd[:1] == ['pgrep']:
                    raise subprocess.TimeoutExpired('pgrep', 5)
                return real_run(cmd, **kwargs)

            def capture_deliver(config, state, new_lines, rpc_call=fw.rpc):
                delivered.extend(list(new_lines))
                DELIVER_NOTICES_REAL(config, state, new_lines, rpc_call)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw.subprocess, 'run', side_effect=subprocess_run_side_effect), \
                    patch.object(fw, 'run_gh', return_value=0), \
                    patch.object(fw, 'open_backup_issue_exists', return_value=False), \
                    patch.object(fw, 'fetch_prs', return_value=[]), \
                    patch.object(fw, 'deliver_notices', side_effect=capture_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertTrue(any(fw.ORCA_SKIP_NOTICE in line for line in delivered))


if __name__ == '__main__':
    unittest.main()
