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
if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
