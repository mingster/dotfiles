"""A failed dispatcher start is tried once and parked. Gate refusals retry."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_stall import OLD_MS, T0, base_worker, stall_test_config  # noqa: E402

REPO = 'o/r'
HEAD = 'a' * 40
HEAD_B = 'b' * 40
BRIEF = (
    'Refs o/r#5\n\n'
    '## Acceptance\n'
    '- [ ] prove it\n\n'
    '## Out of scope\n'
    'other files\n\n'
    '## Verify\n'
    'bash script/checks-local.sh\n\n'
    '## Finish\n'
    'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
)


def recorded_worker_start():
    """The #990 worker-start failure. The message is parsed here, not by fleet-watch."""
    fixtures = Path(__file__).parent / 'fixtures' / 'fleet-watch'
    matches = sorted(fixtures.glob('orca-*/worker-start-missing-repo.json'))
    if not matches:
        raise AssertionError('recorded worker-start reply is missing')
    record = json.loads(matches[-1].read_text(encoding='utf-8'))
    payload = json.loads(record['stdout'])
    message = payload['error']['message'].splitlines()[0].strip()
    return record, message


class RecordedReply(unittest.TestCase):
    def test_stdout_error_message_wins_over_a_closing_brace(self):
        record, message = recorded_worker_start()
        reason = fw._start_reason('}\n', record['stdout'])
        self.assertEqual(reason, message)
        self.assertNotEqual(reason, '}')


def failure_result():
    record, message = recorded_worker_start()

    class Proc:
        returncode = record['exit_code']
        stdout = record['stdout']
        stderr = '}\n'

    result = fw.default_babysit_start(['bash', 'startup'], run=lambda *_a, **_k: Proc())
    return result, message


def verifier_pr(head=HEAD):
    return {
        'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'b',
        'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
        'comments': [], 'labels': [], 'mergeable': 'MERGEABLE',
        'body': 'Builder: agent=claude model=sonnet',
    }


class VerifierPark(unittest.TestCase):
    def pass_with(self, state, result, root, head=HEAD, mtime=None):
        config = {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
            'babysit': {'repos': [REPO], 'startup': '/bin/true'},
        }
        if mtime is not None:
            config['config_mtime'] = mtime
        starts = []

        def start_worker(_command):
            starts.append(1)
            return result

        notices, lines, log = fw.babysit_pass(
            config, state, [], pr_fetch=lambda _repo: [verifier_pr(head)],
            start_worker=start_worker,
            pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}},
            owner_check=lambda _pr: None,
        )
        return notices, lines, log, starts

    def test_one_failure_parks_and_a_later_pass_does_not_start(self):
        result, message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {}
            notices, lines, log, starts = self.pass_with(state, result, root, mtime=1)
            self.assertEqual(starts, [1])
            self.assertEqual(len(notices), 1)
            self.assertIn(message, notices[0])
            self.assertIn('o/r#7', notices[0])
            self.assertTrue(any(bit.startswith('start_fail=7:') for bit in log), log)
            self.assertTrue(any('start-failed' in line for line in lines), lines)

            notices, lines, log, starts = self.pass_with(state, result, root, mtime=1)
            self.assertEqual(starts, [])
            self.assertEqual(notices, [])
            self.assertFalse(any(bit.startswith('start_fail=') for bit in log), log)
            self.assertTrue(any('parked' in line for line in lines), lines)

    def test_new_head_rearms(self):
        result, _message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {}
            self.pass_with(state, result, root, mtime=1)
            _notices, _lines, _log, starts = self.pass_with(state, result, root, head=HEAD_B, mtime=1)
            self.assertEqual(starts, [1])

    def test_config_mtime_change_rearms(self):
        result, _message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {}
            self.pass_with(state, result, root, mtime=1)
            _notices, _lines, _log, starts = self.pass_with(state, result, root, mtime=2)
            self.assertEqual(starts, [1])

    def test_gate_refusal_is_logged_and_retried(self):
        result = fw.BabysitStartResult(4, 'worker-placement: refused local=6/4')
        with tempfile.TemporaryDirectory() as root:
            state = {}
            for _ in range(2):
                notices, lines, log, starts = self.pass_with(state, result, root, mtime=1)
                self.assertEqual(starts, [1])
                self.assertEqual(notices, [])
                self.assertTrue(any('start-deferred' in line for line in lines), lines)
                self.assertIn('start_deferred=7:worker-placement: refused local=6/4', log)
            self.assertNotIn('parked', state)


def scan_config(root):
    return {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'pr_repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'agent': 'cursor',
            'model': 'm1',
            'repo_roots': {REPO: root},
        },
        'host_caps': {'local': 4},
        'config_mtime': 1,
    }


def issue_row(number, updated):
    return {
        'number': number,
        'title': 'ticket %d' % number,
        'body': BRIEF,
        'labels': [{'name': 'ready-for-agent'}],
        'comments': [],
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': updated,
    }


def failing_review_pr(number, head):
    return {
        'number': number,
        'state': 'OPEN',
        'isDraft': False,
        'headRefOid': head,
        'headRefName': 'feature/pr',
        'statusCheckRollup': [
            {'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'},
            {'name': 'review', 'status': 'COMPLETED', 'conclusion': 'FAILURE'},
        ],
        'comments': [{'body': 'Checks: PASS head=%s' % head, 'createdAt': '2026-11-05T10:00:00Z'}],
        'labels': [],
    }


class ScanPark(unittest.TestCase):
    def test_rework_failure_parks_until_the_head_or_round_changes(self):
        result, message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            prs = [failing_review_pr(4, HEAD)]
            starts = []

            def start_worker(command):
                starts.append(command)
                return result

            common = dict(
                pr_fetch=lambda _repo: prs,
                list_issues=lambda _repo: [],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
                start_detached=lambda *_a, **_k: 0,
                checks_lock_live=lambda _root: False,
            )
            notices, log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
            self.assertEqual(len(starts), 1, log)
            self.assertTrue(any(message in str(notice) for notice in notices), notices)
            notices, log = fw.issue_scan_pass(scan_config(root), state, 2, [], **common)
            self.assertEqual(len(starts), 1, log)
            self.assertFalse(any(bit.startswith('rework_fail=') for bit in log), log)

            prs[0] = failing_review_pr(4, HEAD_B)
            fw.issue_scan_pass(scan_config(root), state, 3, [], **common)
            self.assertEqual(len(starts), 2, log)

            prs[0] = failing_review_pr(4, HEAD)
            state.setdefault('issue_scan_rework_rounds', {}).setdefault(REPO, {})['4'] = 1
            fw.issue_scan_pass(scan_config(root), state, 4, [], **common)
            self.assertEqual(len(starts), 3, log)

    def test_rework_gate_refusal_retries(self):
        refused = fw.BabysitStartResult(3, 'worker-startup: refused by the usage gate')
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            starts = []

            def start_worker(_command):
                starts.append(1)
                return refused

            common = dict(
                pr_fetch=lambda _repo: [failing_review_pr(4, HEAD)],
                list_issues=lambda _repo: [],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
                start_detached=lambda *_a, **_k: 0,
                checks_lock_live=lambda _root: False,
            )
            for _ in range(2):
                notices, log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
                self.assertEqual(notices, [])
                self.assertIn('rework_deferred=4:worker-startup: refused by the usage gate', log)
            self.assertEqual(starts, [1, 1])
            self.assertNotIn('parked', state)

    def test_issue_failure_parks_until_updated_at_changes_and_does_not_block_the_next(self):
        result, message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            rows = [issue_row(5, '2026-01-01T00:00:00Z'), issue_row(6, '2026-01-02T00:00:00Z')]
            starts = []

            def start_worker(command):
                starts.append(command)
                if 'issue-5' in command:
                    return result
                return 0

            common = dict(
                pr_fetch=lambda _repo: [],
                list_issues=lambda _repo: rows,
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
            )
            notices, _log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
            self.assertEqual(len(starts), 1)
            self.assertIn('issue-5', starts[0])
            self.assertTrue(any(message in str(notice) for notice in notices), notices)
            fw.issue_scan_pass(scan_config(root), state, 2, [], **common)
            self.assertEqual(len(starts), 2)
            self.assertIn('issue-6', starts[1])

            rows[0] = issue_row(5, '2026-01-03T00:00:00Z')
            # 6 is started, so 5 is the only remaining candidate once its edit changes the key.
            state['issue_scan_started'] = {REPO: [6]}
            fw.issue_scan_pass(scan_config(root), state, 3, [], **common)
            self.assertEqual(len(starts), 3)
            self.assertIn('issue-5', starts[2])

    def test_issue_gate_refusal_retries(self):
        refused = fw.BabysitStartResult(4, 'worker-placement: refused local=6/4')
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            starts = []

            def start_worker(_command):
                starts.append(1)
                return refused

            common = dict(
                pr_fetch=lambda _repo: [],
                list_issues=lambda _repo: [issue_row(5, '2026-01-01T00:00:00Z')],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=start_worker,
            )
            for _ in range(2):
                _notices, log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
                self.assertIn('issue_start_deferred=5:worker-placement: refused local=6/4', log)
            self.assertEqual(starts, [1, 1])
            self.assertNotIn('parked', state)

    def test_head_checks_spawn_failure_parks_until_the_head_changes(self):
        result, message = failure_result()
        with tempfile.TemporaryDirectory() as root:
            state = {'issue_scan_backlog_sweep_at': 1}
            prs = [{
                'number': 8, 'state': 'OPEN', 'isDraft': False, 'headRefOid': HEAD,
                'headRefName': 'feature/pr', 'statusCheckRollup': [], 'comments': [], 'labels': [],
            }]
            starts = []

            def start_detached(command, extra_env=None):
                starts.append(command)
                return result

            common = dict(
                pr_fetch=lambda _repo: prs,
                list_issues=lambda _repo: [],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda _command: 0,
                start_detached=start_detached,
                checks_lock_live=lambda _root: False,
            )
            notices, log = fw.issue_scan_pass(scan_config(root), state, 1, [], **common)
            self.assertEqual(len(starts), 1, log)
            self.assertTrue(any('head-checks.sh' in ' '.join(cmd) for cmd in starts))
            self.assertTrue(any(message in str(notice) for notice in notices), notices)
            _notices, log = fw.issue_scan_pass(scan_config(root), state, 2, [], **common)
            self.assertEqual(len(starts), 1, log)
            prs[0] = dict(prs[0], headRefOid=HEAD_B)
            fw.issue_scan_pass(scan_config(root), state, 3, [], **common)
            self.assertEqual(len(starts), 2)


class StallPark(unittest.TestCase):
    def test_failed_restart_parks_with_the_recorded_message(self):
        record, message = recorded_worker_start()
        starts = []

        def rpc(*args):
            if '--retry-of' in args:
                starts.append(args)
                cause = subprocess.CalledProcessError(
                    record['exit_code'], ['orca'], record['stdout'], '}\n')
                err = fw.OrcaReadError('no_active_sender_terminal')
                err.orca_error_code = 'no_active_sender_terminal'
                raise err from cause
            return {}

        worker = base_worker(dispatchId='d1', taskId='t_park', resource={'worktreeId': 'wt::/p'})
        state = {}
        cfg = stall_test_config()
        notices, _bits = fw.worker_stall_pass(cfg, state, T0, [worker], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(len(starts), 1)
        self.assertTrue(any(message in str(notice) and 'd1' in str(notice) for notice in notices), notices)
        notices, bits = fw.worker_stall_pass(cfg, state, T0 + 1, [worker], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(len(starts), 1)
        self.assertEqual(notices, [])
        self.assertFalse(any(bit.startswith('stall_restart_retry=') for bit in bits), bits)

    def test_gate_refusal_retries_the_restart(self):
        starts = []

        def rpc(*args):
            if '--retry-of' in args:
                starts.append(args)
                cause = subprocess.CalledProcessError(
                    3, ['bash'],
                    json.dumps({'ok': False, 'error': {'code': 'usage_gate', 'message': 'refused by the usage gate'}}),
                    '')
                err = fw.OrcaReadError('usage_gate')
                raise err from cause
            return {}

        worker = base_worker(dispatchId='d1', taskId='t_gate', resource={'worktreeId': 'wt::/p'})
        state = {}
        cfg = stall_test_config()
        _notices, bits = fw.worker_stall_pass(cfg, state, T0, [worker], {'term_fix': OLD_MS}, rpc)
        self.assertIn('stall_restart_deferred=d1:refused by the usage gate', bits)
        fw.worker_stall_pass(cfg, state, T0 + 1, [], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(len(starts), 2)
        self.assertNotIn('parked', state)


class PruneClosed(unittest.TestCase):
    def test_closed_pr_and_issue_drop_parked_failed_stall_and_babysit_rows(self):
        state = {
            'parked': {
                'verifier|o/r|7|aaa': {'repo': REPO, 'pr': 7, 'reason': 'x', 'config_mtime': 1},
                'verifier|o/r|8|bbb': {'repo': REPO, 'pr': 8, 'reason': 'y', 'config_mtime': 1},
                'issue|o/r|5|t': {'repo': REPO, 'issue': 5, 'reason': 'z', 'config_mtime': 1},
                'issue|o/r|6|t': {'repo': REPO, 'issue': 6, 'reason': 'z', 'config_mtime': 1},
            },
            'babysit': {REPO: {'7': {'head': HEAD, 'action': 'verifier'}, '8': {'head': HEAD_B, 'action': 'verifier'}}},
            'failed': ['d7', 'd8'],
            'failed_refs': {'d7': {'repo': REPO, 'pr': 7}, 'd8': {'repo': REPO, 'pr': 8}},
            'stall_stopped': {
                'task7': {'dispatch': 'd7', 'repo': REPO, 'pr': 7},
                'task8': {'dispatch': 'd8', 'repo': REPO, 'pr': 8},
            },
        }
        fw.prune_closed_maps(
            state,
            {REPO: [{'number': 7, 'state': 'CLOSED'}, {'number': 8, 'state': 'OPEN'}]},
            {REPO: [{'number': 5, 'state': 'CLOSED'}, {'number': 6, 'state': 'OPEN'}]},
        )
        self.assertNotIn('verifier|o/r|7|aaa', state['parked'])
        self.assertIn('verifier|o/r|8|bbb', state['parked'])
        self.assertNotIn('issue|o/r|5|t', state['parked'])
        self.assertIn('issue|o/r|6|t', state['parked'])
        self.assertNotIn('7', state['babysit'][REPO])
        self.assertIn('8', state['babysit'][REPO])
        self.assertEqual(state['failed'], ['d8'])
        self.assertNotIn('d7', state['failed_refs'])
        self.assertNotIn('task7', state['stall_stopped'])
        self.assertIn('task8', state['stall_stopped'])

    def test_a_failed_fetch_drops_nothing(self):
        state = {
            'parked': {'verifier|o/r|7|aaa': {'repo': REPO, 'pr': 7, 'reason': 'x'}},
            'babysit': {REPO: {'7': {'head': HEAD, 'action': 'verifier'}}},
            'failed': ['d7'],
            'failed_refs': {'d7': {'repo': REPO, 'pr': 7}},
        }
        fw.prune_closed_maps(state, {REPO: None}, {REPO: None})
        self.assertIn('verifier|o/r|7|aaa', state['parked'])
        self.assertIn('7', state['babysit'][REPO])
        self.assertEqual(state['failed'], ['d7'])

    def test_issue_scan_prunes_a_closed_pr_it_listed(self):
        state = {
            'issue_scan_backlog_sweep_at': 1,
            'babysit': {REPO: {'9': {'head': HEAD, 'action': 'verifier'}}},
            'parked': {'verifier|o/r|9|aaa': {'repo': REPO, 'pr': 9, 'reason': 'x', 'config_mtime': 1}},
        }
        with tempfile.TemporaryDirectory() as root:
            fw.issue_scan_pass(
                scan_config(root), state, 1, [],
                pr_fetch=lambda _repo: [{'number': 9, 'state': 'CLOSED'}],
                list_issues=lambda _repo: [],
                gate_check=lambda _c: True,
                admit_fn=lambda *_a: {'admitted': True, 'occupied': 0},
                start_worker=lambda _command: 0,
            )
        self.assertNotIn(REPO, state.get('babysit') or {})
        self.assertNotIn('verifier|o/r|9|aaa', state.get('parked') or {})

    def test_alerts_records_the_pr_so_a_later_close_can_drop_it(self):
        state = {'failed': []}
        worker = {
            'dispatchId': 'd7',
            'dispatchStatus': 'failed',
            'githubPullRequestNumber': 7,
        }
        config = {
            'runs': [{'id': 'r'}],
            'host_caps': {},
            'leads': [],
            'worker_stall': {'label_repo': REPO},
        }
        fw.alerts(config, state, 0, [], [worker], {'r': True})
        self.assertIn('d7', state['failed'])
        self.assertEqual(state['failed_refs']['d7'], {'repo': REPO, 'pr': 7})
        fw.prune_closed_maps(state, {REPO: [{'number': 7, 'state': 'MERGED'}]}, {})
        self.assertEqual(state['failed'], [])


if __name__ == '__main__':
    unittest.main()
