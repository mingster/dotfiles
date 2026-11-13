#!/usr/bin/env bash
# No orca: a recorded own worker stalls, is restarted once, then parked. Others are not stopped.
set -euo pipefail
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
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

_spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', root / 'tests' / 'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_spec_env)
_spec_env.loader.exec_module(_fwe)
isolated_main_env = _fwe.isolated_main_env

T0 = 1_700_000_000  # unix seconds so lastOutputAt ms exceeds 1e12


def live_worker():
    # Shape from `orca orchestration worker-list --run <run> --full --json` (Nov 2026);
    # PR 629 and branch match this worktree (`gh pr list --head mingster/fsd-watchdog-fold`).
    return {
        'dispatchId': 'disp1',
        'taskId': 'task_stall_fixture',
        'runId': 'r1',
        'terminalState': 'retained',
        'dispatchStatus': 'dispatched',
        'agentTerminalHandle': 'term_w',
        'githubPullRequestNumber': 629,
        'headRefName': 'mingster/fsd-watchdog-fold',
        'agent': 'claude',
        'resource': {
            'worktreeId': '5c45d9ec-0d77-4c92-859f-bda6af348340::/srv/orca/workspaces/example/fsd-watchdog-fold',
        },
        'projection': {
            'host': {'kind': 'local', 'id': 'local'},
            'provider': {'id': 'claude', 'model': None},
            'outcome': 'in_progress',
            'liveness': {'verdict': 'idle'},
        },
    }


class Stall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = pathlib.Path(self.tmp.name)
        self.log_path = self.home / 'fleet-watch-test.log'

    def test_own_stall_restarts_once_then_parks(self):
        calls = []
        gh_calls = []
        # last output 3000s before pass at T0+4000 -> idle 3000s > 30 min (STALL_IDLE_LIMIT)
        term_ms = int((T0 + 1000) * 1000)
        clock = {'now': T0 + 4000}

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
        state.write_text(json.dumps({'own_dispatches': {'disp1': {'kind': 'verifier'}}}))

        with isolated_main_env(str(self.home)), \
                patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                patch.object(watch, 'rpc', side_effect=rpc), \
                patch.object(watch, 'run_gh', side_effect=fake_gh), \
                patch.object(watch, 'pr_notices', return_value=[]), \
                patch.object(watch, 'usage_notices', return_value=[]), \
                patch.object(watch, 'deliver_notices', return_value=None), \
                patch.object(watch.time, 'time', side_effect=lambda: clock['now']):
            watch.main()
            watch.main()
            clock['now'] = T0 + 4000 + 31 * 60
            watch.main()

        stops = [c for c in calls if c[:4] == ('orchestration', 'worker-stop', '--dispatch', 'disp1')]
        starts = [
            c for c in calls
            if len(c) >= 2 and c[0] == 'bash' and str(c[1]).endswith('worker-startup.sh')
        ]
        self.assertEqual(len(stops), 1)
        self.assertEqual(len(starts), 1)
        self.assertIn('--task', starts[0])
        self.assertIn('task_stall_fixture', starts[0])
        self.assertIn('--run', starts[0])
        self.assertIn('r1', starts[0])
        self.assertIn('--retry-of', starts[0])
        self.assertIn('--worktree', starts[0])
        self.assertIn('5c45d9ec-0d77-4c92-859f-bda6af348340::/srv/orca/workspaces/example/fsd-watchdog-fold', starts[0])
        self.assertIn('--agent', starts[0])
        self.assertIn('claude', starts[0])
        self.assertNotIn('--terminal', starts[0])
        self.assertIn('--from', starts[0])
        self.assertIn('tcoord', starts[0])
        self.assertNotIn('worker-start', starts[0])
        edits = [c for c in gh_calls if len(c) >= 3 and c[:3] == ['gh', 'pr', 'edit']]
        self.assertFalse(any('needs-elon' in c for c in edits))
        log = self.log_path.read_text()
        self.assertIn('stall_restart=disp1', log)
        self.assertIn('stall_parked=disp1', log)
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

        with isolated_main_env(str(self.home)), \
                patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
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
