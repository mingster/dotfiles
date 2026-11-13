import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_stall import OLD_MS, T0, base_worker, stall_test_config  # noqa: E402

REPO = 'owner/app'
HEAD = 'ab' * 20
NOW = float(T0)


def recorded(name):
    """Load one #990-style reply. Tests do not build an Orca body inline."""
    root = Path(__file__).parent / 'fixtures' / 'fleet-watch'
    matches = sorted(root.glob('orca-*/%s.json' % name))
    if not matches:
        raise AssertionError('recorded reply %s is missing under %s' % (name, root))
    return json.loads(matches[-1].read_text(encoding='utf-8'))


def recorded_body(name):
    raw = recorded(name)
    text = (raw.get('stdout') or raw.get('stderr') or '').strip()
    return json.loads(text)


def recorded_result(name):
    body = recorded_body(name)
    if body.get('ok') is False:
        code = body['error']['code']
        err = fw.OrcaReadError(code)
        err.orca_error_code = code
        raise err
    result = body.get('result')
    return result if isinstance(result, dict) else {}


def recorded_dispatch_id(name='stall-worker-start-ok'):
    return recorded_result(name)['dispatchId']


def start_handle(name='stall-worker-start-ok'):
    return fw.BabysitStartResult(recorded(name)['exit'], '', recorded_dispatch_id(name))


def own_worker(**kw):
    w = base_worker(**kw)
    return w


def mark_own(state, *ids, kind='verifier'):
    bucket = state.setdefault('own_dispatches', {})
    for did in ids:
        bucket.setdefault(did, {'kind': kind})
    return state


class RecordedStartReplies(unittest.TestCase):
    def test_start_parsers_read_the_recorded_dispatch_id(self):
        raw = recorded('stall-worker-start-ok')

        def run(command, **_kwargs):
            return subprocess.CompletedProcess(
                command, raw['exit'], stdout=raw['stdout'], stderr=raw['stderr'])

        babysit = fw.default_babysit_start(['bash', 'worker-startup.sh'], run=run)
        scan = fw.default_issue_scan_start(['bash', 'worker-startup.sh'], run=run)
        self.assertEqual(babysit, 0)
        self.assertEqual(scan, 0)
        self.assertEqual(babysit.dispatch_id, recorded_dispatch_id())
        self.assertEqual(scan.dispatch_id, recorded_dispatch_id())

    def test_failed_reply_names_the_recorded_error_code(self):
        body = recorded_body('stall-worker-start-fail')
        self.assertFalse(body['ok'])
        self.assertEqual(body['error']['code'], 'no_active_sender_terminal')


class OwnDispatchRecord(unittest.TestCase):
    def test_verifier_rework_and_issue_are_recorded_ship_and_sweep_are_not(self):
        did = recorded_dispatch_id()
        state = {}
        root = '/tmp/app-does-not-exist'
        config = {
            'issue_scan': {
                'enabled': True,
                'repos': [REPO],
                'pr_repos': [REPO],
                'run': 'run_x',
                'from_terminal': 'term_coord',
                'host': 'local',
                'agent': 'cursor',
                'model': 'm1',
                'rework_agent': 'cursor',
                'rework_model': 'm1',
                'repo_roots': {REPO: root},
            },
            'host_caps': {'local': 4},
            'runs': [{'id': 'run_x', 'terminal': 'term_coord', 'waiter_pattern': 'w'}],
            'babysit': {'repos': [REPO], 'startup': '/bin/true'},
        }
        head = HEAD
        ready = {
            'number': 3, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head,
            'headRefName': 'ready-branch', 'mergeable': 'MERGEABLE',
            'statusCheckRollup': [{
                'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS', 'isRequired': True,
            }],
            'comments': [{'body': 'Verdict: PASS head=%s verifier=ctx_v author=ctx_a' % head}],
            'labels': [], 'body': 'Builder: agent=claude model=sonnet',
        }
        fix = {
            'number': 9, 'state': 'OPEN', 'isDraft': False, 'headRefOid': '1' * 40,
            'headRefName': 'fix-branch', 'mergeable': 'MERGEABLE',
            'comments': [{'body': 'Checks: FAIL head=%s' % ('1' * 40)}],
            'labels': [], 'statusCheckRollup': [],
        }
        brief = (
            '## Acceptance criteria\n- [ ] prove it\n\n'
            '## Out of scope\nother files\n\n'
            '## Verify\nbash script/checks-local.sh\n\n'
            '## Finish\nworker_done.\n'
        )

        def admit(_h, _c, _w):
            return {'admitted': True, 'occupied': 0}

        ship_state = {'issue_scan_backlog_sweep_at': NOW}
        _ship_notices, ship_log = fw.issue_scan_pass(
            config, ship_state, NOW, [],
            list_issues=lambda _repo: [],
            pr_fetch=lambda _repo: [ready],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda _cmd: start_handle(),
            act=lambda _cmd: 0,
        )
        self.assertTrue(any(bit.startswith('ship_start=') for bit in ship_log), ship_log)
        self.assertNotIn('own_dispatches', ship_state)

        sweep_state = {}
        _sweep_notices, sweep_log = fw.issue_scan_pass(
            config, sweep_state, NOW, [],
            list_issues=lambda _repo: [],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda _cmd: start_handle(),
            act=lambda _cmd: 0,
        )
        self.assertTrue(any(bit.startswith('backlog_sweep_start=') for bit in sweep_log), sweep_log)
        self.assertNotIn('own_dispatches', sweep_state)

        rework_state = {'issue_scan_backlog_sweep_at': NOW}
        fw.issue_scan_pass(
            config, rework_state, NOW, [],
            list_issues=lambda _repo: [],
            pr_fetch=lambda _repo: [fix],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda _cmd: start_handle(),
            act=lambda _cmd: 0,
        )
        self.assertEqual(rework_state['own_dispatches'][did]['kind'], 'rework')

        issue_state = {'issue_scan_backlog_sweep_at': NOW}
        fw.issue_scan_pass(
            config, issue_state, NOW, [],
            list_issues=lambda _repo: [{
                'number': 4,
                'title': 'ticket',
                'body': brief,
                'labels': [{'name': 'ready-for-agent'}],
                'comments': [],
                'createdAt': '2026-01-01T00:00:00Z',
            }],
            pr_fetch=lambda _repo: [],
            gate_check=lambda _c: True,
            admit_fn=admit,
            start_worker=lambda _cmd: start_handle(),
            act=lambda _cmd: 0,
        )
        self.assertEqual(issue_state['own_dispatches'][did]['kind'], 'issue')

        green = {
            'number': 11, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head,
            'headRefName': 'verify-branch', 'mergeable': 'MERGEABLE',
            'statusCheckRollup': [{
                'name': 'checks', 'status': 'COMPLETED', 'conclusion': 'SUCCESS', 'isRequired': True,
            }],
            'comments': [], 'labels': [], 'body': 'Builder: agent=claude model=sonnet',
        }
        babysit_state = {}
        _b_notices, b_lines, _b_log = fw.babysit_pass(
            config, babysit_state, [],
            pr_fetch=lambda _repo: [green],
            start_worker=lambda _cmd: start_handle(),
            pick=lambda _role: {'selected': {'provider': 'cursor', 'model': 'grok', 'eligible': True}},
            owner_check=lambda _pr: None,
        )
        self.assertTrue(any('verifier' in line for line in b_lines), b_lines)
        self.assertEqual(babysit_state['own_dispatches'][did]['kind'], 'verifier')


class StallOwnWorkers(unittest.TestCase):
    def test_foreign_stall_is_one_notice_and_never_stops(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if '--retry-of' in args:
                return recorded_result('stall-worker-start-ok')
            return {}

        w = own_worker(dispatchId='disp_foreign')
        state = {}
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(calls, [])
        self.assertIn('stall_report=disp_foreign', bits)
        self.assertEqual(len(notices), 1)
        self.assertIn('worker-watch.sh', notices[0])
        self.assertIsInstance(notices[0], fw.Urgent)
        again, bits2 = fw.worker_stall_pass(
            stall_test_config(), state, T0 + 60, [w], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(again, [])
        self.assertNotIn('stall_report=disp_foreign', bits2)

    def test_own_stall_restarts_once_and_records_the_retry(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if '--retry-of' in args:
                return recorded_result('stall-worker-start-ok')
            return {}

        w = own_worker(dispatchId='disp_own')
        state = mark_own({}, 'disp_own')
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(notices, [])
        self.assertIn('stall_restart=disp_own', bits)
        stops = [c for c in calls if c[:2] == ('orchestration', 'worker-stop')]
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0][3], 'disp_own')
        starts = [c for c in calls if '--retry-of' in c]
        self.assertEqual(len(starts), 1)
        retry = recorded_dispatch_id()
        self.assertEqual(state['own_dispatches'][retry]['retry_of'], 'disp_own')
        calls.clear()
        fw.worker_stall_pass(
            stall_test_config(), state, T0 + 60, [w], {'term_fix': OLD_MS}, rpc)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))

    def test_failed_restart_parks_and_reports_once(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if '--retry-of' in args:
                recorded_result('stall-worker-start-fail')
            return {}

        w = own_worker(dispatchId='disp_fail')
        state = mark_own({}, 'disp_fail')
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, T0, [w], {'term_fix': OLD_MS}, rpc)
        self.assertIn('stall_parked=disp_fail', bits)
        self.assertTrue(state['own_dispatches']['disp_fail']['parked'])
        self.assertEqual(len(notices), 1)
        self.assertIn('no_active_sender_terminal', notices[0])
        self.assertIn('disp_fail', notices[0])
        calls.clear()
        again, _bits = fw.worker_stall_pass(
            stall_test_config(), state, T0 + 4000, [w], {'term_fix': OLD_MS}, rpc)
        self.assertEqual(again, [])
        self.assertFalse(any('--retry-of' in c for c in calls))
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))

    def test_silent_retry_parks_once_without_a_second_stop(self):
        calls = []

        def rpc(*args):
            calls.append(args)
            if '--retry-of' in args:
                return recorded_result('stall-worker-start-ok')
            return {}

        original = own_worker(dispatchId='disp_own')
        state = mark_own({}, 'disp_own')
        fw.worker_stall_pass(
            stall_test_config(), state, T0, [original], {'term_fix': OLD_MS}, rpc)
        retry_id = recorded_dispatch_id()
        retry = own_worker(
            dispatchId=retry_id, taskId='task_recorded', agentTerminalHandle='term_retry')
        calls.clear()
        later = T0 + 30 * 60
        quiet = int((later - 4000) * 1000)
        notices, bits = fw.worker_stall_pass(
            stall_test_config(), state, later, [retry],
            {'term_retry': quiet, 'term_fix': quiet}, rpc)
        self.assertFalse(any(c[:2] == ('orchestration', 'worker-stop') for c in calls))
        self.assertIn('stall_parked=%s' % retry_id, bits)
        self.assertEqual(len(notices), 1)
        self.assertIn('still silent after restart', notices[0])
        again, _bits = fw.worker_stall_pass(
            stall_test_config(), state, later + 60, [retry],
            {'term_retry': quiet, 'term_fix': quiet}, rpc)
        self.assertEqual(again, [])


if __name__ == '__main__':
    unittest.main()
