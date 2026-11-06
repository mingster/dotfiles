#!/usr/bin/env bash
# No orca: worker stall uses terminal lastOutputAt, worker-stop/start and gh label.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root / 'fleet-watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

T0 = 1_700_000_000  # unix seconds so lastOutputAt ms exceeds 1e12


def live_worker():
    return {
        'dispatchId': 'disp1',
        'terminalState': 'retained',
        'dispatchStatus': 'dispatched',
        'agentTerminalHandle': 'term_w',
        'githubPullRequestNumber': 42,
        'projection': {
            'outcome': 'in_progress',
            'liveness': {'verdict': 'live'},
        },
    }


class Stall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.env = patch.dict(os.environ, {'HOME': str(self.home)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.log_path = self.home / '.orca' / 'logs' / 'fleet-watch.log'

    def test_stall_restarts_once_then_labels(self):
        calls = []
        gh_calls = []
        # last output 3000s before pass at T0+4000 -> idle 3000s > 30 min (STALL_IDLE_LIMIT)
        term_ms = int((T0 + 1000) * 1000)

        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': [live_worker()], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': [{'handle': 'term_w', 'lastOutputAt': term_ms}]}
            return {}

        def fake_gh(command):
            gh_calls.append(list(command))
            return 0

        backup_stamp = self.home / 'stamp'
        backup_stamp.write_text('x')
        os.utime(backup_stamp, (T0 + 4000 - 700, T0 + 4000 - 700))

        config = self.home / 'config.json'
        state = self.home / 'state.json'
        config.write_text(json.dumps({
            'runs': [{'id': 'r1', 'terminal': 'tcoord', 'waiter_pattern': 'waiter-r1'}],
            'worker_stall': {'label_repo': 'owner/repo', 'label_cooldown_seconds': 0},
            'backup': {'stamp': str(backup_stamp), 'issue_repo': 'owner/repo'},
        }))

        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                patch.object(watch, 'rpc', side_effect=rpc), \
                patch.object(watch, 'run_gh', side_effect=fake_gh), \
                patch.object(watch, 'pr_notices', return_value=[]), \
                patch.object(watch, 'usage_notices', return_value=[]), \
                patch.object(watch, 'deliver_notices', return_value=None), \
                patch.object(watch.time, 'time', return_value=T0 + 4000):
            watch.main()
            watch.main()

        stops = [c for c in calls if c[:4] == ('orchestration', 'worker-stop', '--dispatch', 'disp1')]
        starts = [c for c in calls if len(c) >= 4 and c[:2] == ('orchestration', 'worker-start') and c[-2:] == ('--retry-of', 'disp1')]
        self.assertEqual(len(stops), 1)
        self.assertEqual(len(starts), 1)
        edits = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'pr', 'edit']]
        self.assertTrue(any('42' in c and 'needs-elon' in c for c in edits))
        log = self.log_path.read_text()
        self.assertIn('stall_restart=disp1', log)
        self.assertIn('stall_label_pr=disp1:42', log)
        self.assertIn('backup_stale', log)

    def test_no_worker_stop_without_stall_config(self):
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

        config = self.home / 'config.json'
        state = self.home / 'state.json'
        config.write_text(json.dumps({
            'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
        }))

        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                patch.object(watch, 'rpc', side_effect=rpc), \
                patch.object(watch, 'pr_notices', return_value=[]), \
                patch.object(watch, 'usage_notices', return_value=[]), \
                patch.object(watch, 'deliver_notices', return_value=None), \
                patch.object(watch.time, 'time', return_value=T0):
            watch.main()

        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))


if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
