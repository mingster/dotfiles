#!/usr/bin/env bash
# No orca: the CLI wrapper is patched. First pass baselines failures, later passes report only new ones.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, os, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
def failed(name): return {'dispatchId': name, 'dispatchStatus': 'failed'}
import atexit, shutil
_fleet_dir = tempfile.mkdtemp()
atexit.register(shutil.rmtree, _fleet_dir, True)
def fleet(caps, **extra):
    """A fleet-watch config whose fleet-config.json holds these host caps."""
    path = pathlib.Path(tempfile.mkstemp(dir=_fleet_dir, suffix='.json')[1])
    path.write_text(json.dumps({'host_caps': caps}))
    return dict({'fleet_config': str(path)}, **extra)

REAL_DEFAULT = watch.FLEET_CONFIG_DEFAULT
watch.FLEET_CONFIG_DEFAULT = fleet({})['fleet_config']
watch.DRAIN_LOG_DEFAULT = os.path.join(_fleet_dir, 'drain.log')
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
        return [c for c in calls if c[:2] == ('orchestration', 'send')]
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
        config = fleet({'fleet-1': 4})
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
        config = fleet({'fleet-1': 4})
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
        config = fleet({'fleet-1': 1})
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


def run_on(host, status='running', n=1):
    return [{'dispatchId': 'w%d' % i, 'dispatchStatus': status, 'resource': {'worktreeId': 'wt%d' % i},
             'projection': {'host': {'id': host}}} for i in range(n)]

class FleetConfig(unittest.TestCase):
    def test_over_cap_alert_fires_from_the_file(self):
        config = fleet({'h': 1}, runs=[])
        notices = watch.alerts(config, {}, 0, [], run_on('h', n=2), {})
        self.assertEqual(notices, ['host cap exceeded: h 2/1 (includes child dispatches)'])

    def test_host_caps_in_the_watch_config_are_ignored(self):
        config = dict(fleet({'h': 5}, runs=[]), host_caps={'h': 1})
        self.assertEqual(watch.alerts(config, {}, 0, [], run_on('h', n=2), {}), [])
        self.assertTrue(watch.admit('h', config, run_on('h', n=2))['admitted'])

    def test_admit_uses_the_cap_in_the_file(self):
        self.assertFalse(watch.admit('h', fleet({'h': 2}), run_on('h', n=2))['admitted'])
        self.assertTrue(watch.admit('h', fleet({'h': 3}), run_on('h', n=2))['admitted'])

    def test_unlisted_host_keeps_the_default_of_four(self):
        self.assertTrue(watch.admit('other', fleet({'h': 1}), run_on('other', n=3))['admitted'])
        self.assertFalse(watch.admit('other', fleet({'h': 1}), run_on('other', n=4))['admitted'])

    def test_missing_or_unreadable_file_refuses_admission(self):
        for content in (None, 'not json', '[]', '{"host_caps": 3}'):
            with self.subTest(content=content):
                path = pathlib.Path(tempfile.mkdtemp())/'fleet-config.json'
                if content is not None:
                    path.write_text(content)
                receipt = watch.admit('h', {'fleet_config': str(path)}, run_on('h'))
                self.assertFalse(receipt['admitted'])
                self.assertFalse(receipt['ok'])
                self.assertIn('fleet config', receipt['reason'])

    def test_missing_file_notice_goes_out_once_and_rearms(self):
        path = pathlib.Path(tempfile.mkdtemp())/'fleet-config.json'
        config, state = {'runs': [], 'fleet_config': str(path)}, {}
        first = watch.alerts(config, state, 0, [], [], {})
        self.assertEqual(len(first), 1)
        self.assertIn('fleet config', first[0])
        self.assertEqual(watch.alerts(config, state, 60, [], [], {}), [])
        path.write_text('{"host_caps": {}}')
        self.assertEqual(watch.alerts(config, state, 120, [], [], {}), [])
        path.unlink()
        self.assertEqual(len(watch.alerts(config, state, 180, [], [], {})), 1)

    def test_default_path_is_under_the_claude_state_directory(self):
        self.assertEqual(REAL_DEFAULT, os.path.expanduser('~/.claude/state/fleet-config.json'))

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
