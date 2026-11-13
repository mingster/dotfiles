#!/usr/bin/env python3
"""Rules for moving an Orca board card to Done."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("board_done", ROOT / "script" / "board-done.py")
board = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(board)


def tree(**kwargs):
    base = {
        "path": "/w/a",
        "branch": "refs/heads/feat",
        "workspaceStatus": "in-progress",
        "isMainWorktree": False,
        "projectId": "github:acme/app",
    }
    base.update(kwargs)
    return base


def worker(kind, path="/w/a"):
    workspace = "repo::" + path
    if kind == "working":
        return {"state": "ready", "outcome": "in_progress", "liveness": "live", "terminalState": "active", "workspace": workspace}
    if kind == "released":
        return {"state": "succeeded", "liveness": "exited", "terminalState": "released", "workspace": workspace}
    if kind == "failed":
        return {"state": "failed", "liveness": "exited", "terminalState": "released", "dispatchStatus": "failed", "workspace": workspace}
    if kind == "stopped":
        return {"state": "stopped", "liveness": "exited", "terminalState": "released", "workspace": workspace}
    raise AssertionError(kind)


def pr(number, state):
    return {"number": number, "state": state, "headRefName": "feat"}


class Decide(unittest.TestCase):
    def test_merged_pr_is_done(self):
        self.assertEqual(board.decide(tree(), [], [pr(12, "MERGED")], []), "PR #12 merged")

    def test_closed_pr_is_done(self):
        self.assertEqual(board.decide(tree(), [], [pr(4, "CLOSED")], []), "PR #4 closed")

    def test_open_pr_stays(self):
        self.assertIsNone(board.decide(tree(), [worker("released")], [pr(9, "OPEN")], []))

    def test_open_pr_beats_an_older_closed_one(self):
        self.assertIsNone(board.decide(tree(), [], [pr(1, "CLOSED"), pr(2, "OPEN")], []))

    def test_closed_issue_is_done(self):
        self.assertEqual(board.decide(tree(), [worker("working")], [], [{"number": 7, "state": "CLOSED"}]), "issue #7 closed")

    def test_open_issue_with_a_live_worker_stays(self):
        self.assertIsNone(board.decide(tree(), [worker("working")], [], [{"number": 7, "state": "OPEN"}]))

    def test_released_worker_with_no_pr_is_done(self):
        self.assertEqual(board.decide(tree(), [worker("released")], [], []), "worker released, no PR")

    def test_failed_worker_is_done_even_with_an_open_pr(self):
        self.assertEqual(board.decide(tree(), [worker("failed")], [pr(3, "OPEN")], []), "worker failed")

    def test_stopped_worker_is_done(self):
        self.assertEqual(board.decide(tree(), [worker("stopped")], [], []), "worker stopped")

    def test_live_retry_after_a_failure_stays(self):
        rows = [worker("failed"), worker("working")]
        self.assertIsNone(board.decide(tree(), rows, [], []))

    def test_open_pr_stays_when_a_released_worker_sits_beside_a_failure(self):
        rows = [worker("failed"), worker("released")]
        self.assertIsNone(board.decide(tree(), rows, [pr(9, "OPEN")], []))

    def test_failed_and_released_with_no_pr_is_done(self):
        rows = [worker("failed"), worker("released")]
        self.assertEqual(board.decide(tree(), rows, [], []), "worker failed")

    def test_unknown_pr_lookup_does_not_pretend_there_is_no_pr(self):
        self.assertIsNone(board.decide(tree(), [worker("released")], [], [], prs_known=False))

    def test_completed_and_main_stay(self):
        self.assertIsNone(board.decide(tree(workspaceStatus="completed"), [], [pr(1, "MERGED")], []))
        self.assertIsNone(board.decide(tree(isMainWorktree=True), [], [pr(1, "MERGED")], []))

    def test_nested_dispatch_host_path(self):
        row = {"dispatchStatus": "released", "resource": {"worktreeId": "repo::/w/a"}, "projection": {"host": {"id": "blueDevil"}}}
        self.assertEqual(board.row_path(row), "/w/a")
        self.assertEqual(board.worker_kind(row), "released")


if __name__ == "__main__":
    unittest.main()
