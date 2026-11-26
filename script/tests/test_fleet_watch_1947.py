"""#1947: release closes the terminal on its host, the start_unknown reaper, the orphan terminal sweep, and asks
that are Urgent after 5 minutes."""
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

    def __call__(self, *args):
        self.calls.append(args)
        args = list(args)
        env = ''
        if '--environment' in args:
            i = args.index('--environment')
            env = args[i + 1]
            del args[i:i + 2]
        verb = tuple(args[:2])
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

    def test_a_paged_worker_list_skips_the_host(self):
        fleet = Fleet(terminals={'hostB': [term('term_o', '#5|fullstack-dev')]})

        def paged(*args):
            if args[:2] == ('orchestration', 'worker-list'):
                return {'workers': [], 'nextCursor': 'c2'}
            return fleet(*args)

        self.assertEqual(fw.orphan_terminal_sweep(CONFIG, NOW, paged, ['hostB']), [])


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
