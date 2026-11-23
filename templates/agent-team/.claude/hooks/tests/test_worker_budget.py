"""Tests for .claude/hooks/worker-budget.py, the worker turn budget.

Run from the repo root: python3 -m unittest discover -s .claude/hooks/tests
The hook runs as Claude Code does (JSON on stdin) with HOME pointed at a temporary folder.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

# The start of the brief Orca gives a dispatched worker; a coordinator session has none.
PREAMBLE = ("You are working inside Orca, a multi-agent IDE. You are a dispatched worker.\n"
            "orca orchestration send --type worker_done --task-id task_1 --dispatch-id ctx_abc123")
HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "worker-budget.py")


class WorkerBudgetTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="budget-home-")
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)
        self.transcript = os.path.join(self.home, "transcript.jsonl")

    def run_hook(self, worktree, turns, event, worker=True, tool="Edit", cmd=None, mail=None):
        with open(self.transcript, "w") as f:
            first = (PREAMBLE if worker else "/elon status")
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": first}}) + "\n")
            for i in range(turns):
                f.write(json.dumps({"type": "assistant", "message": {"id": f"msg_{i}"}}) + "\n")
        cwd = os.path.join(self.home, "orca", "workspaces", "proj", worktree)
        os.makedirs(cwd, exist_ok=True)
        payload = {"cwd": cwd, "session_id": "s", "transcript_path": self.transcript,
                   "hook_event_name": event, "tool_name": tool, "tool_input": {"command": cmd} if cmd else {}}
        env = dict(os.environ, HOME=self.home)
        env.pop("ORCA_TERMINAL_HANDLE", None)
        if mail is not None:
            bindir = os.path.join(self.home, "bin")
            os.makedirs(bindir, exist_ok=True)
            fake = os.path.join(bindir, "orca")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\ncat <<'EOF'\n" + json.dumps({"ok": True, "result": {"messages": mail}}) + "\nEOF\n")
            os.chmod(fake, 0o755)
            env["PATH"] = bindir + os.pathsep + env["PATH"]
            env["ORCA_TERMINAL_HANDLE"] = "term_x"
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

    def test_coordinator_session_never_warned(self):
        self.assertIsNone(self.run_hook("elon-x", 150, "PostToolUse", worker=False))

    def test_coordinator_session_never_denied(self):
        self.assertIsNone(self.run_hook("elon-x", 250, "PreToolUse", worker=False))

    WD = "orca orchestration send --type worker_done --task-id task_1 --dispatch-id ctx_abc123 --body x"

    def test_worker_done_denied_with_unread_mail(self):
        out = self.run_hook("fullstack-dev-x", 5, "PreToolUse", tool="Bash", cmd=self.WD, mail=[{"id": "msg_1", "body": "please also fix Y"}])
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("please also fix Y", out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_worker_done_allowed_without_unread_mail(self):
        self.assertIsNone(self.run_hook("fullstack-dev-x", 5, "PreToolUse", tool="Bash", cmd=self.WD, mail=[]))

    def test_worker_done_allowed_without_terminal_handle(self):
        self.assertIsNone(self.run_hook("fullstack-dev-x", 5, "PreToolUse", tool="Bash", cmd=self.WD))


if __name__ == "__main__":
    unittest.main()
