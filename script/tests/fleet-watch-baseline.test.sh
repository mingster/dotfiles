#!/usr/bin/env bash
# No orca: the CLI wrapper is patched. First pass baselines failures, later passes report only new ones.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
def failed(name): return {'dispatchId': name, 'dispatchStatus': 'failed'}
class Baseline(unittest.TestCase):
    def pass_with(self, state, workers):
        calls = []
        def rpc(*args):
            calls.append(args)
            if args[1] == 'inbox': return {'messages': []}
            if args[1] == 'worker-list': return {'workers': workers, 'page': {'hasMore': False}}
            return {}
        config = state.parent/'config.json'
        config.write_text(json.dumps({'runs': [{'id': 'r', 'terminal': 't', 'waiter_pattern': 'w'}]}))
        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), patch.object(watch, 'rpc', side_effect=rpc), \
             patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            watch.main()
        return [c for c in calls if c[:2] == ('terminal', 'send')]
    def test_old_failures_are_silent_and_one_new_failure_alerts_once(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            old = [failed('a'), failed('b')]
            self.assertEqual(self.pass_with(state, old), [])
            self.assertEqual(self.pass_with(state, old), [])
            sends = self.pass_with(state, old + [failed('c')])
            self.assertEqual(len(sends), 1)
            self.assertIn('failed dispatch c', ' '.join(sends[0]))
            self.assertEqual(self.pass_with(state, old + [failed('c')]), [])
    def test_four_occupied_slots_reject_fifth_including_completed_pending_push_author(self):
        config = {'host_caps': {'fleet-1': 4}}
        workers = [
            {'dispatchId': 'b1', 'dispatchStatus': 'running', 'projection': {'role': 'builder', 'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'q1', 'dispatchStatus': 'running', 'projection': {'role': 'qa', 'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'c1', 'dispatchStatus': 'running', 'parentDispatchId': 'b1', 'projection': {'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'a1', 'dispatchStatus': 'completed', 'projection': {'role': 'author', 'host': {'id': 'fleet-1'}}, 'pushed': False, 'released': False},
        ]
        receipt = watch.admit('fleet-1', config, workers)
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 4)
        self.assertEqual(receipt['live_count'], 3)
        self.assertEqual(receipt['retained_count'], 1)
        retained = [r for r in receipt['resources'] if r.get('category') == 'retained']
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0]['dispatchId'], 'a1')
        self.assertEqual(retained[0]['evidence']['pushed'], False)
        self.assertEqual(retained[0]['evidence']['released'], False)

    def test_releasing_author_with_confirmed_push_admits_one(self):
        config = {'host_caps': {'fleet-1': 4}}
        workers = [
            {'dispatchId': 'b1', 'dispatchStatus': 'running', 'projection': {'role': 'builder', 'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'q1', 'dispatchStatus': 'running', 'projection': {'role': 'qa', 'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'c1', 'dispatchStatus': 'running', 'parentDispatchId': 'b1', 'projection': {'host': {'id': 'fleet-1'}}},
            {'dispatchId': 'a1', 'dispatchStatus': 'released', 'projection': {'role': 'author', 'host': {'id': 'fleet-1'}}, 'pushed': True, 'released': True},
        ]
        receipt = watch.admit('fleet-1', config, workers)
        self.assertTrue(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 3)
        self.assertEqual(receipt['live_count'], 3)
        self.assertEqual(receipt['retained_count'], 0)

    def test_confirmed_push_plus_release_frees_slot_exactly_once(self):
        config = {'host_caps': {'fleet-1': 1}}
        # Pushed but not released occupies slot
        w_push_only = [{'dispatchId': 'a1', 'dispatchStatus': 'completed', 'projection': {'host': {'id': 'fleet-1'}}, 'pushed': True, 'released': False}]
        r1 = watch.admit('fleet-1', config, w_push_only)
        self.assertFalse(r1['admitted'])
        self.assertEqual(r1['occupied'], 1)

        # Released but not pushed occupies slot
        w_release_only = [{'dispatchId': 'a1', 'dispatchStatus': 'released', 'projection': {'host': {'id': 'fleet-1'}}, 'pushed': False, 'released': True}]
        r2 = watch.admit('fleet-1', config, w_release_only)
        self.assertFalse(r2['admitted'])
        self.assertEqual(r2['occupied'], 1)

        # Both confirmed frees slot
        w_freed = [{'dispatchId': 'a1', 'dispatchStatus': 'released', 'projection': {'host': {'id': 'fleet-1'}}, 'pushed': True, 'released': True}]
        r3 = watch.admit('fleet-1', config, w_freed)
        self.assertTrue(r3['admitted'])
        self.assertEqual(r3['occupied'], 0)

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
