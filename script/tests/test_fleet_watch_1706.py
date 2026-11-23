"""#1706: babysit starts no verifier for a PR that already has a live one on this head, or that is no longer open."""
import fcntl
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

from test_fleet_watch_park import HEAD, REPO, verifier_pr  # noqa: E402

PICK = lambda _role: {'selected': {'provider': 'cursor', 'model': 'm', 'eligible': True}}  # noqa: E731


def live_verifier_row(title='#7|qa-sdet|verify PR 7'):
    """A worker-list row for a running verifier, shaped like the live_verifier helper in test_fleet_watch_915."""
    return {
        'dispatchId': 'ctx_live_1706', 'taskId': 'task_live_1706', 'runId': 'run_live',
        'workerState': 'ready', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
        'projection': {
            'role': 'worker', 'outcome': 'in_progress', 'provider': None,
            'workspace': {'id': 'wt::/tmp/v7', 'kind': 'folder_or_worktree'},
            'stage': {'worker': 'ready', 'dispatch': 'dispatched', 'detail': 'input_accepted', 'activity': 'working'},
            'liveness': {'verdict': 'live', 'source': 'agent_status'},
        },
        '_task_title': title,
    }


class VerifierGuards(unittest.TestCase):
    def run_pass(self, state, root, workers=None, pr_rows=None, pr_state_rows=None, pr_state_fetch=None):
        config = {
            'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
            'babysit': {'repos': [REPO], 'startup': '/bin/true'},
        }
        starts = []

        def start(command):
            starts.append(command)
            return fw.BabysitStartResult(0)

        if pr_state_fetch is None:
            pr_state_fetch = (lambda _repo: pr_state_rows) if pr_state_rows is not None else None
        _notices, lines, _log = fw.babysit_pass(
            config, state, workers or [],
            pr_fetch=lambda _repo: pr_rows if pr_rows is not None else [verifier_pr()],
            pr_state_fetch=pr_state_fetch,
            start_worker=start, pick=PICK, owner_check=lambda _pr: None,
        )
        return starts, lines

    def test_live_verifier_on_same_head_blocks_a_start_with_no_state_record(self):
        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass({}, root, workers=[live_verifier_row()])
        self.assertEqual(starts, [], lines)
        self.assertTrue(any('verifier-live' in line for line in lines), lines)

    def test_recorded_verifier_on_same_head_blocks_a_start(self):
        state = {'babysit': {REPO: {'7': {'head': HEAD, 'action': 'verifier'}}}}
        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass(state, root)
        self.assertEqual(starts, [], lines)
        self.assertTrue(any('already' in line for line in lines), lines)

    def test_pr_closed_after_the_list_was_read_is_not_started(self):
        # The pass listed the PR as open, but the fresh re-read no longer finds it open (merged or closed).
        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass({}, root, pr_state_rows=[])
        self.assertEqual(starts, [], lines)
        self.assertTrue(any('not-open' in line for line in lines), lines)

    def test_pr_still_open_at_the_reread_is_started(self):
        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass({}, root, pr_state_rows=[verifier_pr()])
        self.assertEqual(len(starts), 1, lines)

    def test_unreadable_reread_skips_this_pass(self):
        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass({}, root, pr_state_fetch=lambda _repo: None)
        self.assertEqual(starts, [], lines)
        self.assertTrue(any('state-unknown' in line for line in lines), lines)

    def test_reread_is_fresh_not_the_pass_list(self):
        # The pass list says open. The re-read, called right before the start, says merged. The start must not happen.
        calls = []

        def fresh(_repo):
            calls.append(_repo)
            return []

        with tempfile.TemporaryDirectory() as root:
            starts, lines = self.run_pass({}, root, pr_rows=[verifier_pr()], pr_state_fetch=fresh)
        self.assertEqual(calls, [REPO])
        self.assertEqual(starts, [], lines)


class OnePassPerState(unittest.TestCase):
    """#1706 reopened: the loop, the 5 minute automation and a manual run each load state, see no record and start a verifier."""
    SCRIPT = Path(__file__).parent.parent / 'fleet-watch.py'

    def run_cli(self, state, config):
        return subprocess.run(
            [sys.executable, str(self.SCRIPT), '--config', str(config), '--state', str(state), '--babysit-only'],
            capture_output=True, text=True, timeout=60,
        )

    def test_second_pass_on_the_same_state_exits_without_starting_anything(self):
        with tempfile.TemporaryDirectory() as root:
            state, config = Path(root) / 'state.json', Path(root) / 'config.json'
            config.write_text(json.dumps({'babysit': {'repos': ['o/r'], 'startup': '/bin/true'}}))
            with open(str(state) + '.lock', 'w') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)  # another pass is running
                result = self.run_cli(state, config)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('another pass is running', result.stderr)
            self.assertFalse(state.exists())

    def test_lock_is_free_again_once_the_holder_exits(self):
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / 'state.json'
            first = fw.acquire_pass_lock(state)
            self.assertIsNotNone(first)
            self.assertIsNone(fw.acquire_pass_lock(state))
            first.close()
            again = fw.acquire_pass_lock(state)
            self.assertIsNotNone(again)
            again.close()


if __name__ == '__main__':
    unittest.main()
