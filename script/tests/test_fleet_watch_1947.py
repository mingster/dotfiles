"""#1947: release closes the terminal on its host, the start_unknown reaper, the orphan terminal sweep, and asks
that are Urgent after 5 minutes."""
import copy
import json
import os
import importlib.util
import unittest
from pathlib import Path
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

COORD = 'term_4d505f31-1274-4bd4-96a9-4c3943f89629'
NOW = 2_000_000
IDLE = (NOW - 16 * 60) * 1000
BUSY = (NOW - 60) * 1000
CONFIG = {'runs': [{'id': 'run_1', 'terminal': COORD}]}


class Fleet:
    """Fake orca: per host terminal and worker lists. terminal close removes the terminal from its host."""

    def __init__(self, terminals=None, workers=None, briefs=None):
        self.terminals = terminals or {}
        self.workers = workers or {}
        self.briefs = briefs or {}
        self.calls = []
        self.fail = set()  # verbs that raise, like an unreachable host

    def __call__(self, *args):
        self.calls.append(args)
        args = list(args)
        env = ''
        if '--environment' in args:
            i = args.index('--environment')
            env = args[i + 1]
            del args[i:i + 2]
        verb = tuple(args[:2])
        if verb in self.fail:
            raise RuntimeError('host unreachable')
        if verb == ('terminal', 'list'):
            return {'terminals': list(self.terminals.get(env, []))}
        if verb == ('orchestration', 'worker-list'):
            return {'workers': list(self.workers.get(env, []))}
        if verb == ('orchestration', 'run-list'):
            return {'runs': [{'id': 'run_1', 'coordinator_handle': COORD}]}
        if verb == ('orchestration', 'worker-show'):
            did = args[args.index('--dispatch') + 1]
            for row in self.workers.get(env, []):
                if row.get('dispatchId') == did and row.get('terminal'):
                    return {'worker': {'terminal': row['terminal']}}
            return {'worker': {}}
        if verb == ('orchestration', 'dispatch-show'):
            return {'preamble': self.briefs.get(args[args.index('--task') + 1], '')}
        if verb == ('terminal', 'close'):
            handle = args[args.index('--terminal') + 1]
            self.terminals[env] = [t for t in self.terminals.get(env, []) if t['handle'] != handle]
        return {}

    def closed(self):
        return [(c[c.index('--terminal') + 1], c[c.index('--environment') + 1] if '--environment' in c else '')
                for c in self.calls if c[:2] == ('terminal', 'close')]


def term(handle, title, last=IDLE, path=''):
    return {'handle': handle, 'title': title, 'lastOutputAt': last, 'worktreePath': path or '/w/' + handle}


def row(did, state='running', terminal='', server='', task='task_' + 'x', **extra):
    r = {'dispatchId': did, 'taskId': task, 'state': state, 'terminal': terminal}
    if server:
        r['server'] = server
    r.update(extra)
    return r


class ReleaseClosesTerminal(unittest.TestCase):
    def setUp(self):
        fw.protect_pass_terminals(CONFIG, [])

    def test_release_closes_a_remote_terminal_on_its_host(self):
        fleet = Fleet(terminals={'hostB': [term('term_w', '#5|fullstack-dev')]},
                      workers={'hostB': [row('ctx_w', 'succeeded', 'term_w')]})
        self.assertEqual(fw.release_and_close(fleet, 'ctx_w', 'hostB'), 'closed')
        verbs = [c[1] for c in fleet.calls]
        self.assertLess(verbs.index('worker-stop'), verbs.index('worker-release'))
        self.assertEqual(fleet.closed(), [('term_w', 'hostB')])
        self.assertEqual(fleet.terminals['hostB'], [])

    def test_a_remote_release_stops_and_releases_on_its_host_and_here(self):
        fleet = Fleet(terminals={'hostB': [term('term_r', '#9|fullstack-dev')]},
                      workers={'hostB': [row('ctx_r', 'running', 'term_r')]})
        self.assertEqual(fw.release_and_close(fleet, 'ctx_r', 'hostB'), 'closed')
        for verb in ('worker-stop', 'worker-release'):
            self.assertIn(('orchestration', verb, '--dispatch', 'ctx_r', '--environment', 'hostB'), fleet.calls)
            self.assertIn(('orchestration', verb, '--dispatch', 'ctx_r'), fleet.calls)

    def test_babysit_release_goes_to_the_verifier_host(self):
        got = []
        workers = [row('ctx_v', 'running', 'term_v', server='hostB'), row('ctx_l', 'running', 'term_l')]
        release = fw.release_on_worker_host(CONFIG, workers, lambda did, env: got.append((did, env)))
        release('ctx_v')
        release('ctx_l')
        self.assertEqual(got, [('ctx_v', 'hostB'), ('ctx_l', None)])

    def test_stall_release_closes_the_terminal(self):
        fleet = Fleet(workers={'hostB': [row('ctx_w', terminal='term_w')]})
        self.assertEqual(fw.stop_and_release_stalled(fleet, {'dispatchId': 'ctx_w'}, 'ctx_w', 'hostB', True), '')
        self.assertEqual(fleet.closed(), [('term_w', 'hostB')])

    def test_release_never_closes_the_coordinator_or_another_live_dispatch(self):
        fw.protect_pass_terminals(CONFIG, [row('ctx_live', terminal='term_live')])
        fleet = Fleet()
        self.assertEqual(fw.release_and_close(fleet, 'ctx_a', '', COORD), 'kept:coordinator')
        self.assertEqual(fw.release_and_close(fleet, 'ctx_b', '', 'term_live'), 'kept:live:ctx_live')
        self.assertEqual(fleet.closed(), [])

    def test_release_worker_by_fragment_closes_and_confirms(self):
        fleet = Fleet(terminals={'hostB': [term('term_done1', '#5|fullstack-dev')]},
                      workers={'': [row('ctx_done1', 'succeeded', server='hostB')],
                               'hostB': [row('ctx_done1', 'succeeded', 'term_done1')]})
        code, message = fw.release_worker_by_fragment('done1', CONFIG, fleet, ['', 'hostB'])
        self.assertEqual(code, 0, message)
        self.assertEqual(fleet.closed(), [('term_done1', 'hostB')])

    def test_release_worker_refuses_ambiguous_coordinator_and_live(self):
        fleet = Fleet(terminals={'': [term(COORD, '--elon')]},
                      workers={'': [row('ctx_ab1', 'succeeded', 'term_1'), row('ctx_ab2', 'succeeded', 'term_2'),
                                    row('ctx_run', terminal='term_run')]})
        self.assertEqual(fw.release_worker_by_fragment('ctx_ab', CONFIG, fleet, [''])[0], 1)
        self.assertEqual(fw.release_worker_by_fragment(COORD[5:20], CONFIG, fleet, [''])[0], 1)
        code, message = fw.release_worker_by_fragment('ctx_run', CONFIG, fleet, [''])
        self.assertEqual(code, 1)
        self.assertIn('live', message)
        self.assertEqual(fleet.closed(), [])
        self.assertFalse([c for c in fleet.calls if c[1] in ('worker-stop', 'worker-release')])


class StartUnknownReaper(unittest.TestCase):
    def setUp(self):
        fw.protect_pass_terminals(CONFIG, [])

    def test_resend_once_then_stop_close_and_issue_back(self):
        worker = row('ctx_u', 'start_unknown', 'term_u', server='hostB', task='task_u',
                     title='#77|fullstack-dev', workspace='repo::/w/r/b77')
        fleet = Fleet(terminals={'hostB': [term('term_u', '#77|fullstack-dev')]},
                      workers={'hostB': [dict(worker)]}, briefs={'task_u': 'BRIEF TEXT'})
        edits = []
        config = dict(CONFIG, issue_scan={'repo_roots': {'o/r': '/w/r'}})
        state = {}

        def reap(t):
            return fw.start_unknown_reaper(config, state, t, [dict(worker)], fleet, act=lambda c: edits.append(c) or 0)

        self.assertEqual(reap(NOW), [])
        self.assertEqual(reap(NOW + 599), [])
        self.assertFalse([c for c in fleet.calls if c[:2] == ('terminal', 'send')])
        self.assertEqual(reap(NOW + 600), [])
        sends = [c for c in fleet.calls if c[:2] == ('terminal', 'send')]
        self.assertEqual(len(sends), 1)
        self.assertIn('BRIEF TEXT', sends[0])
        self.assertIn('hostB', sends[0])
        self.assertEqual(reap(NOW + 1199), [])
        self.assertEqual(fleet.closed(), [])
        notices = reap(NOW + 1200)
        self.assertEqual(len(notices), 1)
        self.assertIsInstance(notices[0], fw.Urgent)
        self.assertEqual(fleet.closed(), [('term_u', 'hostB')])
        self.assertIn(('orchestration', 'worker-stop', '--dispatch', 'ctx_u', '--environment', 'hostB'), fleet.calls)
        self.assertEqual(len(edits), 1)
        self.assertIn('ready-for-agent', edits[0])
        self.assertEqual(reap(NOW + 3000), [])
        self.assertEqual(len([c for c in fleet.calls if c[:2] == ('terminal', 'send')]), 1)

    def test_a_real_remote_full_list_row_is_reaped_on_its_host(self):
        # Built from real worker-list --full rows (fixtures/agy-signin-stopped-remote.json): the coordinator
        # holds a stub that says ready, the remote host's own row is the one that says start_unknown.
        real = json.load(open(os.path.join(os.path.dirname(__file__), 'fixtures', 'agy-signin-stopped-remote.json')))
        stub = real['worker_list_full_row_started']
        env = fw.remote_environment(stub)
        hosted = copy.deepcopy(stub)
        hosted.update(workerState='start_unknown', server=None, terminal='term_h')
        hosted['projection'] = dict(hosted.get('projection') or {}, stage={'worker': 'start_unknown'})
        fleet = Fleet(terminals={env: [term('term_h', '#77|fullstack-dev')]}, workers={env: [hosted]},
                      briefs={stub['taskId']: 'BRIEF'})
        state = {}

        def reap(t):
            rows = fw.reaper_rows(fleet, ['', env], [copy.deepcopy(stub)])
            return fw.start_unknown_reaper(CONFIG, state, t, rows, fleet, act=lambda c: 0)

        reap(NOW)
        reap(NOW + 600)
        sends = [c for c in fleet.calls if c[:2] == ('terminal', 'send')]
        self.assertEqual(len(sends), 1)
        self.assertIn(env, sends[0])
        self.assertEqual(len(reap(NOW + 1200)), 1)
        self.assertEqual(fleet.closed(), [('term_h', env)])

    def test_reads_worker_state_from_the_full_list_shape(self):
        # worker-list --full rows carry workerState and no state key.
        worker = {'dispatchId': 'ctx_f', 'taskId': 'task_f', 'workerState': 'start_unknown', 'terminal': 'term_f'}
        fleet = Fleet(briefs={'task_f': 'B'})
        state = {}
        fw.start_unknown_reaper(CONFIG, state, NOW, [worker], fleet)
        fw.start_unknown_reaper(CONFIG, state, NOW + 600, [worker], fleet)
        self.assertEqual(len([c for c in fleet.calls if c[:2] == ('terminal', 'send')]), 1)

    def test_a_failed_resend_or_close_is_tried_again(self):
        worker = row('ctx_r', 'start_unknown', 'term_r', task='task_r')
        fleet = Fleet(terminals={'': [term('term_r', '#5|fullstack-dev')]}, briefs={'task_r': 'B'})
        state = {}

        def reap(t):
            return fw.start_unknown_reaper(CONFIG, state, t, [dict(worker)], fleet, act=lambda c: 0)

        reap(NOW)
        fleet.fail = {('terminal', 'send')}
        reap(NOW + 600)
        self.assertNotIn('resent_at', state['start_unknown']['ctx_r'])
        fleet.fail = set()
        reap(NOW + 660)
        self.assertEqual(state['start_unknown']['ctx_r']['resent_at'], NOW + 660)
        fleet.fail = {('terminal', 'close')}
        self.assertEqual(reap(NOW + 1260), [])
        self.assertFalse(state['start_unknown']['ctx_r'].get('reaped'))
        fleet.fail = set()
        self.assertEqual(len(reap(NOW + 1320)), 1)
        self.assertEqual(fleet.closed()[-1], ('term_r', ''))

    def test_a_worker_that_starts_leaves_the_book(self):
        state = {}
        fleet = Fleet(briefs={'task_x': 'B'})
        fw.start_unknown_reaper(CONFIG, state, NOW, [row('ctx_s', 'start_unknown', 'term_s')], fleet)
        fw.start_unknown_reaper(CONFIG, state, NOW + 700, [row('ctx_s', 'running', 'term_s')], fleet)
        self.assertEqual(state['start_unknown'], {})
        self.assertEqual(fleet.closed(), [])

    def test_stall_ladder_leaves_reaper_dispatches_alone(self):
        state = {}
        fw.start_unknown_reaper(CONFIG, state, NOW, [row('ctx_s', 'start_unknown')], Fleet())
        self.assertEqual(fw.reaper_owned(state), {'ctx_s'})


class OrphanSweep(unittest.TestCase):
    def setUp(self):
        fw.protect_pass_terminals(CONFIG, [])

    def test_closes_only_unmatched_idle_worker_or_run_terminals(self):
        fleet = Fleet(
            terminals={
                '': [term(COORD, '#0|elon'),
                     term('term_orphan_local', '#9|fullstack-dev'),
                     term('term_live_local', '#3|qa-sdet')],
                'hostB': [term('term_orphan', '#5|fullstack-dev'),
                          term('term_run', 'wrap-up-daily run 4'),
                          term('term_busy', '#6|fullstack-dev', last=BUSY),
                          term('term_live', '#7|fullstack-dev'),
                          term('term_live_path', '#8|fullstack-dev', path='/w/b8'),
                          term('term_shell', 'zsh'),
                          term('term_unknown_age', '#10|fullstack-dev', last=None)],
            },
            workers={'': [row('ctx_l', terminal='term_live_local')],
                     'hostB': [row('ctx_live', terminal='term_live'), row('ctx_done', 'succeeded', 'term_orphan')]},
        )
        coordinator_rows = [row('ctx_p', server='hostB', workspace='repo::/w/b8')]
        closed = fw.orphan_terminal_sweep(CONFIG, NOW, fleet, ['', 'hostB'], coordinator_rows)
        self.assertEqual(sorted(closed), ['term_orphan', 'term_orphan_local', 'term_run'])
        self.assertNotIn(COORD, [h for h, _e in fleet.closed()])

    def test_a_host_that_cannot_be_read_is_skipped(self):
        fleet = Fleet(terminals={'hostB': [term('term_o', '#5|fullstack-dev')]})

        def broken(*args):
            if args[:2] == ('orchestration', 'worker-list'):
                raise fw.OrcaReadError('down')
            return fleet(*args)

        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, broken, ['hostB']), [])
        self.assertEqual(fleet.closed(), [])

    def test_a_live_worker_only_on_an_active_page_is_kept(self):
        # The full list is paged (thousands of rows); a running worker past its first page is still found on
        # the second page of the active list.
        fleet = Fleet(terminals={'hostB': [term('term_old_live', '#5|fullstack-dev'), term('term_o', '#6|qa-sdet')]})

        def paged(*args):
            if args[:2] == ('orchestration', 'worker-list'):
                if '--terminal-state' not in args:
                    return {'workers': [], 'nextCursor': 'full2'}
                if '--cursor' not in args:
                    return {'workers': [], 'nextCursor': 'act2'}
                return {'workers': [row('ctx_old', terminal='term_old_live')], 'nextCursor': None}
            return fleet(*args)

        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, paged, ['hostB']), ['term_o'])

    def test_an_active_list_past_the_page_cap_skips_the_host(self):
        fleet = Fleet(terminals={'hostB': [term('term_o', '#5|fullstack-dev')]})

        def endless(*args):
            if args[:2] == ('orchestration', 'worker-list'):
                return {'workers': [], 'nextCursor': 'again'}
            return fleet(*args)

        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, endless, ['hostB']), [])
        self.assertEqual(fleet.closed(), [])


class AskUrgentAfterFiveMinutes(unittest.TestCase):
    def test_ask_older_than_five_minutes_is_urgent_and_waiting(self):
        workers = [{'dispatchId': 'd1', 'dispatchStatus': 'running', 'terminalState': 'active', 'terminal': 'term_d1',
                    'projection': {'host': {'id': 'local'}}}]
        messages = [{'id': 'msg_a', 'type': 'question', 'subject': 'Which?', 'handled': True,
                     'payload': {'dispatchId': 'd1'}}]
        state = {}
        self.assertEqual(fw.unanswered_ask_notices(state, NOW, messages, workers), [])
        notices = fw.unanswered_ask_notices(state, NOW + 5 * 60, messages, workers)
        self.assertEqual(len(notices), 1)
        self.assertIsInstance(notices[0], fw.Urgent)
        self.assertEqual(fw.waiting_on_coordinator(state, workers), {'d1'})


if __name__ == '__main__':
    unittest.main()
