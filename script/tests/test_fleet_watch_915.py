import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HOST_CONFIG = {'host_caps': {'local': 1}}


def row(dispatch, status, **extra):
    return dict({'dispatchId': dispatch, 'dispatchStatus': status}, **extra)


class AdmissionSeats(unittest.TestCase):
    def admit(self, workers):
        return fw.admit('local', HOST_CONFIG, workers=workers)

    def test_failed_exited_and_released_dispatches_hold_no_seat(self):
        workers = [
            row('d1', 'failed'),
            row('d2', 'failed', terminalState='released'),
            row('d3', 'running', liveness='exited', terminalState='released'),
            row('d4', 'released'),
        ]
        receipt = self.admit(workers)
        self.assertTrue(receipt['admitted'], receipt['reason'])
        self.assertEqual(receipt['occupied'], 0)

    def test_live_dispatch_still_holds_the_seat_and_reason_names_it(self):
        receipt = self.admit([row('d1', 'failed'), row('d2', 'running')])
        self.assertFalse(receipt['admitted'])
        self.assertEqual(receipt['occupied'], 1)
        self.assertIn('host cap exceeded', receipt['reason'])


SCAN_CONFIG = {
    'issue_scan': {'enabled': True, 'host': 'local', 'repos': [], 'pr_repos': []},
}


def scan(state, admission):
    return fw.issue_scan_pass(
        SCAN_CONFIG, state, 1_700_000_000.0, [],
        gate_check=lambda _cfg: True,
        admit_fn=lambda _host, _cfg, _workers: admission,
        pr_fetch=lambda _repo: [],
        list_issues=lambda _repo: [],
    )


class RefusalLogAndNotice(unittest.TestCase):
    REFUSED = {'admitted': False, 'reason': 'host cap exceeded: local 4/4'}

    def test_log_names_the_refusal_reason(self):
        _notices, log = scan({}, self.REFUSED)
        self.assertIn('issue_scan_load', log)
        self.assertIn('issue_scan_refused=host cap exceeded: local 4/4', log)

    def test_three_refusals_in_a_row_send_one_notice_until_it_clears(self):
        state = {}
        sent = []
        for _ in range(5):
            sent += scan(state, self.REFUSED)[0]
        self.assertEqual(len(sent), 1)
        self.assertIn('host cap exceeded', sent[0])
        self.assertIsInstance(sent[0], fw.Urgent)

        self.assertEqual(scan(state, {'admitted': True, 'occupied': 0})[0], [])
        again = []
        for _ in range(3):
            again += scan(state, self.REFUSED)[0]
        self.assertEqual(len(again), 1)

    def test_two_refusals_send_nothing(self):
        state = {}
        sent = []
        for _ in range(2):
            sent += scan(state, self.REFUSED)[0]
        self.assertEqual(sent, [])

    def test_admission_between_refusals_resets_the_count(self):
        state = {}
        sent = []
        for admission in (self.REFUSED, self.REFUSED, {'admitted': True, 'occupied': 0}, self.REFUSED, self.REFUSED):
            sent += scan(state, admission)[0]
        self.assertEqual(sent, [])


class CurrentSenderHandle(unittest.TestCase):
    def config(self):
        return {
            'runs': [{'id': 'run_live', 'terminal': 'term_old'}],
            'issue_scan': {'enabled': False, 'run': 'run_x', 'from_terminal': 'term_old'},
            'babysit': {'from_terminal': 'term_old'},
        }

    def test_commands_send_as_the_runs_current_coordinator(self):
        config = self.config()
        asked = []

        def resolve(run_id):
            asked.append(run_id)
            return 'term_new'

        fw.apply_active_run(config, resolve_handle=resolve)
        self.assertEqual(asked, ['run_live'])
        self.assertEqual(config['issue_scan']['from_terminal'], 'term_new')
        self.assertEqual(config['babysit']['from_terminal'], 'term_new')
        self.assertEqual(fw.terminal_handle_for_configured_run(config, 'run_live'), 'term_new')
        _startup, _run, from_terminal, _roots = fw.babysit_settings(config)
        self.assertEqual(from_terminal, 'term_new')

    def test_unreadable_run_keeps_the_saved_handle(self):
        config = self.config()
        fw.apply_active_run(config, resolve_handle=lambda _run: None)
        self.assertEqual(config['issue_scan']['from_terminal'], 'term_old')

    def test_resolver_reads_coordinator_handle_from_run_list(self):
        pages = [{'runs': [
            {'id': 'run_a', 'coordinator_handle': 'term_a'},
            {'id': 'run_live', 'coordinator_handle': 'term_new'},
        ]}]
        original = fw.list_pages
        fw.list_pages = lambda *command: iter(pages)
        try:
            self.assertEqual(fw.current_coordinator_handle('run_live'), 'term_new')
            self.assertIsNone(fw.current_coordinator_handle('run_missing'))
        finally:
            fw.list_pages = original

    def test_resolver_returns_none_when_orca_fails(self):
        def boom(*command):
            raise fw.OrcaReadError('down')

        original = fw.list_pages
        fw.list_pages = boom
        try:
            self.assertIsNone(fw.current_coordinator_handle('run_live'))
        finally:
            fw.list_pages = original


HEAD = 'a' * 40


class BabysitStartFailureNotice(unittest.TestCase):
    def run_pass(self, state, rc, root):
        config = {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {'o/r': root}},
            'babysit': {'repos': ['o/r'], 'startup': '/bin/true'},
        }
        pr = {
            'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': HEAD, 'headRefName': 'b',
            'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
            'comments': [], 'labels': [], 'mergeable': 'MERGEABLE',
            'body': 'Builder: agent=claude model=sonnet',
        }
        return fw.babysit_pass(
            config, state, [], pr_fetch=lambda _repo: [pr],
            start_worker=lambda _command: rc,
            pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
            owner_check=lambda _pr: None,
        )

    def test_three_start_failures_send_one_notice_until_a_start_works(self):
        with tempfile.TemporaryDirectory() as root:
            state = {}
            sent = []
            for _ in range(4):
                notices, lines, _log = self.run_pass(state, 1, root)
                self.assertTrue(any('start-failed' in line for line in lines), lines)
                sent += notices
            self.assertEqual(len(sent), 1)
            self.assertIn('o/r#7', sent[0])

            notices, _lines, _log = self.run_pass(state, 0, root)
            self.assertEqual(notices, [])
            self.assertNotIn('babysit_start_failed', state['failure_streaks'])


if __name__ == '__main__':
    unittest.main()
