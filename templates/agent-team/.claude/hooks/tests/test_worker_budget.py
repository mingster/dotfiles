"""Tests for .claude/hooks/worker-budget.py, the worker turn budget.

Run from the repo root: python3 -m unittest discover -s .claude/hooks/tests
The hook runs as Claude Code does (JSON on stdin) with HOME pointed at a temporary folder.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "worker-budget.py")


class WorkerBudgetTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="budget-home-")
        self.transcript = os.path.join(self.home, "transcript.jsonl")

    def run_hook(self, worktree, turns, event):
        with open(self.transcript, "w") as f:
            for i in range(turns):
                f.write(json.dumps({"type": "assistant", "message": {"id": f"msg_{i}"}}) + "\n")
        cwd = os.path.join(self.home, "orca", "workspaces", "proj", worktree)
        os.makedirs(cwd, exist_ok=True)
        payload = {"cwd": cwd, "session_id": "s", "transcript_path": self.transcript,
                   "hook_event_name": event, "tool_name": "Edit", "tool_input": {}}
        env = dict(os.environ, HOME=self.home)
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True,
                             text=True, env=env, check=True).stdout
        return json.loads(out) if out.strip() else None

    def test_worker_warned_at_120(self):
        out = self.run_hook("fullstack-dev-x", 120, "PostToolUse")
        self.assertIn("Worker budget", out["hookSpecificOutput"]["additionalContext"])

    def test_worker_denied_at_200(self):
        out = self.run_hook("fullstack-dev-x", 200, "PreToolUse")
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_lead_never_warned(self):
        self.assertIsNone(self.run_hook("lead-x", 150, "PostToolUse"))

    def test_lead_never_denied(self):
        self.assertIsNone(self.run_hook("lead-x", 250, "PreToolUse"))


if __name__ == "__main__":
    unittest.main()
