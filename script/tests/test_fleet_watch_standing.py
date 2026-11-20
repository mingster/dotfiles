import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HOST = 'trial-host'


def head_of(number):
    return '%040x' % number


def pr(number, verdict=False, **extra):
    head = head_of(number)
    comments = [{'body': 'Review: PASS head=%s' % head}]
    if verdict:
        comments.append({'body': 'Verdict: PASS head=%s' % head})
    row = {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'b%s' % number,
        'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
        'comments': comments, 'labels': [], 'mergeable': 'MERGEABLE',
        'body': 'Builder: agent=claude model=sonnet',
    }
    row.update(extra)
    return row


def standing_row(dispatch='ctx_s1', terminal='term_s1'):
    return {
        'dispatchId': dispatch, 'taskId': 'task_s1', 'terminalState': 'active', 'dispatchStatus': 'dispatched',
        'terminal': terminal,
        'projection': {'role': 'worker', 'outcome': 'in_progress', 'liveness': {'verdict': 'live'}},
        '_task_title': '#7|qa-sdet|standing',
    }


class FakeIO:
    def __init__(self):
        self.screens = {}
        self.sent = []
        self.stopped = []
        self.sleeps = []
        self.wakes = True
        self.tick = 100

    resolved = ''

    def resolve_terminal(self, dispatch, name, host):
        return self.resolved

    def read(self, terminal, host):
        return self.screens.get(terminal, ('', None))

    def send(self, terminal, text, host):
        self.sent.append((terminal, text, host))
        if self.wakes:
            self.tick += 1
            self.screens[terminal] = ('Thinking', self.tick)
        return True

    def stop(self, dispatch_id, host):
        self.stopped.append((dispatch_id, host))

    def sleep(self, seconds):
        self.sleeps.append(seconds)


class StandingVerifier(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log = os.path.join(self.tmp.name, 'verifier-trial.tsv')
        patcher = patch.dict(os.environ, {'STANDING_VERIFIER_TRIAL_LOG': self.log})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.io = FakeIO()
        self.io.screens['term_s1'] = ('> ', 100)
        self.starts = []
        self.released = []
        self.now = 10000.0
        self.enabled = True
        self.workers = []

    def config(self, **standing):
        block = {'enabled': self.enabled, 'hosts': [HOST]}
        block.update(standing)
        return {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {'o/r': self.tmp.name}},
            'babysit': {'repos': ['o/r'], 'startup': '/bin/true', 'standing_verifier': block, 'per_pass_cap': 5},
        }

    def start_worker(self, command):
        self.starts.append(command)
        if '--on' in command:
            return fw.BabysitStartResult(0, '', 'ctx_s1', 'term_s1')
        return fw.BabysitStartResult(0, '', 'ctx_fresh%d' % len(self.starts), 'term_f')

    def run_pass(self, prs, state, **standing):
        self.now += 60
        return fw.babysit_pass(
            self.config(**standing), state, self.workers, pr_fetch=lambda _repo: prs,
            start_worker=self.start_worker,
            pick=lambda _role, **_kw: {'selected': {'provider': 'antigravity', 'model': 'm', 'eligible': True, 'headroom': 50}},
            owner_check=lambda _pr, **_kw: None,
            release_worker=lambda did, env=None: self.released.append((did, env)),
            notify_worker=lambda *_a: None,
            now=self.now, term_times={}, standing_io=self.io,
        )

    def trial_rows(self):
        return fw.read_trial_rows(self.log)

    def test_disabled_by_default_starts_a_fresh_verifier(self):
        self.enabled = False
        state = {}
        self.run_pass([pr(7)], state)
        self.assertEqual(len(self.starts), 1)
        self.assertNotIn('--on', self.starts[0])
        self.assertEqual(state.get('standing_verifiers') or {}, {})
        self.assertFalse(os.path.exists(self.log))

    def test_first_pr_starts_one_standing_verifier(self):
        state = {}
        _n, lines, _log = self.run_pass([pr(7)], state)
        self.assertEqual(len(self.starts), 1, lines)
        command = self.starts[0]
        self.assertEqual(command[command.index('--title') + 1], '#7|qa-sdet|standing')
        self.assertEqual(command[command.index('--name') + 1], 'verify-standing-o-r')
        self.assertEqual(command[command.index('--on') + 1], HOST)
        self.assertEqual(command[command.index('--agent') + 1], 'antigravity')
        rec = state['standing_verifiers'][HOST]
        self.assertEqual((rec['dispatch_id'], rec['terminal'], rec['current_pr']), ('ctx_s1', 'term_s1', 7))
        self.assertEqual(rec['prs_assigned'], ['o/r#7@%s' % head_of(7)])
        self.assertEqual([r['event'] for r in self.trial_rows()], ['start'])

    def test_second_pr_goes_to_the_idle_standing_verifier(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        self.run_pass([pr(7, verdict=True), pr(8)], state)
        self.assertEqual(len(self.starts), 1)
        self.assertEqual(len(self.io.sent), 1)
        terminal, text, host = self.io.sent[0]
        self.assertEqual((terminal, host), ('term_s1', HOST))
        for needle in ('Refs o/r#8', head_of(8), 'agent=claude model=sonnet', 'git fetch origin pull/8/head',
                       'script/post-verdict.sh --verifier ctx_s1'):
            self.assertIn(needle, text)
        self.assertNotIn('last PR', text)
        rec = state['standing_verifiers'][HOST]
        self.assertEqual((rec['current_pr'], len(rec['prs_assigned'])), (8, 2))
        events = [r['event'] for r in self.trial_rows()]
        self.assertEqual(events, ['start', 'verdict', 'wake'])

    def test_a_busy_standing_verifier_sends_the_next_pr_to_a_fresh_worker(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        self.run_pass([pr(7), pr(8)], state)
        self.assertEqual(self.io.sent, [])
        self.assertEqual(len(self.starts), 2)
        self.assertNotIn('--on', self.starts[1])

    def test_fifth_pr_carries_the_retirement_order_and_the_verifier_retires_after_its_verdict(self):
        state = {}
        self.run_pass([pr(1)], state)
        self.workers = [standing_row()]
        for number in (2, 3, 4, 5):
            self.run_pass([pr(number - 1, verdict=True), pr(number)], state)
        self.assertEqual(len(self.io.sent), 4)
        self.assertNotIn('last PR', self.io.sent[2][1])
        self.assertIn('last PR', self.io.sent[3][1])
        self.assertIn('--workspace-status completed', self.io.sent[3][1])
        self.assertEqual(len(state['standing_verifiers'][HOST]['prs_assigned']), 5)
        _n, _lines, log_bits = self.run_pass([pr(5, verdict=True)], state)
        self.assertEqual(state['standing_verifiers'], {})
        self.assertEqual(self.io.stopped, [('ctx_s1', HOST)])
        self.assertEqual(self.released, [('ctx_s1', HOST)])
        self.assertIn('standing_retire=ctx_s1:max_prs', log_bits)
        retire = [r for r in self.trial_rows() if r['event'] == 'retire'][0]
        self.assertEqual((retire['reason'], retire['prs_done']), ('max_prs', '5'))

    def test_long_context_retires_the_verifier_and_starts_a_new_one(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        self.io.screens['term_s1'] = ('work\nctx: 85%', 100)
        self.run_pass([pr(7, verdict=True), pr(8)], state)
        self.assertEqual(self.io.sent, [])
        self.assertEqual(self.io.stopped, [('ctx_s1', HOST)])
        self.assertEqual(len(self.starts), 2)
        self.assertEqual(self.starts[1][self.starts[1].index('--title') + 1], '#8|qa-sdet|standing')
        retire = [r for r in self.trial_rows() if r['event'] == 'retire'][0]
        self.assertEqual(retire['reason'], 'low_context')
        self.assertEqual(state['standing_verifiers'][HOST]['current_pr'], 8)

    def test_every_long_context_sign_is_read(self):
        cfg = fw.standing_settings(self.config())
        for text, hit in (('ctx: 70%', True), ('ctx: 69%', False), ('Context limit reached', True),
                          ('Run /compact to continue', True), ('STOPPED quota', True), ('42 turns used', False),
                          ('120 turns used', True), ('Thinking', False)):
            self.assertEqual(bool(fw.standing_low_context(text, cfg)), hit, text)

    def test_wake_failure_stops_the_verifier_and_falls_back_to_a_fresh_worker_in_the_same_pass(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        self.io.wakes = False
        _n, _lines, log_bits = self.run_pass([pr(7, verdict=True), pr(8)], state)
        self.assertEqual(self.io.sleeps, [5, 10])
        self.assertIn('standing_wake_fail=ctx_s1:o/r#8', log_bits)
        self.assertEqual(self.io.stopped, [('ctx_s1', HOST)])
        self.assertEqual(self.released, [('ctx_s1', HOST)])
        self.assertEqual(state['standing_verifiers'], {})
        self.assertEqual(len(self.starts), 2)
        fresh = self.starts[1]
        self.assertEqual(fresh[fresh.index('--title') + 1], '#8|qa-sdet')
        self.assertNotIn('--on', fresh)
        events = [r['event'] for r in self.trial_rows()]
        self.assertIn('wake_fallback', events)
        self.assertEqual(events[-1], 'start')
        self.assertEqual(self.trial_rows()[-1]['mode'], 'fresh')

    def test_next_pass_wake_timeout_fails_a_verifier_that_never_woke(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        rec = state['standing_verifiers'][HOST]
        rec.update(wake_verified=False, assigned_at=self.now - 120, assigned_last=100)
        self.io.screens['term_s1'] = ('> ', 100)
        _n, _lines, log_bits = self.run_pass([pr(7)], state)
        self.assertIn('standing_wake_fail=ctx_s1:o/r#7', log_bits)
        self.assertEqual(self.io.stopped, [('ctx_s1', HOST)])
        self.assertEqual(len(self.starts), 2)
        self.assertNotIn('--on', self.starts[1])

    def test_next_pass_wake_timeout_keeps_a_verifier_that_woke(self):
        state = {}
        self.run_pass([pr(7)], state)
        self.workers = [standing_row()]
        state['standing_verifiers'][HOST].update(wake_verified=False, assigned_at=self.now - 120, assigned_last=100)
        self.io.screens['term_s1'] = ('Thinking', 105)
        self.run_pass([pr(7)], state)
        self.assertEqual(self.io.stopped, [])
        self.assertTrue(state['standing_verifiers'][HOST]['wake_verified'])

    def test_an_exited_standing_verifier_is_dropped_and_replaced(self):
        state = {}
        self.run_pass([pr(7)], state)
        gone = standing_row()
        gone['projection']['liveness'] = {'verdict': 'exited'}
        self.workers = [gone]
        self.run_pass([pr(7, verdict=True), pr(8)], state)
        self.assertEqual(state['standing_verifiers'][HOST]['current_pr'], 8)
        self.assertEqual(len(self.starts), 2)

    def test_a_standing_verifier_counts_as_the_live_verifier_on_its_current_pr(self):
        state = {'standing_verifiers': {HOST: {'dispatch_id': 'ctx_s1', 'repo': 'o/r', 'current_pr': 8}}}
        workers = [standing_row()]
        self.assertTrue(fw.live_verifier_for_pr({'number': 8}, workers, state, 'o/r'))
        self.assertFalse(fw.live_verifier_for_pr({'number': 7}, workers, state, 'o/r'))
        self.assertFalse(fw.live_verifier_for_pr({'number': 8}, workers, state, 'other/repo'))
        self.assertFalse(fw.live_verifier_for_pr({'number': 7}, workers))

    def test_a_non_antigravity_pick_never_uses_the_standing_verifier(self):
        state = {}
        self.now += 60
        fw.babysit_pass(
            self.config(), state, [], pr_fetch=lambda _repo: [pr(7)], start_worker=self.start_worker,
            pick=lambda _role, **_kw: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
            owner_check=lambda _pr, **_kw: None, release_worker=lambda *_a: None, notify_worker=lambda *_a: None,
            now=self.now, term_times={}, standing_io=self.io,
        )
        self.assertEqual(len(self.starts), 1)
        self.assertNotIn('--on', self.starts[0])

    def test_trial_log_has_the_header_and_a_summary_compares_both_modes(self):
        fw.trial_event('start', 'standing', HOST, 1000, dispatch_id='d1', repo='o/r', pr=1, head='h', prs_done=1, headroom_pct=50)
        fw.trial_event('verdict', 'standing', HOST, 1100, dispatch_id='d1', repo='o/r', pr=1, head='h', duration_s=100, headroom_pct=48)
        fw.trial_event('wake', 'standing', HOST, 1200, dispatch_id='d1', repo='o/r', pr=2, head='h', prs_done=2)
        fw.trial_event('wake_fallback', 'standing', HOST, 1300, dispatch_id='d1', repo='o/r', pr=3, head='h', reason='probe')
        fw.trial_event('retire', 'standing', HOST, 1400, dispatch_id='d1', repo='o/r', prs_done=3, reason='max_prs')
        fw.trial_event('start', 'fresh', now=1500, repo='o/r', pr=4, head='h', headroom_pct=40)
        fw.trial_event('start_fail', 'fresh', now=1510, repo='o/r', pr=5, head='h', reason='boom')
        fw.trial_event('verdict', 'fresh', now=1600, repo='o/r', pr=4, head='h', duration_s=300, headroom_pct=36)
        header = Path(self.log).read_text().splitlines()[0].split('\t')
        self.assertEqual(header, list(fw.TRIAL_COLUMNS))
        rows = self.trial_rows()
        self.assertEqual(len(rows), 8)
        self.assertEqual(rows[0]['timestamp'], '1970-01-01T00:16:40Z')
        report = fw.trial_summary(rows)
        self.assertIn('standing: starts=1 start_failure_rate=0% (0/1) verdicts=1 verification_latency_s=100.0 headroom_delta_per_pr=2.0 pts', report)
        self.assertIn('fresh: starts=1 start_failure_rate=50% (1/2) verdicts=1 verification_latency_s=300.0 headroom_delta_per_pr=4.0 pts', report)
        self.assertIn('standing wake_failure_rate=50% (1/2)', report)
        self.assertIn('standing prs_per_dispatch=3.0 retirements=1', report)

    def test_fresh_verifier_start_and_verdict_are_logged_during_the_trial(self):
        state = {}
        self.now += 60
        fw.babysit_pass(
            self.config(), state, [], pr_fetch=lambda _repo: [pr(7)], start_worker=self.start_worker,
            pick=lambda _role, **_kw: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True, 'headroom': 40}},
            owner_check=lambda _pr, **_kw: None, release_worker=lambda *_a: None, notify_worker=lambda *_a: None,
            now=self.now, term_times={}, standing_io=self.io,
        )
        self.run_pass([pr(7, verdict=True)], state)
        rows = self.trial_rows()
        self.assertEqual([(r['mode'], r['event']) for r in rows], [('fresh', 'start'), ('fresh', 'verdict')])
        self.assertEqual(rows[0]['headroom_pct'], '40')

    def test_settings_default_to_disabled_and_need_a_host(self):
        self.assertFalse(fw.standing_settings({})['enabled'])
        self.assertFalse(fw.standing_settings({'babysit': {'standing_verifier': {'enabled': True}}})['enabled'])
        cfg = fw.standing_settings({'babysit': {'standing_verifier': {'enabled': True, 'hosts': ['h'], 'max_prs': '3'}}})
        self.assertEqual((cfg['enabled'], cfg['max_prs'], cfg['model']), (True, 3, 'gemini-4-argon-high'))

    def test_remote_wake_that_never_happens_releases_on_the_environment_and_falls_back(self):
        state = {}
        remote_row = dict(standing_row(), terminal=None, agentTerminalHandle=None)
        self.run_pass([pr(7)], state)
        state['standing_verifiers'][HOST]['terminal'] = ''
        self.workers = [remote_row]
        self.io.resolved = 'term_s1'
        self.io.wakes = False
        self.run_pass([pr(7, verdict=True), pr(8)], state)
        self.assertEqual(self.released, [('ctx_s1', HOST)])
        self.assertEqual(len(self.starts), 2)
        self.assertNotIn('--on', self.starts[1])

    def test_the_example_config_documents_the_block_disabled(self):
        import json
        example = json.loads((Path(__file__).parent.parent / 'fleet-watch.config.example.json').read_text())
        block = example['babysit']['standing_verifier']
        self.assertIs(block['enabled'], False)
        self.assertEqual((block['agent'], block['max_prs'], block['wake_timeout_seconds'], block['max_context_percent']),
                         ('antigravity', 5, 90, 70))


class StandingTrialActivation(unittest.TestCase):
    def test_resolve_pass_config_keeps_standing_verifier_from_the_stub(self):
        import json
        with tempfile.TemporaryDirectory() as home:
            stub = Path(home) / '.config' / 'fleet-watch' / 'config.json'
            stub.parent.mkdir(parents=True)
            block = {'enabled': True, 'hosts': ['auto']}
            stub.write_text(json.dumps({'babysit': {'standing_verifier': block}, 'host_caps': {'local': 2}}))
            coordinator = Path(home) / 'elon.json'
            coordinator.write_text(json.dumps({'runs': [{'id': 'run_x', 'terminal': 'term_x'}]}))
            with patch.object(Path, 'home', return_value=Path(home)), \
                    patch.dict(os.environ, {'FLEET_WATCH_COORDINATOR_CONFIG': str(coordinator)}):
                config = json.loads(stub.read_text())
                resolved, adopted = fw.resolve_pass_config(config, str(stub))
        self.assertEqual(adopted, coordinator)
        self.assertEqual(resolved['babysit']['standing_verifier'], block)
        self.assertTrue(resolved['runs'])

    def test_auto_host_picks_the_first_non_local_code_host(self):
        base = {'local_host': 'me', 'worker_placement': {'order': ['me', 'far-a', 'far-b']},
                'host_caps': {'me': 5, 'far-a': 5}}
        for hosts in (['auto'], []):
            config = dict(base, babysit={'standing_verifier': {'enabled': True, 'hosts': hosts}})
            cfg = fw.standing_settings(config)
            self.assertEqual((cfg['enabled'], cfg['hosts']), (True, ['far-a']), hosts)
        caps_only = {'local_host': 'me', 'host_caps': {'me': 5, 'far-b': 5},
                     'babysit': {'standing_verifier': {'enabled': True, 'hosts': ['auto']}}}
        self.assertEqual(fw.standing_settings(caps_only)['hosts'], ['far-b'])
        only_local = {'local_host': 'me', 'host_caps': {'me': 5},
                      'babysit': {'standing_verifier': {'enabled': True, 'hosts': ['auto']}}}
        self.assertFalse(fw.standing_settings(only_local)['enabled'])


class RemoteStandingTerminal(unittest.TestCase):
    def test_default_babysit_start_carries_the_terminal_from_stdout(self):
        done = type('Done', (), {'returncode': 0, 'stderr': '', 'stdout': (
            '{"ok":true,"result":{"dispatchId":"ctx_s9","terminal":{"handle":"term_s9"}}}')})()
        result = fw.default_babysit_start(['x'], run=lambda *_a, **_k: done)
        self.assertEqual((result.dispatch_id, result.terminal), ('ctx_s9', 'term_s9'))

    def test_resolve_terminal_reads_worker_show_then_terminal_list_and_caches(self):
        calls = []

        def fake_rpc(*args):
            calls.append(args)
            if args[:2] == ('orchestration', 'worker-show'):
                return {'worker': {'dispatchId': 'ctx_s1', 'agentTerminalHandle': None}}
            if args[:2] == ('terminal', 'list'):
                return {'terminals': [{'handle': 'term_other', 'title': 'x'},
                                      {'handle': 'term_found', 'title': 'verify-standing-o-r'}]}
            return {}
        io = fw.StandingIO({'local_host': 'me'})
        with patch.object(fw, 'rpc', fake_rpc):
            self.assertEqual(io.resolve_terminal('ctx_s1', 'verify-standing-o-r', 'far-a'), 'term_found')
        self.assertIn(('orchestration', 'worker-show', '--dispatch', 'ctx_s1', '--environment', 'far-a'), calls)
        self.assertIn(('terminal', 'list', '--environment', 'far-a'), calls)

    def test_resolve_terminal_prefers_the_worker_show_handle(self):
        def fake_rpc(*args):
            return {'worker': {'terminal': 'term_shown'}}
        with patch.object(fw, 'rpc', fake_rpc):
            self.assertEqual(fw.StandingIO({}).resolve_terminal('ctx_s1', 'verify-standing-o-r', 'far-a'), 'term_shown')

    def test_standing_terminal_resolves_once_and_caches_on_the_record(self):
        class Io:
            calls = 0

            def resolve_terminal(self, dispatch, name, host):
                self.calls += 1
                return 'term_r'
        rec, io = {'dispatch_id': 'ctx_s1', 'repo': 'o/r', 'host': 'far-a', 'terminal': ''}, Io()
        remote_row = {'dispatchId': 'ctx_s1', 'agentTerminalHandle': None}
        self.assertEqual(fw._standing_terminal(rec, [remote_row], io), 'term_r')
        self.assertEqual(fw._standing_terminal(rec, [remote_row], io), 'term_r')
        self.assertEqual((io.calls, rec['terminal']), (1, 'term_r'))


if __name__ == '__main__':
    unittest.main()
