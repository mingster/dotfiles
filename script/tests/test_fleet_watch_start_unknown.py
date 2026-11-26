"""#1962: the start_unknown reaper, on #1958's fleet_rows and release_worker."""
import copy
import json
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
import fleet_watch_test_env  # noqa: F401  keeps log lines off ~/.orca/logs (#1864)

spec = importlib.util.spec_from_file_location('fleet_watch_start_unknown', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

FIXTURE = json.loads((Path(__file__).parent / 'fixtures' / 'agy-signin-stopped-remote.json').read_text())
COORD = 'term_4d505f31-1274-4bd4-96a9-4c3943f89629'
NOW = 2_000_000
CONFIG = {'runs': [{'id': 'run_1', 'terminal': COORD}]}


class Fleet:
    """Fake orca: per host terminal and worker lists, briefs by task. Records every call."""

    def __init__(self, terminals=None, workers=None, briefs=None):
        self.terminals = terminals or {}
        self.workers = workers or {}
        self.briefs = briefs or {}
        self.calls = []
        self.fail = set()

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
            raise fw.OrcaReadError('host unreachable')
        if verb == ('terminal', 'list'):
            return {'terminals': list(self.terminals.get(env, []))}
        if verb == ('orchestration', 'worker-list'):
            return {'workers': [] if '--terminal-state' in args else list(self.workers.get(env, []))}
        if verb == ('orchestration', 'worker-show'):
            return {'worker': {}}
        if verb == ('orchestration', 'dispatch-show'):
            return {'preamble': self.briefs.get(args[args.index('--task') + 1], '')}
        if verb == ('terminal', 'close'):
            handle = args[args.index('--terminal') + 1]
            self.terminals[env] = [t for t in self.terminals.get(env, []) if t['handle'] != handle]
        return {}

    def sends(self):
        return [c for c in self.calls if c[:2] == ('terminal', 'send')]


def local_row(did, state='start_unknown', terminal='', **extra):
    row = {'dispatchId': did, 'taskId': 'task_' + did, 'state': state, 'terminal': terminal, 'terminalState': 'active'}
    fw._set_row_host(row, {})
    row.update(extra)
    return row


class Base(unittest.TestCase):
    def setUp(self):
        fw._PROTECTED_HANDLES.clear()
        fw._LIVE_TERMINALS.clear()
        fw._UNREAD_WORKER_HOSTS.clear()
        self.addCleanup(fw._PROTECTED_HANDLES.clear)
        self.addCleanup(fw._LIVE_TERMINALS.clear)
        self.addCleanup(fw._UNREAD_WORKER_HOSTS.clear)


class StartUnknownReaper(Base):
    def reaper(self, config, state, rows, fleet, release_result='closed', edits=None):
        released = []

        def release(row):
            released.append(row['dispatchId'])
            return release_result() if callable(release_result) else release_result

        def reap(t):
            return fw.start_unknown_reaper(config, state, t, rows() if callable(rows) else rows, fleet, release,
                                           act=lambda c: (edits.append(c) if edits is not None else None) or 0)
        return reap, released

    def test_resend_at_10_then_release_and_issue_back_at_20(self):
        rows = [local_row('ctx_u', terminal='term_u', _task_title='#77|fullstack-dev', _repo='o/r')]
        fleet = Fleet(briefs={'task_ctx_u': 'BRIEF TEXT'})
        edits, state = [], {}
        reap, released = self.reaper(CONFIG, state, rows, fleet, edits=edits)
        self.assertEqual(reap(NOW), [])
        self.assertEqual(reap(NOW + 599), [])
        self.assertEqual(fleet.sends(), [])
        self.assertEqual(reap(NOW + 600), [])
        self.assertEqual(len(fleet.sends()), 1)
        self.assertIn('BRIEF TEXT', fleet.sends()[0])
        self.assertIn('term_u', fleet.sends()[0])
        self.assertEqual(reap(NOW + 1199), [])
        self.assertEqual(released, [])
        notices = reap(NOW + 1200)
        self.assertEqual(released, ['ctx_u'])
        self.assertEqual(len(notices), 1)
        self.assertIsInstance(notices[0], fw.Urgent)
        self.assertIn('o/r#77 back to ready-for-agent', notices[0])
        self.assertEqual(edits, [['gh', 'issue', 'edit', '77', '--repo', 'o/r', '--add-label', 'ready-for-agent',
                                  '--remove-label', fw.ISSUE_CLAIM_LABEL]])
        self.assertEqual(reap(NOW + 3000), [])
        self.assertEqual(released, ['ctx_u'])
        self.assertEqual(len(fleet.sends()), 1)

    def test_fixture_remote_row_through_fleet_rows_resends_and_releases_on_its_host(self):
        # The coordinator's --full row says ready; the host's own row says start_unknown (#1958 fixture).
        stub = FIXTURE['worker_list_full_row_started']
        env_id = stub['server']['environmentId']
        hosted = FIXTURE['worker_list_host_row_start_unknown']
        fleet = Fleet(workers={'host-b': [hosted]}, briefs={stub['taskId']: 'BRIEF'})
        state = {}
        with patch.object(fw, 'environment_name_by_id', return_value={env_id: 'host-b'}):
            def rows():
                return fw.fleet_rows(CONFIG, [dict(copy.deepcopy(stub), _task_title='#77|fullstack-dev')],
                                     ['', 'host-b'], fleet)
            reap, released = self.reaper(CONFIG, state, rows, fleet)
            reap(NOW)
            reap(NOW + 600)
            sends = fleet.sends()
            self.assertEqual(len(sends), 1)
            self.assertIn(hosted['terminal'], sends[0])
            self.assertEqual(sends[0][sends[0].index('--environment') + 1], env_id)
            notices = reap(NOW + 1200)
        self.assertEqual(released, [stub['dispatchId']])
        self.assertEqual(len(notices), 1)
        self.assertIn('repo unknown here', notices[0])

    def test_an_unread_host_row_is_skipped(self):
        rows = [local_row('ctx_x', terminal='term_x', _host='env-b', _host_read=False)]
        state = {}
        reap, released = self.reaper(CONFIG, state, rows, Fleet(briefs={'task_ctx_x': 'B'}))
        reap(NOW)
        reap(NOW + 600)
        reap(NOW + 1200)
        self.assertEqual(released, [])
        self.assertNotIn('ctx_x', state.get('start_unknown', {}))

    def test_an_unread_pass_keeps_the_clock_and_the_stall_protection(self):
        rows = [local_row('ctx_k', terminal='term_k', _host='env-b')]
        state = {}
        reap, released = self.reaper(CONFIG, state, lambda: rows, Fleet(briefs={'task_ctx_k': 'B'}))
        reap(NOW)
        reap(NOW + 600)
        rows[0]['_host_read'] = False
        reap(NOW + 900)
        self.assertEqual(state['start_unknown']['ctx_k']['at'], NOW)
        self.assertIn('ctx_k', fw.reaper_owned(state))
        rows[0]['_host_read'] = True
        reap(NOW + 1200)
        self.assertEqual(released, ['ctx_k'])

    def test_a_late_resend_gets_ten_minutes_before_the_release(self):
        rows = [local_row('ctx_l', terminal='term_l')]
        fleet = Fleet(briefs={'task_ctx_l': 'B'})
        state = {}
        reap, released = self.reaper(CONFIG, state, rows, fleet)
        reap(NOW)
        fleet.fail = {('terminal', 'send')}
        reap(NOW + 600)
        fleet.fail = set()
        reap(NOW + 1150)
        reap(NOW + 1200)
        reap(NOW + 1749)
        self.assertEqual(released, [])
        reap(NOW + 1750)
        self.assertEqual(released, ['ctx_l'])

    def test_a_failed_resend_or_release_is_tried_again(self):
        rows = [local_row('ctx_r', terminal='term_r')]
        fleet = Fleet(briefs={'task_ctx_r': 'B'})
        state = {}
        result = ['failed']
        reap, released = self.reaper(CONFIG, state, rows, fleet, release_result=lambda: result[0])
        reap(NOW)
        fleet.fail = {('terminal', 'send')}
        reap(NOW + 600)
        self.assertNotIn('resent_at', state['start_unknown']['ctx_r'])
        fleet.fail = set()
        reap(NOW + 660)
        self.assertEqual(state['start_unknown']['ctx_r']['resent_at'], NOW + 660)
        self.assertEqual(reap(NOW + 1260), [])
        self.assertFalse(state['start_unknown']['ctx_r'].get('reaped'))
        result[0] = 'kept:no_handle'
        self.assertEqual(len(reap(NOW + 1320)), 1)
        self.assertTrue(state['start_unknown']['ctx_r']['reaped'])
        self.assertEqual(released, ['ctx_r', 'ctx_r'])

    def test_a_kept_coordinator_terminal_is_not_booked_reaped(self):
        rows = [local_row('ctx_k', terminal='term_k')]
        state = {}
        reap, released = self.reaper(CONFIG, state, rows, Fleet(briefs={'task_ctx_k': 'B'}), release_result='kept:coordinator')
        reap(NOW)
        reap(NOW + 600)
        self.assertEqual(reap(NOW + 1200), [])
        self.assertFalse(state['start_unknown']['ctx_k'].get('reaped'))

    def test_an_issue_with_a_pr_is_not_relabelled(self):
        rows = [local_row('ctx_p', terminal='term_p', _task_title='#77|fullstack-dev', _repo='o/r', prNumber=88)]
        edits, state = [], {}
        reap, _ = self.reaper(CONFIG, state, rows, Fleet(briefs={'task_ctx_p': 'B'}), edits=edits)
        reap(NOW)
        reap(NOW + 600)
        notices = reap(NOW + 1200)
        self.assertEqual(edits, [])
        self.assertEqual(len(notices), 1)

    def test_a_worker_that_starts_leaves_the_book(self):
        state = {}
        fleet = Fleet(briefs={'task_ctx_s': 'B'})
        fw.start_unknown_reaper(CONFIG, state, NOW, [local_row('ctx_s', terminal='term_s')], fleet, lambda r: 'closed')
        fw.start_unknown_reaper(CONFIG, state, NOW + 700, [local_row('ctx_s', 'running', 'term_s')], fleet,
                                lambda r: 'closed')
        self.assertEqual(state['start_unknown'], {})

    def test_stall_ladder_leaves_reaper_dispatches_alone(self):
        state = {}
        fw.start_unknown_reaper(CONFIG, state, NOW, [local_row('ctx_s')], Fleet(), lambda r: 'closed')
        self.assertEqual(fw.reaper_owned(state), {'ctx_s'})

    def test_main_runs_reap_after_idle_seat_and_before_babysit(self):
        source = (Path(__file__).parent.parent / 'fleet-watch.py').read_text()
        body = source[source.index('\ndef _main('):]
        idle = body.index("run_phase('idle_seat'")
        reap = body.index("run_phase('reap'")
        babysit = body.index("pass_phase('babysit')")
        self.assertLess(idle, reap)
        self.assertLess(reap, babysit)
        self.assertIn('reaper_owned(state)', body[body.index("run_phase('stall'"):])


if __name__ == '__main__':
    unittest.main()
