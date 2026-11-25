"""#1849: a worker_done that names a missing ~/agent-state path is held, and no release path frees its worker.

Message shapes come from the coordinator inbox on 2026-11-25 (msg_b19d31db87d8, the incident, and the rejected
remote copy msg_2ab0de70ccf7). The concise view fleet-watch reads cuts a body at 200 characters, so the
incident path (at character 262) is visible only in the --full read.
"""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('fleet_watch', HERE.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
_env_spec = importlib.util.spec_from_file_location('fleet_watch_test_env', HERE / 'fleet_watch_test_env.py')
_fwe = importlib.util.module_from_spec(_env_spec)
_env_spec.loader.exec_module(_fwe)

T0 = 1_700_000_000
RUNS = [{'id': 'run_fixture', 'terminal': 'term_coord', 'waiter_pattern': 'fw-hold-wait'}]
PATCH = 'patches/10143-test-fixture.patch'
INCIDENT = (
    'Wrote the fixture fix for test_production_scripts.py (copies install-pg-backup-r2.sh, adds bin/pg_backup_r2.sh '
    'to the fixture commit, strips ssh -o options in the mock, answers the backup checksum read, and allows that '
    'read in the guard check) and saved it as ~/agent-state/%s (on niteking, copied to mini6). git apply --check '
    'passes on PR head 7218491294 and the pytest file gives 68 passed.' % PATCH
)
PLAIN = 'Fixed the parser and opened PR #99 at head 7218491294; checks pass.'
CUT = '… (truncated; --full)'


def concise(body):
    """Concise inbox view: the body is cut at 200 characters."""
    return body if len(body) <= 200 else body[:200] + CUT


def accepted(mid, dispatch, body):
    return {'id': mid, 'type': 'worker_done', 'from': 'term_w', 'to': 'run:run_fixture', 'subject': 'done',
            'handled': True, 'body': concise(body),
            'payload': {'taskId': 'task_x', 'dispatchId': dispatch, 'outcome': 'succeeded'}}


def rejected_body(dispatch, body):
    return 'Orca rejected this worker_done: worker_done references unknown dispatch %s.\n\nOriginal body:\n%s' % (
        dispatch, body)


def rejected(mid, dispatch, body):
    return {'id': mid, 'type': 'worker_done', 'from': 'term_r', 'to': 'run:run_fixture',
            'subject': 'Rejected worker_done: done', 'priority': 'high', 'handled': True,
            'body': concise(rejected_body(dispatch, body)), 'payload': {'taskId': 'task_x', 'dispatchId': dispatch}}


def local_row(dispatch, pr=99, handle='term_w'):
    return {
        'dispatchId': dispatch, 'taskId': 'task_x', 'runId': 'run_fixture', 'terminalState': 'retained',
        'dispatchStatus': 'dispatched', 'agentTerminalHandle': handle, 'githubPullRequestNumber': pr,
        'title': '#77|fullstack-dev', 'resource': {'worktreeId': 'repo-x::/w/%s' % dispatch},
        'projection': {'host': {'id': 'local'}, 'outcome': 'succeeded', 'liveness': {'verdict': 'idle'}},
    }


def remote_live_row(dispatch, handle='term_remote'):
    row = local_row(dispatch, pr=None, handle=handle)
    row['projection'] = dict(row['projection'], host={'id': 'niteking'})
    return row


def remote_settled_row(dispatch):
    return {'dispatchId': dispatch, 'taskId': 'task_x', 'runId': 'run_fixture', 'workerState': 'succeeded',
            'dispatchStatus': 'completed', 'agentTerminalHandle': None, 'terminalState': None, 'resource': None,
            'server': {'environmentId': 'env-1', 'name': 'niteking'}}


GREEN = {'number': 99, 'state': 'OPEN', 'headRefOid': 'abc',
         'statusCheckRollup': [{'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}]}


class Fleet:
    """Runs fleet-watch main() passes against one state file, with every Orca call recorded."""

    def __init__(self, test, home):
        self.test, self.home = test, Path(home)
        self.agent_state = self.home / 'agent-state'
        self.agent_state.mkdir()
        self.config = self.home / 'config.json'
        self.state_path = self.home / 'state.json'
        self.config.write_text(json.dumps({'runs': RUNS, 'worker_stall': {'label_repo': 'o/r'}}))
        self.state_path.write_text('{}')
        self.calls, self.notices = [], []
        self.full_reads = 0
        self.send_error = False
        self.shown = {}

    def rpc(self, *args):
        self.calls.append(args)
        if args[:2] == ('orchestration', 'inbox') and '--full' in args:
            self.full_reads += 1
            return {'messages': [dict(m, body=self.full[m['id']]) for m in self.messages]}
        if args[:2] == ('orchestration', 'worker-show'):
            return self.shown.get(args[3], {})
        if args[:2] == ('worktree', 'list'):
            return {'worktrees': [{'path': '/w/%s' % d, 'workspaceStatus': 'in-progress'} for d in self.dispatches]}
        if args[:2] == ('terminal', 'send') and self.send_error:
            raise fw.OrcaReadError('terminal_not_found')
        return {}

    def run(self, messages, full, workers, now=T0):
        """One pass. full maps message id to its uncut body (what inbox --full returns)."""
        self.messages, self.full = messages, full
        self.dispatches = [w['dispatchId'] for w in workers]
        self.calls.clear()
        inventory = {'messages': messages, 'workers': workers, 'alive': {'run_fixture': True}, 'leads': {}}
        self.inventory = inventory

        def deliver(_config, _state, notices, *_rest, **_kw):
            self.notices.append(list(notices))

        with _fwe.isolated_main_env(str(self.home)), \
                patch('sys.argv', ['fleet-watch', '--config', str(self.config), '--state', str(self.state_path)]), \
                patch.object(fw, 'AGENT_STATE_DIR', str(self.agent_state)), \
                patch.object(fw, 'rpc', side_effect=self.rpc), \
                patch.object(fw, 'read_orca_inventory', return_value=inventory), \
                patch.object(fw, 'repo_for_worker', return_value='o/r'), \
                patch.object(fw, 'fetch_prs', return_value=[GREEN]), \
                patch.object(fw, 'bounce_builder_dones', return_value=[]), \
                patch.object(fw.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(fw, 'pr_notices', return_value=[]), \
                patch.object(fw, 'usage_notices', return_value=[]), \
                patch.object(fw, 'fleet_pull_after_ship_notices', return_value=[]), \
                patch.object(fw, 'deliver_notices', side_effect=deliver), \
                patch.object(fw.time, 'time', return_value=now):
            fw.main()
        return json.loads(self.state_path.read_text())

    def releases(self):
        return [c for c in self.calls if c[:2] == ('orchestration', 'worker-release')]

    def sends(self):
        return [c for c in self.calls if c[:2] == ('terminal', 'send')]

    def board_sets(self):
        return [c for c in self.calls if c[:2] == ('worktree', 'set')]

    def last_notices(self):
        return [str(n) for n in self.notices[-1]]


class DoneHoldPasses(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        _fwe.guard_gh_writes(self)
        self.fleet = Fleet(self, tmp.name)

    def incident_pass(self, workers, message=None, **kw):
        message = message or accepted('msg_inc', 'ctx_inc', INCIDENT)
        full = {message['id']: (rejected_body('ctx_inc', INCIDENT) if message['body'].startswith('Orca rejected')
                                else INCIDENT)}
        return self.fleet.run([message], full, workers, **kw)

    def test_fixture_matches_the_captured_concise_view(self):
        message = accepted('msg_inc', 'ctx_inc', INCIDENT)
        self.assertTrue(message['body'].endswith(CUT))
        self.assertNotIn('agent-state', message['body'])
        self.assertGreater(INCIDENT.index('~/agent-state'), 200)

    def test_1_local_pr_task_missing_path_is_held_and_told_once(self):
        state = self.incident_pass([local_row('ctx_inc')])
        self.assertEqual(self.fleet.releases(), [])
        self.assertIn(PATCH, state['done_hold']['ctx_inc']['reason'])
        self.assertEqual(state['done_hold']['ctx_inc']['message_id'], 'msg_inc')
        self.assertNotIn('ctx_inc', state.get('auto_released', []))
        sends = self.fleet.sends()
        self.assertEqual(len(sends), 1)
        self.assertEqual(sends[0][3], 'term_w')
        self.assertIn('does not count yet', sends[0][5])
        self.assertNotIn('--environment', sends[0])
        self.assertEqual(state['done_hold_notified'], ['msg_inc'])
        self.assertEqual(self.fleet.full_reads, 1)
        state = self.incident_pass([local_row('ctx_inc')])
        self.assertEqual((self.fleet.releases(), self.fleet.sends(), self.fleet.full_reads), ([], [], 1))
        self.assertIn('ctx_inc', state['done_hold'])

    def test_2_local_no_pr_is_held_and_its_card_stays(self):
        state = self.incident_pass([local_row('ctx_inc', pr=None)])
        self.assertEqual(self.fleet.releases(), [])
        self.assertEqual(self.fleet.board_sets(), [])
        self.assertEqual(state.get('board_done', []), [])
        self.assertIn('ctx_inc', state['done_hold'])

    def test_3_remote_row_notice_names_its_environment(self):
        state = self.incident_pass([remote_live_row('ctx_inc')])
        self.assertEqual(self.fleet.releases(), [])
        sends = self.fleet.sends()
        self.assertEqual(len(sends), 1)
        self.assertEqual(sends[0][3], 'term_remote')
        self.assertEqual(sends[0][-2:], ('--environment', 'niteking'))
        self.assertEqual(state['done_hold_notified'], ['msg_inc'])

    def assert_reconcile_held(self, state):
        self.assertEqual(self.fleet.releases(), [])
        self.assertFalse(any(str(m.get('id', '')).startswith('remote-reconciled:')
                             for m in self.fleet.inventory['messages']))
        self.assertNotIn('ctx_inc', state.get('remote_reconciled', []))
        self.assertFalse(any('finished' in n for n in self.fleet.last_notices()))
        self.assertIn('ctx_inc', state['done_hold'])

    def test_4_reconcile_listed_row_is_not_synthesized_or_released(self):
        state = self.incident_pass([remote_settled_row('ctx_inc')], message=rejected('msg_inc', 'ctx_inc', INCIDENT))
        self.assert_reconcile_held(state)

    def test_5_reconcile_row_from_worker_show_is_not_synthesized_or_released(self):
        self.fleet.shown['ctx_inc'] = {'dispatchId': 'ctx_inc', 'state': 'succeeded', 'status': 'completed',
                                       'server': 'niteking', 'stage': 'server_record'}
        state = self.incident_pass([], message=rejected('msg_inc', 'ctx_inc', INCIDENT))
        self.assertIn(('orchestration', 'worker-show', '--dispatch', 'ctx_inc'), self.fleet.calls)
        self.assert_reconcile_held(state)

    def assert_undelivered_then_retried(self, first_pass_rows):
        state = self.incident_pass(first_pass_rows)
        self.assertIn('ctx_inc', state['done_hold'])
        self.assertEqual(state['done_hold_notified'], [])
        told = [n for n in self.fleet.last_notices() if 'hold on ctx_inc: notice not delivered' in n]
        self.assertEqual(len(told), 1)
        state = self.incident_pass(first_pass_rows)
        self.assertEqual(state['done_hold_notified'], [])
        self.assertFalse(any('notice not delivered' in n for n in self.fleet.last_notices()))
        self.assertEqual(self.fleet.releases(), [])
        return state

    def test_6_no_terminal_handle_is_not_latched_and_retried(self):
        self.assert_undelivered_then_retried([local_row('ctx_inc', handle=None)])
        state = self.incident_pass([local_row('ctx_inc')])
        self.assertEqual(len(self.fleet.sends()), 1)
        self.assertEqual(state['done_hold_notified'], ['msg_inc'])

    def test_7_send_error_is_not_latched_and_retried(self):
        self.fleet.send_error = True
        self.assert_undelivered_then_retried([local_row('ctx_inc')])
        self.assertEqual(len(self.fleet.sends()), 1)  # the second pass tried again
        self.fleet.send_error = False
        state = self.incident_pass([local_row('ctx_inc')])
        self.assertEqual(state['done_hold_notified'], ['msg_inc'])

    def test_8_fixed_resend_clears_the_hold_and_releases(self):
        self.incident_pass([local_row('ctx_inc')])
        (self.fleet.agent_state / 'patches').mkdir()
        (self.fleet.agent_state / PATCH).write_text('patch')
        resend = accepted('msg_fix', 'ctx_inc', INCIDENT)
        state = self.fleet.run([resend, accepted('msg_inc', 'ctx_inc', INCIDENT)],
                               {'msg_fix': INCIDENT, 'msg_inc': INCIDENT}, [local_row('ctx_inc')])
        self.assertEqual(state['done_hold'], {})
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_inc'), self.fleet.releases())
        self.assertEqual(state['auto_released'], ['ctx_inc'])

    def test_8_resend_naming_an_agent_state_commit_clears_the_hold(self):
        self.incident_pass([local_row('ctx_inc')])
        body = INCIDENT + ' Committed to agent-state as 9f8e7d6c5b4a.'
        resend = accepted('msg_fix', 'ctx_inc', body)
        with patch.object(fw, '_agent_state_sha_exists', side_effect=lambda sha: sha == '9f8e7d6c5b4a'):
            state = self.fleet.run([resend], {'msg_fix': body}, [local_row('ctx_inc')])
        self.assertEqual(state['done_hold'], {})
        self.assertEqual(len(self.fleet.releases()), 1)

    def test_9_overdue_hold_is_told_once_and_never_released(self):
        self.incident_pass([local_row('ctx_inc')])
        late = T0 + fw.STALL_IDLE_LIMIT_DEFAULT
        self.incident_pass([local_row('ctx_inc')], now=late)
        overdue = [n for n in self.fleet.notices[-1] if 'no passing worker_done after one stall window' in n]
        self.assertEqual(len(overdue), 1)
        self.assertIsInstance(overdue[0], fw.Urgent)
        state = self.incident_pass([local_row('ctx_inc')], now=late + 60)
        self.assertFalse(any('stall window' in n for n in self.fleet.last_notices()))
        self.assertEqual(self.fleet.releases(), [])
        self.assertIn('ctx_inc', state['done_hold'])

    def test_10_body_without_agent_state_path_releases_as_today(self):
        state = self.fleet.run([accepted('msg_ok', 'ctx_ok', PLAIN)], {'msg_ok': PLAIN}, [local_row('ctx_ok')])
        self.assertEqual(state['done_hold'], {})
        self.assertIn(('orchestration', 'worker-release', '--dispatch', 'ctx_ok'), self.fleet.releases())
        self.assertEqual(self.fleet.full_reads, 0)
        self.assertEqual(self.fleet.sends(), [])


class StallLadderSkipsHeld(unittest.TestCase):
    """Case 9, ladder half: a held live worker past the release windows is neither nudged nor stopped."""

    def test_held_worker_climbs_no_ladder(self):
        calls = []
        row = dict(local_row('ctx_inc', pr=None), projection={'host': {'id': 'local'}, 'outcome': 'in_progress',
                                                              'liveness': {'verdict': 'idle'}})
        state = {'done_hold': {'ctx_inc': {'reason': 'x', 'message_id': 'm', 'since': T0}}}
        config = {'runs': RUNS, 'worker_stall': {'label_repo': 'o/r'}}
        limit = fw.STALL_IDLE_LIMIT_DEFAULT
        start = T0 - limit - 60
        for now in (T0, start + 2 * limit, start + 4 * limit):
            notices, bits = fw.worker_stall_pass(
                config, state, now, [row], {'term_w': int(start * 1000)}, lambda *a: calls.append(a) or {},
                act=lambda argv: 0, head_of=lambda _w: 'sha1', holds_work=lambda _w: False, pr_list=lambda _r: [])
        self.assertEqual(calls, [])
        self.assertEqual(state.get('stall_ladder'), {})


class AgentStateHold(unittest.TestCase):
    def hold(self, body, exists=(), shas=()):
        return fw.agent_state_hold({'type': 'worker_done', 'body': body, 'payload': {'dispatchId': 'd'}},
                                   path_exists=lambda p: p in exists, sha_exists=lambda s: s in shas)

    def test_forms_of_the_path(self):
        for prefix in ('~', '$HOME', '/Users/mtsai', '/home/agent'):
            reason = self.hold('saved %s/agent-state/audits/a.md (on niteking).' % prefix)
            self.assertIn('~/agent-state/audits/a.md,', reason)

    def test_rejected_copy_reads_the_original_body(self):
        self.assertIn(PATCH, self.hold(rejected_body('ctx_inc', INCIDENT)))

    def test_existing_path_passes(self):
        self.assertEqual(self.hold(INCIDENT, exists={os.path.join(fw.AGENT_STATE_DIR, PATCH)}), '')

    def test_pr_head_sha_alone_does_not_pass(self):
        self.assertIn(PATCH, self.hold(INCIDENT))

    def test_cut_body_holds_without_notice_until_read(self):
        state = {}
        message = accepted('msg_inc', 'ctx_inc', INCIDENT)
        fw.update_done_holds(state, [message], [local_row('ctx_inc')], T0, read_full=lambda: None)
        self.assertTrue(state['done_hold']['ctx_inc']['unread'])
        self.assertEqual(fw.send_done_hold_notices(state, [local_row('ctx_inc')], {}, T0, lambda *a: {}), [])
        self.assertFalse(fw.update_done_holds(state, [message], [local_row('ctx_inc')], T0,
                                              read_full=lambda: {'msg_inc': PLAIN}))

    def test_old_mail_for_released_dispatches_raises_no_hold(self):
        state = {'auto_released': ['ctx_inc']}
        fw.update_done_holds(state, [accepted('msg_inc', 'ctx_inc', INCIDENT)], [local_row('ctx_inc')], T0,
                             read_full=lambda: {'msg_inc': INCIDENT})
        self.assertEqual(state['done_hold'], {})


if __name__ == '__main__':
    unittest.main()
