#!/usr/bin/env bash
# No orca: partial terminal send must not repeat notices on terminals that already got them.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

def failed(name):
    return {'dispatchId': name, 'dispatchStatus': 'failed'}

CONFIG = {'runs': [
    {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
    {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'},
]}

def fake_rpc(sends, broken=None):
    def rpc(*args):
        term = args[args.index('--terminal') + 1]
        if term in (broken or {}):
            raise broken[term]
        sends.append((term, args[args.index('--text') + 1]))
    return rpc

class Resend(unittest.TestCase):
    def run_pass(self, state, workers, fail_terminals):
        sends = []
        def rpc(*args):
            if args[1] == 'inbox':
                return {'messages': []}
            if args[1] == 'worker-list':
                return {'workers': workers, 'page': {'hasMore': False}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': []}
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

    def test_all_sends_work(self):
        state = {}
        sends = []
        watch.deliver_notices(CONFIG, state, ['n1'], fake_rpc(sends))
        self.assertEqual(sends, [('term_first', 'n1'), ('term_second', 'n1')])
        self.assertEqual(state['notice_delivery'], {})

    def test_each_error_type_skips_only_that_terminal(self):
        errors = (subprocess.CalledProcessError(1, 'orca', stderr='gone'), subprocess.TimeoutExpired('orca', 15),
                  RuntimeError('refused'), OSError('pipe'), ValueError('json'), KeyError('result'))
        for error in errors:
            with self.subTest(error=type(error).__name__):
                state = {}
                sends = []
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    watch.deliver_notices(CONFIG, state, ['n1'], fake_rpc(sends, {'term_first': error}))
                self.assertEqual(sends, [('term_second', 'n1')])
                self.assertEqual(state['notice_delivery']['n1'], {'sent': ['term_second'], 'passes': 1})
                self.assertIn('term_first', err.getvalue())

    def test_success_after_failure_sends_only_to_missed_terminal(self):
        state = {}
        sends = []
        with contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices(CONFIG, state, ['n1'], fake_rpc(sends, {'term_first': OSError('x')}))
        watch.deliver_notices(CONFIG, state, [], fake_rpc(sends))
        self.assertEqual(sends, [('term_second', 'n1'), ('term_first', 'n1')])
        self.assertEqual(state['notice_delivery'], {})

    def test_closed_terminal_dropped_at_pass_twenty(self):
        state = {}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            for i in range(20):
                watch.deliver_notices(CONFIG, state, ['n1'] if i == 0 else [], fake_rpc([], {'term_first': OSError('x')}))
        self.assertEqual(state['notice_delivery'], {})
        gave_up = [l for l in err.getvalue().splitlines() if 'giving up' in l]
        self.assertEqual(len(gave_up), 1)
        self.assertIn('n1', gave_up[0])
        self.assertIn('term_first', gave_up[0])

    def pending_growth(self, broken, passes=100):
        state = {}
        most = 0
        with contextlib.redirect_stderr(io.StringIO()):
            for i in range(passes):
                watch.deliver_notices(CONFIG, state, ['n%d' % i], fake_rpc([], broken))
                most = max(most, len(state['notice_delivery']))
        return most

    def test_pending_growth_is_capped_with_one_closed_terminal(self):
        self.assertLessEqual(self.pending_growth({'term_first': OSError('x')}), 20)

    def test_pending_growth_is_capped_with_all_terminals_closed(self):
        self.assertLessEqual(self.pending_growth({'term_first': OSError('x'), 'term_second': OSError('x')}), 20)

    def test_blips_never_mute_a_terminal(self):
        state = {}
        sends = []
        with contextlib.redirect_stderr(io.StringIO()):
            for i in range(50):
                broken = {'term_first': OSError('x')} if i % 2 == 0 else {}
                watch.deliver_notices(CONFIG, state, ['n%d' % i], fake_rpc(sends, broken))
        self.assertTrue(all(('term_first', 'n%d' % i) in sends for i in range(1, 50, 2)))

    def test_recovery_after_long_outage(self):
        state = {}
        sends = []
        with contextlib.redirect_stderr(io.StringIO()):
            for i in range(30):
                watch.deliver_notices(CONFIG, state, ['old%d' % i], fake_rpc([], {'term_first': OSError('x')}))
        watch.deliver_notices(CONFIG, state, ['fresh'], fake_rpc(sends))
        self.assertIn(('term_first', 'fresh'), sends)
        self.assertFalse([line for _, line in sends if line.startswith('old') and int(line[3:]) < 10])

    def test_hung_terminal_tried_once_per_pass(self):
        state = {}
        sends = []
        calls = []
        base = fake_rpc(sends, {'term_first': subprocess.TimeoutExpired('orca', 15)})
        def counting(*args):
            calls.append(args[args.index('--terminal') + 1])
            return base(*args)
        with contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices(CONFIG, state, ['p%d' % i for i in range(5)], counting)
        self.assertEqual(calls.count('term_first'), 1)
        self.assertEqual(calls.count('term_second'), 5)

    def test_state_without_notice_delivery_still_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            state.write_text(json.dumps({'failed': ['x'], 'pr_watch': {'owner/repo': {'merged': []}}}))
            self.assertEqual(self.run_pass(state, [failed('x')], set()), [])

    def test_saved_state_round_trip_continues_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'state.json'
            state = {}
            sends = []
            with contextlib.redirect_stderr(io.StringIO()):
                watch.deliver_notices(CONFIG, state, ['n1'], fake_rpc(sends, {'term_second': OSError('x')}))
            watch.save_state(path, state)
            state = json.loads(path.read_text())
            self.assertEqual(state['notice_delivery']['n1'], {'sent': ['term_first'], 'passes': 1})
            watch.deliver_notices(CONFIG, state, [], fake_rpc(sends))
            self.assertEqual(sends, [('term_first', 'n1'), ('term_second', 'n1')])
            self.assertEqual(state['notice_delivery'], {})

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
