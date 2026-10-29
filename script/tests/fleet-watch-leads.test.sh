#!/usr/bin/env bash
# No orca: the CLI wrapper is patched. A configured lead whose terminal is gone alerts once, then again only after it returns and dies.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
class Leads(unittest.TestCase):
    def pass_with(self, state, gone):
        calls = []
        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox': return {'messages': []}
            if args[1] == 'worker-list': return {'workers': [], 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'show') and args[3] in gone:
                raise subprocess.CalledProcessError(1, 'orca', 'terminal_not_found')
            return {}
        config = state.parent/'config.json'
        config.write_text(json.dumps({'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}],
                                      'leads': [{'name': 'lead 2', 'terminal': 'term_lead2'}]}))
        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), patch.object(watch, 'rpc', side_effect=rpc), \
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
