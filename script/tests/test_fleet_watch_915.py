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

    def test_one_start_failure_notifies_once_and_does_not_retry(self):
        with tempfile.TemporaryDirectory() as root:
            state = {}
            notices, lines, _log = self.run_pass(state, 1, root)
            self.assertTrue(any('start-failed' in line for line in lines), lines)
            self.assertEqual(len(notices), 1)
            self.assertIn('o/r#7', notices[0])

            notices, lines, _log = self.run_pass(state, 1, root)
            self.assertEqual(notices, [])
            self.assertTrue(any('parked' in line for line in lines), lines)


class BabysitLiveVerifier(unittest.TestCase):
    def run_pass(self, workers, state=None):
        starts = []
        with tempfile.TemporaryDirectory() as root:
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
            state = {} if state is None else state
            _notices, lines, _log = fw.babysit_pass(
                config, state, workers, pr_fetch=lambda _repo: [pr],
                start_worker=lambda command: starts.append(command) or 0,
                pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
                owner_check=lambda _pr: None,
            )
        return starts, lines, state

    def live_verifier(self, title='qa-sdet - verify PR #7', **extra):
        """A worker-list row as Orca returns it (run_2d30da234f80, trimmed), with the task title fetch_workers joins."""
        row = {
            'dispatchId': 'ctx_e771016f49a0', 'taskId': 'task_aa11bb22cc33', 'runId': 'run_2d30da234f80',
            'workerState': 'ready', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
            'projection': {
                'role': 'worker', 'outcome': 'in_progress', 'provider': None,
                'workspace': {'id': 'wt::/Users/x/orca/workspaces/dotfiles/v972', 'kind': 'folder_or_worktree'},
                'stage': {'worker': 'ready', 'dispatch': 'dispatched', 'detail': 'input_accepted', 'activity': 'working'},
                'liveness': {'verdict': 'live', 'source': 'agent_status'},
            },
            '_task_title': title,
        }
        row.update(extra)
        return row

    def test_live_hand_dispatched_verifier_blocks_a_second_one(self):
        starts, lines, state = self.run_pass([self.live_verifier()])
        self.assertEqual(starts, [])
        self.assertTrue(any('verifier-live' in line for line in lines), lines)
        self.assertNotIn('o/r', state.get('babysit', {}))

    def test_babysit_title_form_blocks_too(self):
        starts, _lines, _state = self.run_pass([self.live_verifier(title='qa-sdet verify o/r#7')])
        self.assertEqual(starts, [])

    def test_finished_verifier_does_not_block(self):
        row = self.live_verifier()
        row['projection']['liveness'] = {'verdict': 'exited'}
        row['dispatchStatus'] = 'completed'
        starts, _lines, _state = self.run_pass([row])
        self.assertEqual(len(starts), 1)

    def test_live_verifier_for_another_pr_does_not_block(self):
        starts, _lines, _state = self.run_pass([self.live_verifier(title='qa-sdet - verify PR #8')])
        self.assertEqual(len(starts), 1)

    def test_live_builder_does_not_block(self):
        starts, _lines, _state = self.run_pass([self.live_verifier(title='fullstack-dev - 7 rework')])
        self.assertEqual(len(starts), 1)

    def test_verifier_skip_is_retried_once_it_finishes(self):
        state = {}
        starts, _lines, _ = self.run_pass([self.live_verifier()], state)
        self.assertEqual(starts, [])
        starts, _lines, _ = self.run_pass([], state)
        self.assertEqual(len(starts), 1)

    def test_fetch_workers_joins_the_task_title_onto_each_row(self):
        row = self.live_verifier()
        del row['_task_title']
        calls = []

        def fake_rpc(*args):
            calls.append(args[:2])
            if args[1] == 'task-list':
                return {'tasks': [{'id': 'task_aa11bb22cc33', 'title': 'qa-sdet - verify PR #7'}]}
            return {'workers': [row]}

        real = fw.rpc
        fw.rpc = fake_rpc
        try:
            workers = fw.fetch_workers({'runs': [{'id': 'run_2d30da234f80'}]})
        finally:
            fw.rpc = real
        self.assertEqual(workers[0]['_task_title'], 'qa-sdet - verify PR #7')
        self.assertTrue(fw.live_verifier_for_pr({'number': 7}, workers))


if __name__ == '__main__':
    unittest.main()


class FakeRun:
    def __init__(self, returncode, stderr):
        self.returncode = returncode
        self.stderr = stderr

    def __call__(self, command, **_kwargs):
        return self


class BabysitStartReason(unittest.TestCase):
    def pass_with(self, state, code, reason, root):
        result = fw.BabysitStartResult(code, reason)
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
            start_worker=lambda _command: result,
            pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
            owner_check=lambda _pr: None,
        )

    def test_default_start_keeps_last_stderr_line(self):
        run = FakeRun(1, 'noise\norca worktree create failed (exit 1)\nbase ref, not found\n\n')
        result = fw.default_babysit_start(['bash', 'x'], run=run)
        self.assertEqual(result, 1)
        self.assertEqual(result.reason, 'base ref not found')

    def test_start_failure_logs_the_reason_and_names_it_in_the_notice(self):
        with tempfile.TemporaryDirectory() as root:
            state = {}
            notices, _lines, log = self.pass_with(state, 1, 'bun install failed in /x', root)
            self.assertIn('start_fail=7:bun install failed in /x', log)
            self.assertEqual(len(notices), 1)
            self.assertIn('bun install failed in /x', notices[0])
            notices, _lines, log = self.pass_with(state, 1, 'bun install failed in /x', root)
            self.assertEqual(notices, [])
            self.assertFalse(any(bit.startswith('start_fail=') for bit in log), log)

    def test_placement_and_usage_gate_refusals_defer_without_a_failure_streak(self):
        with tempfile.TemporaryDirectory() as root:
            for code in (3, 4):
                state = {}
                sent = []
                for _ in range(4):
                    notices, lines, log = self.pass_with(
                        state, code, 'worker-placement: refused local=6/4', root)
                    sent += notices
                    self.assertTrue(any('start-deferred' in line for line in lines), lines)
                    self.assertIn('start_deferred=7:worker-placement: refused local=6/4', log)
                    self.assertFalse(any(bit.startswith('start_fail=') for bit in log), log)
                self.assertEqual(sent, [])
                self.assertNotIn('babysit', state)
