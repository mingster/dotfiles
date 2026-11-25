"""Tests for hooks/owner-decisions-stop.py: an answered issue blocks the reply, an unanswered one passes."""
import json
import os
import stat
import shutil
import subprocess
import sys
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "owner-decisions-stop.py")


class OwnerDecisionsStopTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ods-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.script = os.path.join(self.dir, "owner-decisions.sh")
        # Stub: issue 44 only prints a decision recorded on #7 (a referenced issue). Issue 7 has a decision (exit 0), 8 has none (exit 1), 9 fails (exit 2). Logs "<repo> <n>".
        with open(self.script, "w") as fh:
            fh.write('#!/usr/bin/env bash\necho "$1 $2" >>"$(dirname "$0")/calls"\ncase "$2" in 7|42) echo "#$2: Owner decision: A"; exit 0;; 44) echo "#7: Owner decision: A"; exit 0;; 9) exit 2;; *) exit 1;; esac\n')
        os.chmod(self.script, os.stat(self.script).st_mode | stat.S_IXUSR)

    def transcript(self, reply, first_user="hello"):
        return self.write_records([
            {"message": {"role": "user", "content": [{"type": "text", "text": first_user}]}},
            {"message": {"role": "assistant", "content": [{"type": "text", "text": reply}]}},
        ])

    def write_records(self, records):
        path = os.path.join(self.dir, "t.jsonl")
        with open(path, "w") as fh:
            for rec in records:
                fh.write(json.dumps(rec) + "\n")
        return path

    def run_hook(self, reply, first_user="hello", path=None, repo="o/r", **extra):
        payload = dict({"transcript_path": path or self.transcript(reply, first_user)}, **extra)
        env = dict(os.environ, OWNER_DECISIONS_SCRIPT=self.script)
        if repo:
            env["OWNER_DECISIONS_REPO"] = repo
        else:
            env.pop("OWNER_DECISIONS_REPO", None)
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True,
                             capture_output=True, env=env, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.last_env = env
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

    def test_progress_report_on_a_decided_issue_passes(self):
        self.assertIsNone(self.run_hook("PR merged for #7.\nWorker answered on #7.\nAnything else?"))

    def test_question_on_another_line_than_the_issue_passes(self):
        self.assertIsNone(self.run_hook("Merged #7.\nWhich day works for the call?"))

    def test_needs_you_wording_about_a_decided_issue_blocks(self):
        self.assertEqual(self.run_hook("#7 needs you.")["decision"], "block")

    def test_a_or_b_choice_about_a_decided_issue_blocks(self):
        self.assertEqual(self.run_hook("#7: take A/B")["decision"], "block")

    def test_decision_only_on_a_referenced_issue_passes(self):
        self.assertIsNone(self.run_hook("Which for #44?"))

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

    @staticmethod
    def user(text):
        return {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}

    @staticmethod
    def assistant(text):
        return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}

    def test_null_content_record_does_not_hide_the_reply(self):
        path = self.write_records([self.user("hello"),
                                   {"type": "assistant", "message": {"role": "assistant", "content": None}}])
        result = self.run_hook("", path=path, last_assistant_message="Which for #7?")
        self.assertEqual(result["decision"], "block")

    def test_meta_user_record_before_the_brief_still_marks_a_worker(self):
        path = self.write_records([dict(self.user("<local-command-caveat>x"), isMeta=True),
                                   self.user("You are a dispatched worker."), self.assistant("Which for #7?")])
        self.assertIsNone(self.run_hook("", path=path))

    def test_reply_split_around_a_tool_call_keeps_the_issue(self):
        path = self.write_records([self.user("hello"), self.assistant("Re #7:"),
                                   {"type": "user", "toolUseResult": {}, "message": {"role": "user", "content": [
                                       {"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}},
                                   self.assistant("#7: A or B?")])
        self.assertEqual(self.run_hook("", path=path)["decision"], "block")

    def test_turn_without_assistant_text_leaves_no_stale_question(self):
        path = self.write_records([self.user("hello"), self.assistant("Which for #7?"), self.user("go on")])
        self.assertIsNone(self.run_hook("", path=path))

    def test_cross_repo_reference_uses_its_own_repo(self):
        result = self.run_hook("Which for o2/r2#42?")
        self.assertEqual(result["decision"], "block")
        with open(os.path.join(self.dir, "calls")) as fh:
            self.assertEqual(fh.read().split("\n")[0], "o2/r2 42")

    def test_bare_reference_repo_comes_from_payload_cwd(self):
        bindir = os.path.join(self.dir, "bin")
        os.makedirs(bindir)
        gh = os.path.join(bindir, "gh")
        with open(gh, "w") as fh:
            fh.write('#!/usr/bin/env bash\necho "gh in $(pwd -P)" >"$(dirname "$0")/../ghcwd"\necho cwd/repo\n')
        os.chmod(gh, 0o755)
        cwd = os.path.join(self.dir, "work")
        os.makedirs(cwd)
        old = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + old
        try:
            self.run_hook("Which for #7?", repo=None, cwd=cwd)
        finally:
            os.environ["PATH"] = old
        with open(os.path.join(self.dir, "ghcwd")) as fh:
            self.assertEqual(fh.read().strip(), "gh in " + os.path.realpath(cwd))
        with open(os.path.join(self.dir, "calls")) as fh:
            self.assertEqual(fh.read().split("\n")[0], "cwd/repo 7")


if __name__ == "__main__":
    unittest.main()
