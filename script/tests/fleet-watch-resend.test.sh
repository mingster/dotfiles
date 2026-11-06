#!/usr/bin/env bash
# No orca: partial terminal send must not repeat notices on terminals that already got them.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

import tempfile as _tf
_default = pathlib.Path(_tf.mkdtemp())/'fleet-config.json'
_default.write_text('{"host_caps": {}}')
watch.FLEET_CONFIG_DEFAULT = str(_default)
watch.DRAIN_LOG_DEFAULT = str(_default.parent/'drain.log')

def failed(name):
    return {'dispatchId': name, 'dispatchStatus': 'failed'}

CONFIG = {'runs': [
    {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1', 'typed': True},
    {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2', 'typed': True},
]}
UNTYPED = {'runs': [
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
            if args[:2] == ('terminal', 'send'):
                term = args[args.index('--terminal') + 1]
                if term in fail_terminals:
                    raise subprocess.CalledProcessError(1, 'orca', stderr='terminal unreachable')
                sends.append(term)
            return {}
        config = state.parent/'config.json'
        config.write_text(json.dumps(CONFIG))
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


def digest_rpc(calls, broken=None):
    def rpc(*args):
        calls.append(args)
        term = args[args.index('--to') + 1] if '--to' in args else args[args.index('--terminal') + 1]
        if term in (broken or {}):
            raise broken[term]
        return {}
    return rpc

def sent(calls):
    """(terminal, body) for each orchestration send."""
    return [(c[c.index('--to') + 1], c[c.index('--body') + 1]) for c in calls if c[:2] == ('orchestration', 'send')]

NO_OWNER = lambda author: None

def run_on(host, n=1):
    return [{'dispatchId': 'w%d' % i, 'dispatchStatus': 'running', 'resource': {'worktreeId': 'wt%d' % i},
             'projection': {'host': {'id': host}}} for i in range(n)]

class Digest(unittest.TestCase):
    def test_run_terminal_is_never_typed_into_by_default(self):
        calls = []
        watch.deliver_notices(UNTYPED, {}, ['n1'], digest_rpc(calls), now=0, owner_of=NO_OWNER)
        self.assertEqual([c for c in calls if c[:2] == ('terminal', 'send')], [])
        self.assertEqual(sent(calls), [('term_first', 'n1'), ('term_second', 'n1')])

    def test_typed_true_types_into_that_run_only(self):
        config = {'runs': [dict(UNTYPED['runs'][0], typed=True), UNTYPED['runs'][1]]}
        calls = []
        watch.deliver_notices(config, {}, ['n1'], digest_rpc(calls), now=0, owner_of=NO_OWNER)
        typed = [c[c.index('--terminal') + 1] for c in calls if c[:2] == ('terminal', 'send')]
        self.assertEqual(typed, ['term_first'])
        self.assertEqual(sent(calls), [('term_second', 'n1')])

    def test_digest_goes_out_at_most_every_600_seconds_oldest_first(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        for now, line in ((60, 'n2'), (300, 'n3'), (599, None)):
            watch.deliver_notices(UNTYPED, state, [line] if line else [], rpc, now=now, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 2)
        watch.deliver_notices(UNTYPED, state, [], rpc, now=600, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2:], [('term_first', 'n2\nn3'), ('term_second', 'n2\nn3')])
        watch.deliver_notices(UNTYPED, state, [], rpc, now=1300, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 4)

    def test_duplicates_are_merged(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['a'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['b', 'c', 'b'], rpc, now=10, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['c'], rpc, now=20, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, [], rpc, now=700, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2], ('term_first', 'b\nc'))

    def test_urgent_notice_skips_the_wait_and_carries_the_queue(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['n2'], rpc, now=5, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, [watch.Urgent('lead pane gone: x')], rpc, now=10, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2:], [('term_first', 'n2\nlead pane gone: x'), ('term_second', 'n2\nlead pane gone: x')])

    def test_plain_text_that_looks_urgent_still_waits(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['lead pane gone: x', 'host cap exceeded: h 5/4'], rpc, now=10, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 2)

    def test_alerts_mark_dead_lead_and_over_cap_urgent(self):
        import tempfile
        fleet = pathlib.Path(tempfile.mkdtemp())/'fleet-config.json'
        fleet.write_text(json.dumps({'host_caps': {'h': 1}}))
        config = {'runs': [], 'fleet_config': str(fleet), 'leads': [{'name': 'L', 'terminal': 'tl'}]}
        workers = [{'dispatchId': 'a', 'dispatchStatus': 'running', 'projection': {'host': {'id': 'h'}}, 'resource': {'worktreeId': 'w1'}},
                   {'dispatchId': 'b', 'dispatchStatus': 'running', 'projection': {'host': {'id': 'h'}}, 'resource': {'worktreeId': 'w2'}}]
        notices = watch.alerts(config, {}, 0, [], workers, {}, {'tl': False})
        self.assertEqual(len(notices), 2)
        self.assertTrue(all(isinstance(n, watch.Urgent) for n in notices))
        failed_notice = watch.alerts({'runs': []}, {'failed': []}, 0, [], [failed('z')], {})
        self.assertIsInstance(failed_notice[0], watch.Urgent)

    def test_failed_dispatch_goes_at_once_as_a_message_and_is_never_typed(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        calls.clear()
        notice = watch.alerts({'runs': []}, {'failed': []}, 0, [], [failed('z')], {})
        watch.deliver_notices(UNTYPED, state, notice, rpc, now=10, owner_of=NO_OWNER)
        self.assertEqual([c for c in calls if c[:2] == ('terminal', 'send')], [])
        self.assertEqual([t for t, _ in sent(calls)], ['term_first', 'term_second'])
        self.assertIn('failed dispatch z', sent(calls)[0][1])

    def test_no_alarm_types_into_a_terminal(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'}],
                  'leads': [{'name': 'L', 'terminal': 'tl'}], 'fleet_config': ''}
        import tempfile
        fleet = pathlib.Path(tempfile.mkdtemp())/'fleet-config.json'
        fleet.write_text(json.dumps({'host_caps': {'h': 1}}))
        config['fleet_config'] = str(fleet)
        state = {'r1': {'since': 0, 'alerted': False}, 'failed': []}
        workers = run_on('h', n=2) + [failed('z')]
        notices = watch.alerts(config, state, 600, [{'run_id': 'r1', 'read': 0}], workers, {'r1': False}, {'tl': False})
        text = ' | '.join(notices)
        for kind in ('inbox waiter absent', 'failed dispatch', 'lead pane gone', 'host cap exceeded'):
            self.assertIn(kind, text)
        self.assertTrue(all(isinstance(n, watch.Urgent) for n in notices))
        calls = []
        watch.deliver_notices(config, {}, notices, digest_rpc(calls), now=0, owner_of=NO_OWNER)
        self.assertEqual([c for c in calls if c[:2] == ('terminal', 'send')], [])
        self.assertEqual(sent(calls)[0][0], 'term_first')
        for kind in ('inbox waiter absent', 'failed dispatch', 'lead pane gone', 'host cap exceeded'):
            self.assertIn(kind, sent(calls)[0][1])

    def test_failed_send_retries_without_loss_or_repeat(self):
        state, calls = {}, []
        with contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices(UNTYPED, state, ['n1'], digest_rpc(calls, {'term_first': OSError('x')}), now=0, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [('term_first', 'n1'), ('term_second', 'n1')])
        calls.clear()
        watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=60, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [('term_first', 'n1')])
        calls.clear()
        watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=120, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [])

    def test_give_up_after_twenty_passes_prints_to_stderr(self):
        state, err = {}, io.StringIO()
        with contextlib.redirect_stderr(err):
            for i in range(20):
                watch.deliver_notices(UNTYPED, state, ['n1'] if i == 0 else [], digest_rpc([], {'term_first': OSError('x')}), now=i, owner_of=NO_OWNER)
        gave_up = [l for l in err.getvalue().splitlines() if 'giving up' in l]
        self.assertEqual(len(gave_up), 1)
        self.assertIn('n1', gave_up[0])
        self.assertEqual(state['notice_queue'].get('term_first', []), [])

    def test_restart_neither_floods_nor_drops(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'state.json'
            state, calls = {}, []
            watch.deliver_notices(UNTYPED, state, ['n1'], digest_rpc(calls), now=0, owner_of=NO_OWNER)
            watch.deliver_notices(UNTYPED, state, ['n2'], digest_rpc(calls), now=30, owner_of=NO_OWNER)
            watch.save_state(path, state)
            state = json.loads(path.read_text())
            calls.clear()
            watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=90, owner_of=NO_OWNER)
            self.assertEqual(sent(calls), [])
            watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=600, owner_of=NO_OWNER)
            self.assertEqual(sent(calls), [('term_first', 'n2'), ('term_second', 'n2')])

    def test_verdict_goes_to_owning_lead_at_once_as_a_message(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        calls.clear()
        verdict = watch.pr_events('o/r', {}, [{'number': 7, 'state': 'OPEN', 'headRefOid': 'h', 'statusCheckRollup': [],
            'comments': [{'id': 'c1', 'body': 'Verdict: PASS head=h verifier=v1 author=ctx_a1\nfine'}]}], 0, 99)[0]
        self.assertEqual(verdict, ['o/r #7 Verdict: PASS head=h verifier=v1 author=ctx_a1'])
        watch.deliver_notices(UNTYPED, state, verdict, rpc, now=5, owner_of=lambda a: 'term_lead' if a == 'ctx_a1' else None)
        self.assertEqual(sent(calls), [('term_lead', verdict[0])])
        self.assertEqual([c for c in calls if c[:2] == ('terminal', 'send')], [])

    def test_verdict_without_owner_goes_to_the_digest(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        calls.clear()
        verdict = watch.Verdict('o/r #7 Verdict: PASS head=h verifier=v author=unknown')
        verdict.author = 'unknown'
        watch.deliver_notices(UNTYPED, state, [verdict], rpc, now=5, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [])
        watch.deliver_notices(UNTYPED, state, [], rpc, now=600, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 2)


class DrainCounts(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.path = pathlib.Path(tempfile.mkdtemp())/'coordinator-drain.log'
        self.config = {'runs': [], 'leads': [{'name': 'Lead One', 'terminal': 'term_l1'}, {'name': 'Lead Two', 'terminal': 'term_l2'}]}

    def test_counts_per_lead_become_one_digest_line_and_reset(self):
        self.path.write_text('term_l1\n' * 98 + 'term_l2\n' * 3)
        notices = watch.drain_notices(self.config, self.path)
        self.assertEqual(notices, ['lead stops dropped from the coordinator inbox: Lead One 98, Lead Two 3'])
        self.assertNotIsInstance(notices[0], watch.Urgent)
        self.assertFalse(self.path.exists())
        self.assertEqual(watch.drain_notices(self.config, self.path), [])

    def test_unknown_handle_is_named_by_handle_and_missing_file_is_silent(self):
        self.assertEqual(watch.drain_notices(self.config, self.path), [])
        self.path.write_text('term_gone\nterm_gone\n')
        self.assertEqual(watch.drain_notices(self.config, self.path), ['lead stops dropped from the coordinator inbox: term_gone 2'])

    def test_counts_are_not_lost_when_the_pass_stops_before_it_finishes(self):
        self.path.write_text('term_l1\n' * 4)
        claimed = watch.drain_notices(self.config, self.path, keep=True)
        self.assertEqual(len(claimed), 1)
        self.assertEqual(len(watch.drain_notices(self.config, self.path)), 1)


class Sweep(unittest.TestCase):
    def test_each_run_is_swept_once_per_pass_and_output_lines_become_notices(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
                           {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'}]}
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout='worker-done sweep: d1 seat kept, x\n\n', stderr='')
        notices = watch.sweep_notices(config, runner)
        self.assertEqual(len(calls), 2)
        for command, run, terminal in zip(calls, ('r1', 'r2'), ('term_first', 'term_second')):
            self.assertEqual(command[0], 'bash')
            self.assertTrue(command[1].endswith('worker-done-relay.sh'))
            self.assertEqual(command[2:], ['sweep', '--coordinator', terminal, '--run', run])
        self.assertEqual(notices, ['worker-done sweep: d1 seat kept, x'] * 2)
        self.assertNotIsInstance(notices[0], watch.Urgent)

    def test_failing_sweep_adds_no_notice_and_does_not_stop_the_pass(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'}]}
        def runner(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 1)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(watch.sweep_notices(config, runner), [])
        self.assertIn('sweep failed', err.getvalue())

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
