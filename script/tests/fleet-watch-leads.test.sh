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
if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
