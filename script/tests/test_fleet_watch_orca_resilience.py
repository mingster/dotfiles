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


class MainOrcaInventoryFailure(unittest.TestCase):
    def test_inbox_timeout_skips_worker_alerts_but_runs_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            stamp = directory / 'stamp'
            stamp.write_text('x')
            now = 1_000_000.0
            # Stale stamp (>30 min) so backup_notices opens an issue path
            os.utime(stamp, (now - 4000, now - 4000))

            config = {
                'runs': [{'id': 'r', 'terminal': 'term_x', 'waiter_pattern': 'waiter_pat'}],
                'backup': {'stamp': str(stamp), 'issue_repo': 'owner/repo'},
            }
            cfg_path = directory / 'config.json'
            state_path = directory / 'state.json'
            cfg_path.write_text(json.dumps(config))
            state_path.write_text('{}')
            rpc_calls = []
            gh_calls = []

            def rpc_side_effect(*args):
                rpc_calls.append(args)
                if args[:2] == ('orchestration', 'inbox'):
                    raise subprocess.TimeoutExpired('orca', 15)
                return {}

            def run_gh_side_effect(command):
                gh_calls.append(command)
                return 0

            deliver_real = fw.deliver_notices

            def safe_deliver(*a, **k):
                deliver_real(*a, **k)

            with patch('sys.argv', ['fleet-watch', '--config', str(cfg_path), '--state', str(state_path)]), \
                    patch.object(fw, 'rpc', side_effect=rpc_side_effect), \
                    patch.object(fw, 'run_gh', side_effect=run_gh_side_effect), \
                    patch.object(fw, 'open_issue_titles', return_value=[]), \
                    patch.object(fw, 'deliver_notices', side_effect=safe_deliver), \
                    patch.object(fw.time, 'time', return_value=now):
                code = fw.main()
            self.assertEqual(code, 0)
            self.assertTrue(any(c[:2] == ('orchestration', 'inbox') for c in rpc_calls))
            self.assertTrue(any('issue' in c and 'create' in c for c in gh_calls))


if __name__ == '__main__':
    unittest.main()
