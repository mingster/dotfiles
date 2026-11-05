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

    def test_timeout_does_not_skip_other_terminals(self):
        config = {'runs': [
            {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
            {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'},
        ]}
        state = {}
        sends = []
        def rpc(*args):
            if args[:2] == ('terminal', 'send'):
                term = args[args.index('--terminal') + 1]
                if term == 'term_first':
                    raise subprocess.TimeoutExpired(cmd='orca', timeout=15)
                sends.append(term)
            return {}
        with patch.object(watch, 'rpc', side_effect=rpc):
            watch.deliver_notice_line(config, state, 'notice line', rpc)
        self.assertEqual(sends, ['term_second'])
        self.assertIn('notice line', state.get('notice_delivery', {}))

    def test_oserror_valueerror_count_as_failed_send(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_a', 'waiter_pattern': 'w1'}]}
        for exc in (OSError('broken pipe'), ValueError('bad json')):
            with self.subTest(exc=type(exc).__name__):
                state = {}
                def rpc(*args):
                    raise exc
                with patch.object(watch, 'rpc', side_effect=rpc):
                    watch.deliver_notice_line(config, state, 'line', rpc)
                self.assertIn('line', state.get('notice_delivery', {}))

    def test_abandon_terminal_after_twenty_failed_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            pending_line = 'fleet-watch: pending notice'
            state.write_text(json.dumps({
                'failed': ['a'],
                'notice_delivery': {pending_line: {'term_first': True}},
            }))
            workers = [failed('a')]
            fail = {'term_second'}
            for _ in range(20):
                self.run_pass(state, workers, fail)
            loaded = json.loads(state.read_text())
            self.assertIn('term_second', loaded.get('notice_send_abandoned', []))
            sends = self.run_pass(state, workers, fail)
            self.assertEqual(sends, [])
            workers = workers + [failed('c')]
            self.run_pass(state, workers, fail)
            loaded = json.loads(state.read_text())
            delivery = loaded.get('notice_delivery', {})
            self.assertNotIn(pending_line, delivery)
            self.assertLessEqual(len(delivery), 1)

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
