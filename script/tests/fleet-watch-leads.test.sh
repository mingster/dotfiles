#!/usr/bin/env bash
# No orca: the CLI wrapper is patched. A configured lead whose terminal is gone alerts once, then again only after it returns and dies.
set -euo pipefail
PYTHON=python3
if [[ -x /usr/bin/python3 ]]; then PYTHON=/usr/bin/python3; fi
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
_spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', root/'tests'/'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_spec_env); _spec_env.loader.exec_module(_fwe)
redirect_main_log_under = _fwe.redirect_main_log_under


class Leads(unittest.TestCase):
    def pass_with(self, state, gone):
        calls = []

        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': [], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': []}
            if args[:2] == ('terminal', 'show'):
                term = args[args.index('--terminal') + 1]
                if term in gone:
                    # Real Orca maps gone leads to a specific error; before TerminalNotFound existed,
                    # terminal show failure aborted inventory as a generic refusal (90d9aaf).
                    tnf = getattr(watch, 'TerminalNotFound', None)
                    if tnf is not None:
                        raise tnf('terminal_not_found')
                    raise watch.OrcaReadError('Orca refused inventory')
                return {}
            return {}

        config = state.parent/'config.json'
        config.write_text(json.dumps({'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
                                      'leads': [{'name': 'lead 2', 'terminal': 'term_lead2'}]}))
        with redirect_main_log_under(str(state.parent.resolve())), \
             patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
             patch.object(watch, 'rpc', side_effect=rpc), \
             patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            watch.main()
        return [' '.join(c) for c in calls if c[:2] == ('terminal', 'send')]

    def test_dead_lead_alerts_once_and_rearms_after_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            self.assertEqual(self.pass_with(state, set()), [])
            sends = self.pass_with(state, {'term_lead2'})
            self.assertEqual(len(sends), 1)
            self.assertIn('lead pane gone: lead 2', sends[0])
            self.assertEqual(self.pass_with(state, {'term_lead2'}), [])
            self.assertEqual(self.pass_with(state, set()), [])
            self.assertEqual(len(self.pass_with(state, {'term_lead2'})), 1)

    def test_terminal_show_other_failure_fails_inventory_without_lead_alert(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            state = home / 'state.json'

            def rpc(*args):
                if args[1] == 'inbox':
                    return {'messages': []}
                if args[1] == 'worker-list':
                    return {'workers': [], 'page': {'hasMore': False}}
                if args[:2] == ('terminal', 'list'):
                    return {'terminals': []}
                if args[:2] == ('terminal', 'show'):
                    raise subprocess.CalledProcessError(1, 'orca', stderr='terminal unreachable')
                return {}

            config = home / 'config.json'
            config.write_text(json.dumps({'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
                                          'leads': [{'name': 'lead 2', 'terminal': 'term_lead2'}]}))
            buf = io.StringIO()
            with redirect_main_log_under(str(home)), \
                 patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                 patch.object(watch, 'rpc', side_effect=rpc), \
                 patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                 contextlib.redirect_stdout(buf):
                watch.main()
            out = buf.getvalue()
            self.assertIn(watch.ORCA_SKIP_NOTICE, out)
            self.assertNotIn('lead pane gone', out)

    def test_rpc_maps_terminal_show_stdout_matches_real_orca_stale_handle(self):
        # Captured: `orca terminal show --terminal does-not-exist --json` → exit 1, stderr empty, stdout JSON.
        stale_stdout = r'''{
  "id": "a5839119-0279-4b82-9113-600d4cfa5daa",
  "ok": false,
  "error": {
    "code": "terminal_handle_stale",
    "message": "terminal_handle_stale",
    "data": {
      "nextSteps": [
        "Terminal handles belong to the Orca server that issued them. If this handle came from a paired server (for example `orca terminal list --environment <server>`), pass the same --environment <server> to this command."
      ]
    }
  },
  "_meta": {
    "runtimeId": "acc8d77d-9e56-4e28-b277-3f4dbabb0ceb"
  }
}
'''
        proc = subprocess.CompletedProcess(
            ['orca', 'terminal', 'show', '--json'], 1,
            stdout=stale_stdout,
            stderr='',
        )
        with patch.object(watch.subprocess, 'run', return_value=proc):
            with self.assertRaises(watch.TerminalNotFound):
                watch.rpc('terminal', 'show', '--terminal', 'does-not-exist')

    def test_rpc_maps_terminal_show_json_body_terminal_not_found(self):
        proc = subprocess.CompletedProcess(
            ['orca', 'terminal', 'show', '--json'], 0,
            stdout='{"ok":false,"error":{"code":"terminal_not_found","message":"x"}}',
            stderr='',
        )
        with patch.object(watch.subprocess, 'run', return_value=proc):
            with self.assertRaises(watch.TerminalNotFound):
                watch.rpc('terminal', 'show', '--terminal', 'term_x')

    def test_paged_remote_inventory_and_retries_deduplicate_by_dispatch_and_resource_identity(self):
        config = {'host_caps': {'fleet-1': 2}}
        # Duplicated observation across pages and retry sharing worktree resource identity
        workers = [
            {'dispatchId': 'd1', 'dispatchStatus': 'running', 'resource': {'worktreeId': 'wt1'}, 'projection': {'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'd1', 'dispatchStatus': 'running', 'resource': {'worktreeId': 'wt1'}, 'projection': {'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'd2_retry', 'retryOf': 'd2_failed', 'taskId': 't2', 'dispatchStatus': 'running', 'resource': {'worktreeId': 'wt2'}, 'projection': {'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'd2_failed', 'taskId': 't2', 'dispatchStatus': 'failed', 'resource': {'worktreeId': 'wt2'}, 'projection': {'host': {'id': 'fleet-1'}}},
        ]
        receipt = watch.admit('fleet-1', config, workers)
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 2)

    def test_missing_or_failed_remote_inventory_never_authorizes_start(self):
        config = {'host_caps': {'fleet-1': 4}, 'runs': [{'id': 'r1', 'terminal': 't1', 'waiter_pattern': 'w'}]}

        def failing_rpc(*args):
            raise RuntimeError('Orca refused inventory')

        with patch.object(watch, 'rpc', side_effect=failing_rpc):
            receipt = watch.admit('fleet-1', config)
            self.assertFalse(receipt['admitted'])
            self.assertIn('failed', receipt['reason'].lower())

    def test_release_unknown_never_authorizes_start(self):
        config = {'host_caps': {'fleet-1': 4}}
        workers = [
            {'dispatchId': 'b1', 'dispatchStatus': 'release_unknown', 'projection': {'host': {'id': 'fleet-1'}}},
        ]
        receipt = watch.admit('fleet-1', config, workers)
        self.assertFalse(receipt['admitted'])
        self.assertIn('release_unknown', receipt['reason'])

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
