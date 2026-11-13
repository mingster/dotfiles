import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_stall import base_worker, stall_test_config, OLD_MS, T0  # noqa: E402

REPO = 'owner/app'
BRANCH = 'mingster/intenttopup'


def git(*args, cwd):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True,
                   env={'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t', 'GIT_COMMITTER_NAME': 't',
                        'GIT_COMMITTER_EMAIL': 't@t', 'PATH': '/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin'})


class RemoteOnlyBranch(unittest.TestCase):
    """A PR opened on another host: origin has the branch, the coordinator clone has no local ref."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        tmp = Path(self.tmp.name)
        origin, other, self.clone = tmp / 'origin.git', tmp / 'other', tmp / 'clone'
        git('init', '-q', '--bare', '-b', 'main', str(origin), cwd=tmp)
        git('clone', '-q', str(origin), str(other), cwd=tmp)
        (other / 'f').write_text('x')
        git('add', 'f', cwd=other)
        git('commit', '-q', '-m', 'init', cwd=other)
        git('push', '-q', 'origin', 'HEAD:main', cwd=other)
        git('clone', '-q', str(origin), str(self.clone), cwd=tmp)
        git('checkout', '-q', '-b', BRANCH, cwd=other)
        git('push', '-q', 'origin', BRANCH, cwd=other)
        self.config = {
            'babysit': {'run': 'run_x', 'from_terminal': 'term_c', 'repo_roots': {REPO: str(self.clone)}},
            'issue_scan': {'run': 'run_x', 'from_terminal': 'term_c', 'repo_roots': {REPO: str(self.clone)}},
        }
        self.row = {'number': 7877, 'headRefName': BRANCH, 'headRefOid': 'a' * 40}

    def assert_based_on_remote(self, command):
        base = command[command.index('--base-branch') + 1]
        self.assertEqual(base, 'origin/' + BRANCH)
        local = subprocess.run(['git', '-C', str(self.clone), 'rev-parse', '--verify', '-q', 'refs/heads/' + BRANCH])
        self.assertNotEqual(local.returncode, 0)
        resolved = subprocess.run(['git', '-C', str(self.clone), 'rev-parse', '--verify', '-q', base])
        self.assertEqual(resolved.returncode, 0)

    def test_babysit_command_bases_worktree_on_fetched_remote_branch(self):
        command = fw.build_babysit_command(self.config, REPO, self.row, 'verifier', 'claude', 'sonnet', None)
        self.assert_based_on_remote(command)

    def test_rework_command_bases_worktree_on_fetched_remote_branch(self):
        self.row['comments'] = []
        command = fw.build_rework_start_command(self.config, REPO, self.row)
        self.assert_based_on_remote(command)


class StartReason(unittest.TestCase):
    def test_orca_json_error_message_wins_over_closing_brace(self):
        stderr = ('orca: worktree create failed\n'
                  + json.dumps({'ok': False, 'error': {'code': 'worktree_create_failed',
                                                       'message': 'fatal: invalid reference: mingster/intenttopup\nmore'}},
                               indent=2))
        self.assertEqual(fw._start_reason(stderr), 'fatal: invalid reference: mingster/intenttopup')

    def test_plain_stderr_keeps_last_line(self):
        self.assertEqual(fw._start_reason('a\nboom here'), 'boom here')


class Notices(unittest.TestCase):
    def test_send_addresses_the_run_with_the_existing_sender(self):
        calls = []
        config = {'runs': [{'id': 'run_x', 'terminal': 'term_live'}]}
        state = {}
        fw.deliver_notices(config, state, [fw.Urgent('boom')], rpc_call=lambda *a: calls.append(a), now=100.0)
        self.assertEqual(len(calls), 1)
        args = calls[0]
        self.assertEqual(args[args.index('--to') + 1], 'run:run_x')
        self.assertEqual(args[args.index('--from') + 1], 'term_live')
        self.assertNotEqual(args[args.index('--from') + 1], args[args.index('--to') + 1])

    def test_verdict_goes_to_the_lead_from_the_run_terminal(self):
        calls = []
        config = {'runs': [{'id': 'run_x', 'terminal': 'term_live'}]}
        verdict = fw.Verdict('Verdict: PASS')
        verdict.author = 'ctx_a1'
        fw.deliver_notices(
            config, {}, [verdict], rpc_call=lambda *a: calls.append(a), now=100.0,
            owner_of=lambda author: 'term_lead' if author == 'ctx_a1' else None,
        )
        args = calls[0]
        self.assertEqual(args[args.index('--to') + 1], 'term_lead')
        self.assertEqual(args[args.index('--from') + 1], 'term_live')

    def test_notices_for_terminals_not_in_runs_are_dropped(self):
        calls = []
        config = {'runs': [{'id': 'run_x', 'terminal': 'term_live'}]}
        state = {'notice_queue': {'term_dead': [{'text': 'old', 'urgent': True, 'passes': 3}]}}
        fw.deliver_notices(config, state, [], rpc_call=lambda *a: calls.append(a), now=100.0)
        self.assertEqual(calls, [])
        self.assertNotIn('term_dead', state['notice_queue'])


class StallRestartGivesUp(unittest.TestCase):
    def test_failing_restart_is_reported_once_then_stops(self):
        starts = []

        def rpc(*a):
            if '--retry-of' in a:
                starts.append(a)
                err = fw.OrcaReadError('boom')
                err.orca_error_code = 'worktree_busy'
                raise err
            return {}

        w = base_worker(dispatchId='d1', taskId='t_fail', resource={'worktreeId': 'wt::/p'})
        term_times = {'term_fix': OLD_MS}
        cfg, state = stall_test_config(), {}
        state['own_dispatches'] = {'d1': {'kind': 'rework'}}
        urgent = []
        for step in range(6):
            notices, _bits = fw.worker_stall_pass(cfg, state, T0 + step, [w] if step == 0 else [], term_times, rpc)
            urgent += [n for n in notices if isinstance(n, fw.Urgent)]
        self.assertEqual(len(starts), 1)
        self.assertEqual(len(urgent), 1)
        self.assertIn('d1', str(urgent[0]))
        self.assertTrue(state['own_dispatches']['d1'].get('parked'))


if __name__ == '__main__':
    unittest.main()
