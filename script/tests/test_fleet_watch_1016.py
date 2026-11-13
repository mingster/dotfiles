import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

REPO = 'owner/app'
NOW = 1_700_000_000.0
HEAD = 'a' * 40
ENV_NITE = '11111111-2222-4333-8444-555555555555'
ENV_COORD = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
VALID_BRIEF = (
    'Refs owner/app#9\n\n'
    '## Acceptance\n'
    '- [ ] prove it\n\n'
    '## Out of scope\n'
    'other files\n\n'
    '## Verify\n'
    'bash script/checks-local.sh\n\n'
    '## Finish\n'
    'Self-review, run orca worktree set --worktree active --workspace-status in-review, then worker_done.\n'
)


def issue(number, labels, body, created='2026-01-01T00:00:00Z'):
    return {
        'number': number,
        'title': 'ticket %d' % number,
        'body': body,
        'labels': [{'name': name} for name in labels],
        'comments': [],
        'createdAt': created,
    }


def checks(conclusion='SUCCESS'):
    return [{
        'name': 'checks', 'status': 'COMPLETED', 'conclusion': conclusion, 'isRequired': True,
    }]


def ready_pr(number, head, mergeable='MERGEABLE'):
    return {
        'number': number, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head,
        'headRefName': 'ready-%d' % number, 'mergeable': mergeable,
        'statusCheckRollup': checks(),
        'comments': [{'body': 'Verdict: PASS head=%s verifier=ctx_v author=ctx_a' % head}],
        'labels': [],
    }


def scan_config(caps, root='/tmp/app'):
    return {
        'issue_scan': {
            'enabled': True,
            'repos': [REPO],
            'run': 'run_x',
            'from_terminal': 'term_coord',
            'host': 'local',
            'agent': 'cursor',
            'model': 'm1',
            'rework_agent': 'cursor',
            'rework_model': 'm1',
            'repo_roots': {REPO: root},
        },
        'host_caps': caps,
    }


class HeadOfLineLint(unittest.TestCase):
    def test_lint_failure_drops_ready_and_starts_the_next_issue(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        bad = issue(1, ['ready-for-agent', 'P0'], '## Acceptance criteria\n- prove it')
        good = issue(2, ['ready-for-agent'], VALID_BRIEF, created='2026-01-02T00:00:00Z')
        starts = []
        gh_calls = []

        def act(command):
            gh_calls.append(command)
            return 0

        _notices, log = fw.issue_scan_pass(
            scan_config({'local': 4}), state, NOW, [],
            list_issues=lambda _repo: [bad, good],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
            act=act,
        )
        edits = [c for c in gh_calls if c[:3] == ['gh', 'issue', 'edit']]
        self.assertEqual(len(edits), 1, gh_calls)
        self.assertIn('--remove-label', edits[0])
        self.assertIn('ready-for-agent', edits[0])
        self.assertIn('needs-triage', edits[0])
        self.assertEqual(edits[0][3], '1')
        self.assertIn('issue_needs_triage=1', log)
        self.assertEqual(len(starts), 1, log)
        self.assertIn('issue-2', starts[0])
        self.assertIn('issue_start=2', log)


class RemotePlacementWhenLocalIsFull(unittest.TestCase):
    def test_occupied_local_starts_on_the_admitted_remote(self):
        state = {'issue_scan_backlog_sweep_at': NOW}
        starts = []
        calls = []

        def admit(host, _config, _workers):
            calls.append(host)
            if host == 'local':
                return {'admitted': False, 'occupied': 4, 'reason': 'host cap exceeded: local 4/4'}
            return {'admitted': True, 'occupied': 0, 'reason': 'admitted'}

        _notices, log = fw.issue_scan_pass(
            scan_config({'local': 4, 'hostB': 4}), state, NOW, [],
            list_issues=lambda _repo: [issue(9, ['ready-for-agent'], VALID_BRIEF)],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
            repo_id_lookup=lambda host, _repo: 'repo-on-%s' % host,
        )
        self.assertEqual(calls, ['local', 'hostB'])
        self.assertEqual(len(starts), 1, log)
        self.assertIn('--on', starts[0])
        self.assertEqual(starts[0][starts[0].index('--on') + 1], 'hostB')
        self.assertIn('id:repo-on-hostB', starts[0])
        self.assertIn('issue_start=9', log)


class ShipWhileLocalIsFull(unittest.TestCase):
    def test_unknown_mergeable_is_ready(self):
        row = ready_pr(3, HEAD, 'UNKNOWN')
        self.assertEqual(fw.classify_open_pr(row), 'ready')

    def test_refused_local_still_logs_ship_start(self):
        state = {}
        starts = []

        def admit(host, _config, _workers):
            if host == 'local':
                return {'admitted': False, 'occupied': 4, 'reason': 'host cap exceeded: local 4/4'}
            return {'admitted': True, 'occupied': 0, 'reason': 'admitted'}

        _notices, log = fw.issue_scan_pass(
            scan_config({'local': 4, 'hostB': 4}), state, NOW, [],
            list_issues=lambda _repo: [],
            pr_fetch=lambda _repo: [ready_pr(3, HEAD, 'UNKNOWN')],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda cmd: (starts.append(cmd), 0)[1],
        )
        self.assertIn('ship_start=%s' % HEAD[:8], log)
        self.assertEqual(len(starts), 1)

    def test_refused_local_with_nowhere_else_still_ships(self):
        state = {}
        _notices, log = fw.issue_scan_pass(
            scan_config({'local': 4}), state, NOW, [],
            list_issues=lambda _repo: [issue(9, ['ready-for-agent'], VALID_BRIEF)],
            pr_fetch=lambda _repo: [ready_pr(4, HEAD, 'MERGEABLE')],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': False, 'occupied': 4, 'reason': 'host cap exceeded: local 4/4'},
            start_worker=lambda _cmd: 0,
        )
        self.assertIn('ship_start=%s' % HEAD[:8], log)
        self.assertNotIn('issue_start=9', log)


class ConflictReworkRounds(unittest.TestCase):
    def test_conflict_only_rework_does_not_count_a_round(self):
        conflict_head = 'c' * 40
        fail_head = 'f' * 40
        conflict = {
            'number': 8, 'state': 'OPEN', 'isDraft': False, 'headRefOid': conflict_head,
            'headRefName': 'conflict', 'mergeable': 'CONFLICTING',
            'statusCheckRollup': checks(),
            'comments': [{'body': 'Checks: PASS head=%s' % conflict_head}],
            'labels': [],
        }
        failed = {
            'number': 9, 'state': 'OPEN', 'isDraft': False, 'headRefOid': fail_head,
            'headRefName': 'red', 'mergeable': 'MERGEABLE',
            'statusCheckRollup': checks('FAILURE'),
            'comments': [{'body': 'Checks: FAIL head=%s' % fail_head}],
            'labels': [],
        }
        state = {'issue_scan_backlog_sweep_at': NOW}
        _notices, log = fw.issue_scan_pass(
            scan_config({'local': 4}), state, NOW, [],
            list_issues=lambda _repo: [],
            pr_fetch=lambda _repo: [conflict, failed],
            gate_check=lambda _c: True,
            admit_fn=lambda _h, _c, _w: {'admitted': True, 'occupied': 0},
            start_worker=lambda _cmd: 0,
        )
        rounds = state['issue_scan_rework_rounds'][REPO]
        self.assertNotIn('8', rounds)
        self.assertEqual(rounds.get('9'), 1)
        self.assertIn('rework_start=%s' % conflict_head[:8], log)
        self.assertIn('rework_start=%s' % fail_head[:8], log)


class EnvironmentHostIds(unittest.TestCase):
    """A concise remote row's host string is an environment id, not "local".

    environment list maps that id to the host_caps name. Full rows use
    projection.host {kind: remote, id: <environment id>}. A missing host is
    the local seat. The real worker-list row is in the pull request, not here.
    """

    def config(self):
        return {
            'local_host': 'coord-box',
            'host_caps': {'coord-box': 1, 'host-b': 1, 'host-c': 2},
        }

    def test_environment_list_maps_id_to_name(self):
        def call(*args):
            self.assertEqual(args, ('environment', 'list'))
            return {'environments': [
                {'id': ENV_COORD, 'name': 'host-b'},
                {'id': '', 'name': 'skip'},
                'not-a-row',
            ]}

        self.assertEqual(fw.environment_name_by_id(call), {ENV_COORD: 'host-b'})

    def test_environment_id_counts_on_the_named_host(self):
        workers = [{
            'dispatchId': 'ctx_remote_row',
            'dispatchStatus': 'running',
            'host': ENV_COORD,
        }]
        names = {ENV_COORD: 'host-b', ENV_NITE: 'host-d'}
        config = self.config()
        local = fw.admit('local', config, workers, env_names=names)
        named = fw.admit('host-b', config, workers, env_names=names)
        self.assertEqual(local['occupied'], 0, local)
        self.assertEqual(named['occupied'], 1, named)
        self.assertFalse(named['admitted'])

    def test_full_named_host_is_not_the_overflow_target(self):
        workers = [{
            'dispatchId': 'ctx_nite',
            'dispatchStatus': 'running',
            'projection': {'role': 'builder', 'host': {'kind': 'remote', 'id': ENV_NITE}},
        }]
        config = {
            'local_host': 'coord-box',
            'host_caps': {'coord-box': 4, 'host-d': 1, 'host-c': 2},
        }
        names = {ENV_NITE: 'host-d'}
        with patch.dict(os.environ, {
            'FLEET_WATCH_TEST_LOAD_PER_CORE': '0.85',
            'FLEET_WATCH_TEST_FREE_GB': '12',
        }):
            receipt = fw.admit('local', config, workers, env_names=names)
        self.assertFalse(receipt['admitted'], receipt)
        self.assertEqual(receipt['occupied'], 0)
        self.assertEqual(receipt['overflow_host'], 'host-c')

    def test_missing_host_still_counts_on_local(self):
        workers = [{
            'dispatchId': 'ctx_local',
            'dispatchStatus': 'running',
            'projection': {'role': 'builder'},
        }]
        receipt = fw.admit('coord-box', self.config(), workers, env_names={})
        self.assertEqual(receipt['occupied'], 1)


class GreenSuccessRelease(unittest.TestCase):
    def worker(self, root, dispatch='ctx_done', number=3):
        return {
            'dispatchId': dispatch,
            'dispatchStatus': 'completed',
            'terminalState': 'retained',
            'githubPullRequestNumber': number,
            'projection': {
                'workspace': {'path': root},
                'host': {'id': 'local'},
                'outcome': 'succeeded',
            },
        }

    def release(self, worker, pr_row, outcome='succeeded'):
        released = []
        state = {}
        config = {
            'local_host': 'coord-box',
            'host_caps': {'coord-box': 1},
            'issue_scan': {'repo_roots': {REPO: worker['projection']['workspace']['path']}},
        }
        before = fw.admit('local', config, [worker], env_names={})
        messages = [{
            'type': 'worker_done',
            'outcome': outcome,
            'payload': {'dispatchId': worker['dispatchId']},
        }]
        done = fw.release_green_successes(
            messages, [worker], config, state, released.append,
            lambda repo, number: pr_row if repo == REPO and number == pr_row.get('number') else None,
        )
        after = fw.admit('local', config, [worker], env_names={})
        return before, done, released, after, state

    def test_succeeded_worker_with_green_checks_frees_the_seat_once(self):
        with tempfile.TemporaryDirectory() as root:
            worker = self.worker(root)
            before, done, released, after, state = self.release(worker, ready_pr(3, HEAD))
        self.assertEqual(before['occupied'], 1)
        self.assertEqual(done, ['ctx_done'])
        self.assertEqual(released, ['ctx_done'])
        self.assertEqual(after['occupied'], 0)
        self.assertEqual(state['auto_released'], ['ctx_done'])
        again = []
        fw.release_green_successes(
            [{'type': 'worker_done', 'outcome': 'succeeded', 'payload': {'dispatchId': 'ctx_done'}}],
            [worker], {'issue_scan': {'repo_roots': {REPO: root}}}, state, again.append,
            lambda _repo, _number: ready_pr(3, HEAD),
        )
        self.assertEqual(again, [])

    def test_red_checks_and_a_failed_outcome_stay_occupied(self):
        with tempfile.TemporaryDirectory() as root:
            red = ready_pr(3, HEAD)
            red['statusCheckRollup'] = checks('FAILURE')
            red_worker = self.worker(root)
            before, done, released, after, _state = self.release(red_worker, red)
            self.assertEqual(before['occupied'], 1)
            self.assertEqual(done, [])
            self.assertEqual(released, [])
            self.assertEqual(after['occupied'], 1)
            failed = self.worker(root, dispatch='ctx_fail')
            _before, done, released, after, _state = self.release(failed, ready_pr(3, HEAD), outcome='failed')
        self.assertEqual(done, [])
        self.assertEqual(released, [])
        self.assertEqual(after['occupied'], 1)


class QuietFailedDigest(unittest.TestCase):
    def test_skips_alerted_released_and_settled_failures(self):
        config = {
            'host_caps': {},
            'runs': [{'id': 'r1', 'terminal': 'term_coord'}],
            'leads': [],
        }
        already = {'dispatchId': 'ctx_old', 'dispatchStatus': 'failed', 'terminalState': 'retained'}
        live = {
            'dispatchId': 'ctx_new', 'dispatchStatus': 'failed', 'terminalState': 'retained',
            'projection': {
                'liveness': {'verdict': 'exited'},
                'stage': {'detail': 'process_stopped'},
                'outcome': 'failed',
            },
        }
        released = {
            'dispatchId': 'ctx_rel', 'dispatchStatus': 'failed',
            'terminalState': 'released', 'released': True,
        }
        settled = {
            'dispatchId': 'ctx_set', 'dispatchStatus': 'failed', 'terminalState': 'retained',
            'projection': {'stage': {'detail': 'settled'}, 'outcome': 'failed'},
        }
        workers = [already, live, released, settled]
        state = {'failed': ['ctx_old']}
        notices = fw.alerts(config, state, NOW, [], workers, {'r1': True})
        texts = [str(notice) for notice in notices]
        self.assertTrue(any('ctx_new' in text for text in texts), texts)
        self.assertFalse(any('ctx_rel' in text or 'ctx_set' in text or 'ctx_old' in text for text in texts), texts)
        sent = []
        fw.deliver_notices(config, {}, notices, rpc_call=lambda *args: sent.append(args), now=NOW)
        body = sent[0][sent[0].index('--body') + 1]
        self.assertIn('ctx_new', body)
        self.assertNotIn('ctx_rel', body)
        self.assertNotIn('ctx_set', body)
        self.assertNotIn('ctx_old', body)
        again = fw.alerts(config, state, NOW + 60, [], workers, {'r1': True})
        self.assertFalse(any('failed dispatch' in str(notice) for notice in again), again)
        self.assertIn('ctx_rel', state['failed'])
        self.assertIn('ctx_set', state['failed'])
        self.assertIn('ctx_new', state['failed'])


if __name__ == '__main__':
    unittest.main()
