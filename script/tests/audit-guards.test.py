#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

watch = load('fleet-watch')
idle = load('worktree-idle')
scoped = load('run-scoped-tests')

class Guards(unittest.TestCase):
    def setUp(self):
        self.config = {'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'waiter-r'}], 'host_caps': {'local': 1}}
        self.messages = [{'run_id': 'r', 'read': 0}]

    def test_waiter_missing_for_ten_minutes_wakes_once_and_rearms(self):
        state = {}
        self.assertEqual(watch.alerts(self.config, state, 0, self.messages, [], {'r': False}), [])
        self.assertEqual(watch.alerts(self.config, state, 599, self.messages, [], {'r': False}), [])
        self.assertIn('unacked', watch.alerts(self.config, state, 600, self.messages, [], {'r': False})[0])
        self.assertEqual(watch.alerts(self.config, state, 1200, self.messages, [], {'r': False}), [])
        watch.alerts(self.config, state, 1300, self.messages, [], {'r': True})
        self.assertNotIn('r', state)

    def test_acknowledged_inbox_never_wakes(self):
        state = {}
        watch.alerts(self.config, state, 0, [], [], {'r': False})
        self.assertEqual(watch.alerts(self.config, state, 9999, [], [], {'r': False}), [])

    def test_failed_capacity_dispatch_reported_once_and_children_count(self):
        state = {'failed': []}
        workers = [{'dispatchId': 'f', 'dispatchStatus': 'failed'}, {'dispatchId': 'p', 'dispatchStatus': 'dispatched'}, {'dispatchId': 'c', 'dispatchStatus': 'dispatched', 'parentDispatchId': 'p'}]
        notices = watch.alerts(self.config, state, 0, [], workers, {'r': True})
        self.assertEqual(len(notices), 2)
        self.assertIn('2/1', notices[1])
        self.assertEqual(len(watch.alerts(self.config, state, 1, [], workers, {'r': True})), 1)

    def test_failed_dispatch_without_retry_alerts(self):
        state = {'failed': []}
        workers = [{'dispatchId': 'f', 'dispatchStatus': 'failed', 'taskId': 't1'}]
        self.assertEqual(len(watch.alerts(self.config, state, 0, [], workers, {'r': True})), 1)
        self.assertEqual(state['failed'], ['f'])

    def test_failed_dispatch_with_live_retry_is_silent_and_not_recorded(self):
        state = {}
        workers = [{'dispatchId': 'f', 'dispatchStatus': 'failed', 'taskId': 't1'}, {'dispatchId': 'g', 'dispatchStatus': 'completed', 'taskId': 't1'}]
        self.assertEqual(watch.alerts(self.config, state, 0, [], workers, {'r': True}), [])
        self.assertEqual(state.get('failed', []), [])

    def test_task_with_every_dispatch_failed_alerts_each_once(self):
        state = {'failed': []}
        workers = [{'dispatchId': 'f', 'dispatchStatus': 'failed', 'taskId': 't1'}, {'dispatchId': 'g', 'dispatchStatus': 'failed', 'taskId': 't1'}]
        self.assertEqual(len(watch.alerts(self.config, state, 0, [], workers, {'r': True})), 2)
        self.assertEqual(watch.alerts(self.config, state, 1, [], workers, {'r': True}), [])

    def test_watchdog_pass_delivers_one_wake_and_persists_only_after_delivery(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            state = Path(directory) / 'state.json'
            config.write_text(json.dumps(self.config))
            state.write_text(json.dumps({'r': {'since': 0, 'alerted': False}}))
            calls = []
            def rpc(*args):
                calls.append(args)
                if args[1] == 'inbox': return {'messages': self.messages}
                if args[1] == 'worker-list': return {'workers': [], 'page': {'hasMore': False}}
                return {}
            with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), patch.object(watch, 'rpc', side_effect=rpc), patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), patch.object(watch.time, 'time', return_value=601):
                self.assertEqual(watch.main(), 0)
                self.assertEqual(watch.main(), 0)
            sends = [call for call in calls if call[:2] == ('terminal', 'send')]
            self.assertEqual(len(sends), 1)
            self.assertIn('t', sends[0])
            self.assertTrue(json.loads(state.read_text())['r']['alerted'])

    def test_live_terminal_inside_detached_worktree_is_retained(self):
        self.assertFalse(idle.idle('/work/a', {'result': {'terminals': [{'cwd': '/work/a/web'}]}}))

    def test_inventory_unknown_or_truncated_is_retained(self):
        for receipt in [{}, {'ok': False}, {'result': {'terminals': [], 'truncated': True}}, {'result': {'terminals': [{}]}}]:
            self.assertFalse(idle.idle('/work/a', receipt))
        self.assertTrue(idle.idle('/work/a', {'result': {'terminals': [{'cwd': '/work/ab'}]}}))

    def test_cli_unknown_inventory_refuses_removal(self):
        result = subprocess.run(['python3', str(ROOT / 'worktree-idle.py'), '/work/a'], env=dict(os.environ, ORCA_CLI_COMMAND='/nonexistent-command'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('retaining', result.stderr)

    def test_browser_suite_is_reported_unchecked_on_missing_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            browser = root / 'layout.test.ts'
            browser.write_text('import {chromium} from "playwright";')
            pure = root / 'pure.test.ts'
            pure.write_text('expect(1).toBe(1);')
            self.assertTrue(scoped.browser_test(browser))
            self.assertFalse(scoped.browser_test(pure))
            from unittest.mock import patch
            import contextlib, io
            output = io.StringIO()
            with patch.object(scoped, 'select_changed_tests', return_value=[browser]), patch.object(scoped, 'browser_available', return_value=False), patch.object(scoped, 'ensure_dependencies') as dependencies, contextlib.redirect_stdout(output):
                self.assertEqual(scoped.run_scoped_tests(root, 'bun test', [str(browser)]), 0)
            self.assertIn('UNCHECKED: layout.test.ts', output.getvalue())
            dependencies.assert_not_called()

if __name__ == '__main__':
    unittest.main()
