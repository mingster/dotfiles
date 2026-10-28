"""Tests for .claude/hooks/strikes.py, the retry circuit breaker.

Run from the repo root: python3 -m unittest discover -s .claude/hooks/tests
The hook runs as Claude Code does (JSON on stdin) with HOME pointed at a temporary folder.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "strikes.py")
COMMAND = "bun test web/src/x/__tests__/a.test.ts"


class StrikesTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="strikes-home-")

    def run_hook(self, event, output=""):
        payload = {"tool_name": "Bash", "hook_event_name": event, "session_id": "s1",
                   "tool_input": {"command": COMMAND}, "tool_response": {"stdout": output}}
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True,
                             capture_output=True, env=dict(os.environ, HOME=self.home), timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)["hookSpecificOutput"] if out.stdout.strip() else None

    def test_assertion_failure_counts(self):
        result = self.run_hook("PostToolUse", " 1 pass\n 2 fail\nerror: expect(received).toBe(expected)")
        self.assertIn("Strike 1 of 3", result["additionalContext"])

    def test_tooling_failures_do_not_count(self):
        for output in [
            "error: Cannot find module 'zod' from '/repo/web/src/a.ts'\n 1 fail",
            "error: Cannot find package 'next' from '/repo/web/src/a.ts'\n 1 fail",
            "error: Could not resolve: \"@/lib/x\"\n 1 fail",
            "ENOENT node_modules/.bin/tsc\n 1 fail",
            "Run prisma generate first\n 1 fail",
            "@prisma/client did not initialize yet\n 1 fail",
            "heavy-gate: budget exceeded\n 1 fail",
        ]:
            with self.subTest(output=output):
                result = self.run_hook("PostToolUse", output)
                self.assertIn("tooling failure, not a strike", result["additionalContext"])
                self.assertNotIn("Strike", result["additionalContext"])

    def test_tooling_failure_leaves_count_alone(self):
        for _ in range(3):
            self.run_hook("PostToolUse", "Cannot find module 'zod'\n 1 fail")
        self.assertIsNone(self.run_hook("PreToolUse"))


if __name__ == "__main__":
    unittest.main()
