#!/usr/bin/env bash
# No orca: partial terminal send must not repeat notices on terminals that already got them.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import importlib.util, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

def failed(name):
    return {'dispatchId': name, 'dispatchStatus': 'failed'}

class Resend(unittest.TestCase):
    def run_pass(self, state, workers, fail_terminals):
        sends = []
        def rpc(*args):
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': workers, 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'send'):
                term = args[args.index('--terminal') + 1]
                if term in fail_terminals:
                    raise subprocess.CalledProcessError(1, 'orca', stderr='terminal unreachable')
                sends.append(term)
            return {}
        config = state.parent/'config.json'
        config.write_text(json.dumps({'runs': [
            {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
            {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'},
        ]}))
        with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
             patch.object(watch, 'rpc', side_effect=rpc), \
             patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            watch.main()
        return sends

    def test_second_terminal_failure_does_not_repeat_first(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            baseline = [failed('a')]
            self.assertEqual(self.run_pass(state, baseline, set()), [])
            self.assertEqual(self.run_pass(state, baseline, set()), [])
            workers = baseline + [failed('b')]
            first_pass = self.run_pass(state, workers, {'term_second'})
            self.assertEqual(first_pass, ['term_first'])
            second_pass = self.run_pass(state, workers, set())
            self.assertEqual(second_pass, ['term_second'])
            self.assertEqual(self.run_pass(state, workers, set()), [])

    def test_state_without_notice_delivery_still_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            state.write_text(json.dumps({'failed': ['x'], 'pr_watch': {'owner/repo': {'merged': []}}}))
            sends = self.run_pass(state, [failed('x')], set())
            self.assertEqual(sends, [])

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
