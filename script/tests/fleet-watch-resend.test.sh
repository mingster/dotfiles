#!/usr/bin/env bash
# No orca: digest delivery via orchestration send; typed runs may still use terminal send.
set -euo pipefail
# Keep fixture lines out of ~/.orca/logs/fleet-watch.log (#1864).
if [ -z "$(printf %s "${FLEET_WATCH_LOG_PATH:-}" | tr -d '[:space:]')" ]; then
  FLEET_WATCH_LOG_PATH="$(mktemp -d "${TMPDIR:-/tmp}/fleet-watch-test-log.XXXXXX")/fleet-watch-test.log"
  export FLEET_WATCH_LOG_PATH
  trap 'rm -rf "${FLEET_WATCH_LOG_PATH%/*}"' EXIT
fi
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
PYTHON=$(PATH="$path_no_asdf" type -P python3 2>/dev/null || true)
[ -x "$PYTHON" ] || PYTHON="$(ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}" asdf which python3 2>/dev/null || true)"
[ -x "$PYTHON" ] || { echo "missing python3" >&2; exit 1; }
"$PYTHON" - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import contextlib, importlib.util, io, json, pathlib, subprocess, sys, tempfile, unittest
from unittest.mock import patch
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('fleet_watch', root/'fleet-watch.py')
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)

import os, tempfile as _tf
watch.DRAIN_LOG_DEFAULT = str(pathlib.Path(_tf.mkdtemp())/'drain.log')
# Keep every line this file logs off the coordinator's real ~/.orca/logs/fleet-watch.log (#1843).
LOG = pathlib.Path(_tf.mkdtemp())/'fleet-watch.log'
os.environ['FLEET_WATCH_LOG_PATH'] = str(LOG)

def failed(name):
    return {'dispatchId': name, 'dispatchStatus': 'failed'}

UNTYPED = {'runs': [
    {'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'},
    {'id': 'r2', 'terminal': 'term_second', 'waiter_pattern': 'w2'},
]}

class NoTerminalSend(unittest.TestCase):
    def test_a_full_pass_never_calls_terminal_send_without_typed(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory)/'config.json'
            config.write_text(json.dumps({
                'runs': UNTYPED['runs'],
                'host_caps': {'h': 1},
                'leads': [{'name': 'L', 'terminal': 'term_lead'}]}))
            calls = []
            workers = run_on('h', n=2) + [failed('z')]
            def rpc(*args):
                calls.append(args)
                if args[:2] == ('terminal', 'send'):
                    raise AssertionError('fleet-watch typed into a terminal: %r' % (args,))
                if args[:2] == ('terminal', 'show'):
                    term = args[args.index('--terminal') + 1]
                    if term == 'term_lead':
                        raise watch.TerminalNotFound('terminal_not_found')
                    return {}
                if args[:2] == ('orchestration', 'inbox'):
                    return {'messages': [{'run_id': 'r1', 'read': 0}]}
                if args[:2] == ('orchestration', 'worker-list'):
                    return {'workers': workers, 'page': {'hasMore': False}}
                if args[:2] == ('terminal', 'list'):
                    return {'terminals': []}
                return {}
            state = pathlib.Path(directory)/'state.json'
            state.write_text(json.dumps({'failed': [], 'r1': {'since': 0, 'alerted': False}}))
            _spec_env = importlib.util.spec_from_file_location('fleet_watch_test_env', root/'tests'/'fleet_watch_test_env.py')
            _fwe = importlib.util.module_from_spec(_spec_env); _spec_env.loader.exec_module(_fwe)
            with _fwe.redirect_main_log_under(directory), \
                 patch('sys.argv', ['fleet-watch', '--config', str(config), '--state', str(state)]), \
                 patch.object(watch, 'rpc', side_effect=rpc), \
                 patch.object(watch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                watch.main()
            bodies = ' '.join(c[c.index('--body') + 1] for c in calls if c[:2] == ('orchestration', 'send'))
            for kind in ('failed dispatch', 'lead pane gone', 'host cap exceeded', 'inbox waiter absent'):
                self.assertIn(kind, bodies)

    def test_typed_run_gets_terminal_send_others_get_orchestration(self):
        config = {'runs': [
            dict(UNTYPED['runs'][0], typed=True),
            UNTYPED['runs'][1],
        ]}
        calls = []
        def rpc(*args):
            calls.append(args)
            return {}
        watch.deliver_notices(config, {}, ['notice line'], rpc, now=0, owner_of=lambda a: None)
        term_sends = [c for c in calls if c[:2] == ('terminal', 'send')]
        orch = [(c[c.index('--to') + 1], c[c.index('--body') + 1]) for c in calls if c[:2] == ('orchestration', 'send')]
        self.assertEqual(len(term_sends), 1)
        self.assertEqual(term_sends[0][term_sends[0].index('--terminal') + 1], 'term_first')
        self.assertEqual(orch, [('run:r2', 'notice line')])
        orch_args = [c for c in calls if c[:2] == ('orchestration', 'send')][0]
        self.assertEqual(orch_args[orch_args.index('--from') + 1], 'term_second')
        self.assertNotEqual(orch_args[orch_args.index('--from') + 1], orch_args[orch_args.index('--to') + 1])


def digest_rpc(calls, broken=None):
    def rpc(*args):
        calls.append(args)
        term = args[args.index('--to') + 1] if '--to' in args else args[args.index('--terminal') + 1]
        if term in (broken or {}):
            raise broken[term]
        return {}
    return rpc

def sent(calls):
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
        self.assertEqual(sent(calls), [('run:r1', 'n1'), ('run:r2', 'n1')])
        first = [c for c in calls if c[:2] == ('orchestration', 'send')][0]
        self.assertEqual(first[first.index('--from') + 1], 'term_first')
        self.assertNotEqual(first[first.index('--to') + 1], first[first.index('--from') + 1])

    def test_digest_goes_out_at_most_every_600_seconds_oldest_first(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        for now, line in ((60, 'n2'), (300, 'n3'), (599, None)):
            watch.deliver_notices(UNTYPED, state, [line] if line else [], rpc, now=now, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 2)
        watch.deliver_notices(UNTYPED, state, [], rpc, now=600, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2:], [('run:r1', 'n2\nn3'), ('run:r2', 'n2\nn3')])
        watch.deliver_notices(UNTYPED, state, [], rpc, now=1300, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 4)

    def test_duplicates_are_merged(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['a'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['b', 'c', 'b'], rpc, now=10, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['c'], rpc, now=20, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, [], rpc, now=700, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2], ('run:r1', 'b\nc'))

    def test_urgent_notice_skips_the_wait_and_carries_the_queue(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['n2'], rpc, now=5, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, [watch.Urgent('lead pane gone: x')], rpc, now=10, owner_of=NO_OWNER)
        self.assertEqual(sent(calls)[2:], [('run:r1', 'n2\nlead pane gone: x'), ('run:r2', 'n2\nlead pane gone: x')])

    def test_plain_text_that_looks_urgent_still_waits(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        watch.deliver_notices(UNTYPED, state, ['lead pane gone: x', 'host cap exceeded: h 5/4'], rpc, now=10, owner_of=NO_OWNER)
        self.assertEqual(len(sent(calls)), 2)

    def test_alerts_mark_dead_lead_and_over_cap_urgent(self):
        config = {'runs': [], 'host_caps': {'h': 1}, 'leads': [{'name': 'L', 'terminal': 'tl'}]}
        workers = run_on('h', n=2)
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
        self.assertEqual([t for t, _ in sent(calls)], ['run:r1', 'run:r2'])
        self.assertIn('failed dispatch z', sent(calls)[0][1])

    def test_no_alarm_types_into_a_terminal(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'waiter_pattern': 'w1'}],
                  'host_caps': {'h': 1}, 'leads': [{'name': 'L', 'terminal': 'tl'}]}
        state = {'r1': {'since': 0, 'alerted': False}, 'failed': []}
        workers = run_on('h', n=2) + [failed('z')]
        notices = watch.alerts(config, state, 600, [{'run_id': 'r1', 'read': 0}], workers, {'r1': False}, {'tl': False})
        text = ' | '.join(str(n) for n in notices)
        for kind in ('inbox waiter absent', 'failed dispatch', 'lead pane gone', 'host cap exceeded'):
            self.assertIn(kind, text)
        self.assertTrue(all(isinstance(n, watch.Urgent) for n in notices))
        calls = []
        watch.deliver_notices(config, {}, notices, digest_rpc(calls), now=0, owner_of=NO_OWNER)
        self.assertEqual([c for c in calls if c[:2] == ('terminal', 'send')], [])
        self.assertEqual(sent(calls)[0][0], 'run:r1')
        for kind in ('inbox waiter absent', 'failed dispatch', 'lead pane gone', 'host cap exceeded'):
            self.assertIn(kind, sent(calls)[0][1])

    def test_failed_send_retries_without_loss_or_repeat(self):
        state, calls = {}, []
        with contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices(UNTYPED, state, ['n1'], digest_rpc(calls, {'run:r1': OSError('x')}), now=0, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [('run:r1', 'n1'), ('run:r1', 'n1'), ('run:r2', 'n1')])
        calls.clear()
        watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=60, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [('run:r1', 'n1')])
        calls.clear()
        watch.deliver_notices(UNTYPED, state, [], digest_rpc(calls), now=120, owner_of=NO_OWNER)
        self.assertEqual(sent(calls), [])

    def test_notice_stays_queued_through_many_failures_and_drops_after_twenty_four_hours(self):
        state, err = {}, io.StringIO()
        day = 24 * 60 * 60
        failing = digest_rpc([], {'run:r1': OSError('x')})
        with contextlib.redirect_stderr(err):
            watch.deliver_notices(UNTYPED, state, ['n1'], failing, now=0, owner_of=NO_OWNER)
            for i in range(1, 30):
                watch.deliver_notices(UNTYPED, state, [], failing, now=i * 60, owner_of=NO_OWNER)
            self.assertEqual([item['text'] for item in state['notice_queue'].get('run:r1', [])], ['n1'])
            watch.deliver_notices(UNTYPED, state, [], failing, now=day - 1, owner_of=NO_OWNER)
            self.assertEqual([item['text'] for item in state['notice_queue'].get('run:r1', [])], ['n1'])
            watch.deliver_notices(UNTYPED, state, [], failing, now=day, owner_of=NO_OWNER)
        gave_up = [l for l in err.getvalue().splitlines() if 'giving up' in l]
        self.assertEqual(len(gave_up), 1)
        self.assertIn('n1', gave_up[0])
        self.assertIn('24 hours', gave_up[0])
        self.assertEqual(state['notice_queue'].get('run:r1', []), [])
        self.assertIn('OSError', err.getvalue())

    def test_typed_notice_survives_many_tries_and_drops_after_a_day(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'typed': True, 'waiter_pattern': 'w1'}]}
        state, err = {}, io.StringIO()

        def fail(*_args):
            raise OSError('x')

        day = 24 * 60 * 60
        with contextlib.redirect_stderr(err):
            watch.deliver_notices(config, state, ['n1'], fail, now=0, owner_of=NO_OWNER)
            for i in range(1, 25):
                watch.deliver_notices(config, state, [], fail, now=i, owner_of=NO_OWNER)
            self.assertIn('n1', state.get('typed_notice_delivery', {}))
            watch.deliver_notices(config, state, [], fail, now=day, owner_of=NO_OWNER)
        self.assertNotIn('n1', state.get('typed_notice_delivery', {}))
        self.assertTrue(any('giving up' in line and '24 hours' in line for line in err.getvalue().splitlines()))

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
            self.assertEqual(sent(calls), [('run:r1', 'n2'), ('run:r2', 'n2')])

    def test_verdict_goes_to_owning_lead_at_once_as_a_message(self):
        state, calls = {}, []
        rpc = digest_rpc(calls)
        watch.deliver_notices(UNTYPED, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        calls.clear()
        verdict, _ = watch.pr_events('o/r', {}, [{'number': 7, 'state': 'OPEN', 'headRefOid': 'h', 'statusCheckRollup': [],
            'comments': [{'id': 'c1', 'body': 'Verdict: PASS head=' + 'a' * 40 + ' verifier=v1 author=ctx_a1\nfine'}]}], 0, 99)
        self.assertEqual(len(verdict), 1)
        self.assertIsInstance(verdict[0], watch.Verdict)
        watch.deliver_notices(UNTYPED, state, verdict, rpc, now=5, owner_of=lambda a: 'term_lead' if a == 'ctx_a1' else None)
        self.assertEqual(sent(calls), [('term_lead', str(verdict[0]))])
        lead_send = [c for c in calls if c[:2] == ('orchestration', 'send')][-1]
        self.assertEqual(lead_send[lead_send.index('--from') + 1], 'term_first')
        self.assertNotEqual(lead_send[lead_send.index('--from') + 1], 'term_lead')
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

    def test_state_without_notice_queue_still_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            state = pathlib.Path(directory)/'state.json'
            state.write_text(json.dumps({'failed': ['x'], 'notice_delivery': {'old': {'sent': [], 'passes': 0}}}))


def orca_ok(*_a, **_k):
    return subprocess.CompletedProcess([], 0, stdout='{"ok":true,"result":{}}', stderr='')


class SendRetry(unittest.TestCase):
    """#1843: a send whose orca process could not start is tried once more; --from falls back to config."""
    def setUp(self):
        LOG.write_text('')

    def test_spawn_oserror_through_real_rpc_is_retried_once_and_lands(self):
        attempts = []
        def run(cmd, **kw):
            attempts.append(cmd)
            if len(attempts) == 1:
                raise OSError('fork failed')
            return orca_ok()
        state = {}
        with patch.object(watch.subprocess, 'run', side_effect=run), contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices({'runs': [UNTYPED['runs'][0]]}, state, ['n1'], watch.rpc, now=0, owner_of=NO_OWNER)
        self.assertEqual(len(attempts), 2)
        self.assertEqual(attempts[0], attempts[1])
        self.assertEqual(state['notice_queue'], {})
        log = LOG.read_text()
        self.assertIn('send retry for run:r1 after OSError', log)
        self.assertNotIn('send failed', log)

    def test_two_spawn_failures_log_one_failure_after_the_retry(self):
        with patch.object(watch.subprocess, 'run', side_effect=OSError('x')), contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices({'runs': [UNTYPED['runs'][0]]}, {}, ['n1'], watch.rpc, now=0, owner_of=NO_OWNER)
        lines = [l for l in LOG.read_text().splitlines() if 'run:r1' in l]
        self.assertEqual(len(lines), 2)
        self.assertIn('send retry for run:r1 after OSError', lines[0])
        self.assertIn('send failed for run:r1: OrcaReadError', lines[1])

    def test_timeout_is_not_retried(self):
        attempts = []
        def run(cmd, **kw):
            attempts.append(cmd)
            raise subprocess.TimeoutExpired(cmd, 15)
        with patch.object(watch.subprocess, 'run', side_effect=run), contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices({'runs': [UNTYPED['runs'][0]]}, {}, ['n1'], watch.rpc, now=0, owner_of=NO_OWNER)
        self.assertEqual(len(attempts), 1)

    def test_typed_terminal_send_is_retried_once(self):
        config = {'runs': [{'id': 'r1', 'terminal': 'term_first', 'typed': True}]}
        calls = []
        def rpc(*args):
            calls.append(args)
            if len(calls) == 1:
                raise OSError('x')
            return {}
        state = {}
        with contextlib.redirect_stderr(io.StringIO()):
            watch.deliver_notices(config, state, ['n1'], rpc, now=0, owner_of=NO_OWNER)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('n1', state.get('typed_notice_delivery', {}))

    def test_from_comes_from_config_when_the_pass_has_no_handle(self):
        config = {'runs': [], 'babysit': {'from_terminal': 'term_cfg'}}
        verdict = watch.Verdict('o/r #7 Verdict: PASS head=h verifier=v author=ctx_a1')
        verdict.author = 'ctx_a1'
        calls = []
        env = {k: v for k, v in os.environ.items() if k != 'ORCA_TERMINAL_HANDLE'}
        with patch.dict(os.environ, env, clear=True):
            watch.deliver_notices(config, {}, [verdict], digest_rpc(calls), now=0, owner_of=lambda a: 'term_lead')
        send = [c for c in calls if c[:2] == ('orchestration', 'send')]
        self.assertEqual(len(send), 1)
        self.assertEqual(send[0][send[0].index('--from') + 1], 'term_cfg')


def ask(mid, dispatch, **extra):
    return dict({'id': mid, 'type': 'question', 'subject': 'Which port?', 'from': 'term_w',
                 'payload': {'dispatchId': dispatch}}, **extra)

# An answer is a reply threaded to the ask; inbox `handled` alone only means read (#1947).
THREAD_REPLY = {'id': 'msg_r1', 'type': 'status', 'subject': 'Re: Which port?', 'threadId': 'msg_1'}

def live(dispatch, title):
    return {'dispatchId': dispatch, 'dispatchStatus': 'running', 'terminalState': 'active', 'terminal': 'term_w',
            'title': title, 'name': 'build-' + dispatch, 'projection': {}}


class AskStamps(unittest.TestCase):
    """#1843: every ask and reply carries a UTC time in the log and the digest, so wait time can be measured."""
    def setUp(self):
        LOG.write_text('')

    def test_ask_and_reply_are_stamped(self):
        state, workers = {}, [live('ctx_a', '#12|fullstack-dev')]
        t0 = 1764061200  # 2025-11-25T09:00:00Z
        self.assertEqual(watch.unanswered_ask_notices(state, t0, [ask('msg_1', 'ctx_a')], workers), [])
        self.assertIn('ask question msg_1 from ctx_a asked 2025-11-25T09:00:00Z', LOG.read_text())
        late = watch.unanswered_ask_notices(state, t0 + 16 * 60, [ask('msg_1', 'ctx_a')], workers)
        self.assertEqual(len(late), 1)
        self.assertIn('(asked 2025-11-25T09:00:00Z)', str(late[0]))
        self.assertEqual(watch.unanswered_ask_notices(state, t0 + 20 * 60, [ask('msg_1', 'ctx_a'), THREAD_REPLY], workers), [])
        done = watch.take_ask_reply_lines(state)
        line = 'reply to question msg_1 from ctx_a: asked 2025-11-25T09:00:00Z, answer seen 2025-11-25T09:20:00Z, waited 20 minutes'
        self.assertEqual([str(n) for n in done], [line])
        self.assertIn(line, LOG.read_text())
        self.assertEqual(watch.unanswered_ask_notices(state, t0 + 30 * 60, [ask('msg_1', 'ctx_a'), THREAD_REPLY], workers), [])
        self.assertEqual(LOG.read_text().count('reply to question msg_1'), 1)

    def test_orca_created_at_wins_over_first_seen(self):
        state = {}
        watch.unanswered_ask_notices(state, 1764061200, [ask('msg_2', 'ctx_a', created_at='2025-11-25T08:55:00Z')],
                                     [live('ctx_a', '#12|fullstack-dev')])
        self.assertIn('asked 2025-11-25T08:55:00Z', LOG.read_text())

    def test_stamped_reply_reaches_the_digest(self):
        state = {}
        workers = [live('ctx_a', '#12|fullstack-dev')]
        watch.unanswered_ask_notices(state, 0, [ask('msg_1', 'ctx_a')], workers)
        watch.unanswered_ask_notices(state, 60, [ask('msg_1', 'ctx_a'), THREAD_REPLY], workers)
        notices = watch.take_ask_reply_lines(state)
        self.assertEqual(watch.take_ask_reply_lines(state), [])
        calls = []
        watch.deliver_notices(UNTYPED, {}, notices, digest_rpc(calls), now=60, owner_of=NO_OWNER)
        self.assertIn('answer seen 1970-01-01T00:01:00Z', sent(calls)[0][1])


class OpenWork(unittest.TestCase):
    """#1843: open asks and live claims survive a coordinator compaction in a file elon-startup prints."""
    def test_open_ask_and_claim_are_written_and_leave_when_done(self):
        path = pathlib.Path(tempfile.mkdtemp())/'elon-open-work.md'
        state = {}
        workers = [live('ctx_a', '#12|fullstack-dev'), live('ctx_b', 'no issue here')]
        watch.unanswered_ask_notices(state, 0, [ask('msg_1', 'ctx_a')], workers)
        watch.write_open_work(state, workers, {}, 0, path, repo_of=lambda w: 'o/r')
        text = path.read_text()
        self.assertIn('- question msg_1 from ctx_a, asked 1970-01-01T00:00:00Z: Which port?', text)
        self.assertIn('- o/r#12 ctx_a build-ctx_a', text)
        self.assertNotIn('ctx_b', text)
        watch.unanswered_ask_notices(state, 60, [ask('msg_1', 'ctx_a'), THREAD_REPLY], workers)
        watch.write_open_work(state, workers, {}, 60, path, repo_of=lambda w: 'o/r')
        self.assertNotIn('msg_1', path.read_text())
        self.assertIn('o/r#12', path.read_text())
        ended = [dict(workers[0], dispatchStatus='completed')]
        watch.write_open_work(state, ended, {}, 120, path, repo_of=lambda w: 'o/r')
        self.assertNotIn('o/r#12', path.read_text())
        self.assertIn('## Live claims\nnone', path.read_text())

    def test_open_work_sits_beside_the_state_file(self):
        env = {k: v for k, v in os.environ.items() if k != 'ELON_OPEN_WORK_FILE'}
        with patch.dict(os.environ, env, clear=True):
            self.assertEqual(watch.open_work_path('/s/agent-team/fleet-watch.state.json'),
                             pathlib.Path('/s/agent-team/elon-open-work.md'))


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
