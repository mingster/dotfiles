"""Tests for hooks/owner-decisions-stop.py: an answered issue blocks the reply, an unanswered one passes."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "owner-decisions-stop.py")


class OwnerDecisionsStopTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ods-")
        self.script = os.path.join(self.dir, "owner-decisions.sh")
        # Stub: issue 7 has a decision (exit 0), 8 has none (exit 1), 9 fails (exit 2).
        with open(self.script, "w") as fh:
            fh.write('#!/usr/bin/env bash\ncase "$2" in 7) echo "#7: Owner decision: A"; exit 0;; 9) exit 2;; *) exit 1;; esac\n')
        os.chmod(self.script, os.stat(self.script).st_mode | stat.S_IXUSR)

    def transcript(self, reply, first_user="hello"):
        path = os.path.join(self.dir, "t.jsonl")
        with open(path, "w") as fh:
            for role, text in (("user", first_user), ("assistant", reply)):
                fh.write(json.dumps({"message": {"role": role, "content": [{"type": "text", "text": text}]}}) + "\n")
        return path

    def run_hook(self, reply, first_user="hello", **extra):
        payload = dict({"transcript_path": self.transcript(reply, first_user)}, **extra)
        env = dict(os.environ, OWNER_DECISIONS_SCRIPT=self.script, OWNER_DECISIONS_REPO="o/r")
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True,
                             capture_output=True, env=env, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout) if out.stdout.strip() else None

    def test_answered_issue_blocks_the_reply(self):
        result = self.run_hook("Should we take A or B on #7?")
        self.assertEqual(result["decision"], "block")
        self.assertIn("already answered on #7, apply it", result["reason"])
        self.assertIn("Owner decision: A", result["reason"])

    def test_unanswered_issue_passes(self):
        self.assertIsNone(self.run_hook("Should we take A or B on #8?"))

    def test_one_answered_among_several_blocks(self):
        self.assertIn("#7", self.run_hook("#8 and #7: which one?")["reason"])

    def test_statement_without_a_question_passes(self):
        self.assertIsNone(self.run_hook("Applied the decision on #7."))

    def test_question_without_issue_number_passes(self):
        self.assertIsNone(self.run_hook("Which option do you want?"))

    def test_check_failure_passes(self):
        self.assertIsNone(self.run_hook("What about #9?"))

    def test_dispatched_worker_passes(self):
        self.assertIsNone(self.run_hook("Which for #7?", first_user="You are a dispatched worker."))

    def test_second_pass_after_a_block_passes(self):
        self.assertIsNone(self.run_hook("Which for #7?", stop_hook_active=True))


if __name__ == "__main__":
    unittest.main()
