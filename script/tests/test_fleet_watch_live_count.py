"""Live count (#1781): a gone remote dispatch is not live, and a worker question nobody answered is raised."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch_live_count', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

NOW = 1_000_000.0


def remote_row(dispatch, host='niteking'):
    return {'dispatchId': dispatch, 'state': 'ready', 'host': host, 'asOf': '2026-11-24T10:00:00Z'}


def host_rpc(terminals_by_host, shown_by_dispatch, calls=None):
    def call(*args):
        if calls is not None:
            calls.append(args)
        env = args[args.index('--environment') + 1]
        if args[:2] == ('terminal', 'list'):
            return {'terminals': [{'handle': h} for h in terminals_by_host[env]]}
        if args[:2] == ('orchestration', 'worker-show'):
            return {'worker': shown_by_dispatch[args[args.index('--dispatch') + 1]]}
        raise AssertionError(args)
    return call


class GoneRemoteDispatch(unittest.TestCase):
    def setUp(self):
        self.gone = remote_row('ctx_gone')
        self.alive = remote_row('ctx_alive')
        self.rpc = host_rpc(
            {'niteking': ['term_alive']},
            {'ctx_gone': {'dispatchId': 'ctx_gone'}, 'ctx_alive': {'dispatchId': 'ctx_alive', 'terminal': 'term_alive'}},
        )

    def test_ready_row_without_terminal_on_host_is_not_live_and_reported(self):
        state = {}
        notices = fw.gone_remote_dispatch_notices([self.gone, self.alive], state, self.rpc)
        self.assertTrue(fw.worker_row_is_live(self.alive))
        self.assertFalse(fw.worker_row_is_live(self.gone))
        self.assertEqual(fw.active_worker_count([self.gone, self.alive]), 1)
        self.assertEqual(len(notices), 1)
        self.assertIsInstance(notices[0], fw.Urgent)
        self.assertIn('ctx_gone', notices[0])
        self.assertIn('worker-stop', notices[0])

    def test_reported_once_per_dispatch(self):
        state = {}
        fw.gone_remote_dispatch_notices([self.gone], state, self.rpc)
        self.assertEqual(fw.gone_remote_dispatch_notices([self.gone], state, self.rpc), [])
        self.assertFalse(fw.worker_row_is_live(self.gone))

    def test_unreadable_terminal_list_leaves_row_live(self):
        def broken(*args):
            raise fw.OrcaReadError('orca CLI failed')
        notices = fw.gone_remote_dispatch_notices([self.gone], {}, broken)
        self.assertEqual(notices, [])
        self.assertTrue(fw.worker_row_is_live(self.gone))


def ask(mid, dispatch, kind='question', subject='Which option?'):
    return {'id': mid, 'type': kind, 'from': 'term_' + dispatch, 'to': 'run:run_1', 'subject': subject,
            'handled': True, 'payload': {'dispatchId': dispatch}}


def reply(mid, dispatch):
    return {'id': mid, 'type': 'status', 'from': 'peer:coordinator', 'to': 'dispatch:' + dispatch,
            'subject': 'Answer', 'handled': False}


def live_worker(dispatch):
    return {'dispatchId': dispatch, 'dispatchStatus': 'running', 'terminalState': 'active',
            'terminal': 'term_' + dispatch, 'projection': {'host': {'id': 'local'}}}


class UnansweredAsk(unittest.TestCase):
    def test_waits_fifteen_minutes_then_urgent_once_quoting_id_and_subject(self):
        state, workers = {}, [live_worker('d1')]
        messages = [ask('msg_q1', 'd1', 'escalation', 'Blocked: fixture needs a decision')]
        self.assertEqual(fw.unanswered_ask_notices(state, NOW, messages, workers), [])
        self.assertEqual(fw.unanswered_ask_notices(state, NOW + 899, messages, workers), [])
        notices = fw.unanswered_ask_notices(state, NOW + 900, messages, workers)
        self.assertEqual(len(notices), 1)
        self.assertIsInstance(notices[0], fw.Urgent)
        self.assertIn('msg_q1', notices[0])
        self.assertIn('Blocked: fixture needs a decision', notices[0])
        self.assertEqual(fw.unanswered_ask_notices(state, NOW + 5000, messages, workers), [])

    def test_handled_flag_does_not_hide_an_unanswered_ask(self):
        state, workers = {}, [live_worker('d1')]
        messages = [ask('msg_q1', 'd1')]
        self.assertTrue(messages[0]['handled'])
        fw.unanswered_ask_notices(state, NOW, messages, workers)
        self.assertEqual(len(fw.unanswered_ask_notices(state, NOW + 900, messages, workers)), 1)

    def test_reply_to_the_worker_clears_it(self):
        state, workers = {}, [live_worker('d1')]
        messages = [ask('msg_q1', 'd1')]
        fw.unanswered_ask_notices(state, NOW, messages, workers)
        messages = [reply('msg_r1', 'd1')] + messages
        self.assertEqual(fw.unanswered_ask_notices(state, NOW + 2000, messages, workers), [])

    def test_gone_worker_is_not_raised(self):
        state = {}
        messages = [ask('msg_q1', 'd1')]
        fw.unanswered_ask_notices(state, NOW, messages, [])
        self.assertEqual(fw.unanswered_ask_notices(state, NOW + 2000, messages, []), [])


class WorkOrderSplit(unittest.TestCase):
    def test_line_splits_working_and_waiting_on_coordinator(self):
        config = {'work_order': {'min_active': 3, 'target_workers': 8}}
        workers = [live_worker('d1'), live_worker('d2'), live_worker('d3')]
        state = {}
        fw.unanswered_ask_notices(state, NOW, [ask('msg_q1', 'd2')], workers)
        line = fw.work_order_supply_line(config, NOW, workers, 5, waiting=fw.waiting_on_coordinator(state, workers))
        self.assertEqual(line, 'work order: 3 live (2 working, 1 waiting on coordinator), supply 5')


if __name__ == '__main__':
    unittest.main()
