#!/usr/bin/env bash
# No orca: partial terminal send must not repeat notices on terminals that already got them.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, json, pathlib, re, subprocess, sys, tempfile, unittest
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

UNTYPED = {'runs': [
    {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
    {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'},
]}

class NoTerminalSend(unittest.TestCase):
    def test_a_full_pass_never_calls_terminal_send_even_with_a_stale_typed_key(self):
        with tempfile.TemporaryDirectory() as directory:
            fleet = pathlib.Path(directory)/'fleet-config.json'
            fleet.write_text(json.dumps({'host_caps': {'h': 1}}))
            config = pathlib.Path(directory)/'config.json'
            config.write_text(json.dumps({
                'runs': [dict(UNTYPED['runs'][0], typed=True), UNTYPED['runs'][1]],
                'leads': [{'name': 'L', 'terminal': 'term_lead'}], 'fleet_config': str(fleet)}))
            calls = []
            workers = run_on('h', n=2) + [failed('z')]
            def rpc(*args):
                calls.append(args)
                if args[:2] == ('terminal', 'send'):
                    raise AssertionError('fleet-watch typed into a terminal: %r' % (args,))
                if args[:2] == ('terminal', 'show'):
                    raise subprocess.CalledProcessError(1, 'orca', stderr='terminal_not_found')
                if args[1] == 'inbox':
                    return {'messages': [{'run_id': 'r1', 'read': 0}]}
                if args[1] == 'worker-list':
                    return {'workers': workers, 'page': {'hasMore': False}}
                return {}
            state = pathlib.Path(directory)/'state.json'
            state.write_text(json.dumps({'failed': [], 'r1': {'since': 0, 'alerted': False}}))
            for _ in range(3):
                with patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                     patch.object(watch, 'rpc', side_effect=rpc), \
                     patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                    watch.main()
            bodies = ' '.join(c[c.index('--body') + 1] for c in calls if c[:2] == ('orchestration', 'send'))
            for kind in ('failed dispatch', 'lead pane gone', 'host cap exceeded', 'inbox waiter absent'):
                self.assertIn(kind, bodies)

    def test_the_source_has_no_terminal_send_call(self):
        source = (root/'fleet-watch.py').read_text()
        self.assertIsNone(re.search(r"['\"]terminal['\"]\s*,\s*['\"]send['\"]", source))
        self.assertNotIn('typed', source)


def digest_rpc(calls, broken=None):
    def rpc(*args):
        calls.append(args)
        if args[:2] == ('orchestration', 'send') and '--from' not in args:
            raise subprocess.CalledProcessError(1, args, stderr='error: no_active_sender_terminal')
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

    def test_every_send_names_the_terminal_it_goes_to_as_its_sender(self):
        calls = []
        watch.deliver_notices(UNTYPED, {}, ['n1'], digest_rpc(calls), now=0, owner_of=NO_OWNER)
        sends = [c for c in calls if c[:2] == ('orchestration', 'send')]
        self.assertEqual(len(sends), 2)
        for c in sends:
            self.assertEqual(c[c.index('--from') + 1], c[c.index('--to') + 1])

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

if __name__ == '__main__':
    unittest.main(argv=['x'], verbosity=1)
PY
