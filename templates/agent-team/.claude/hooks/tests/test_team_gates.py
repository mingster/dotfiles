"""Tests for the team gates in .claude/hooks/guard-bash.py and the compact reminder (#6936).

1. Role file gate: commit, push and PR create that touch .claude/agents, docs/agents or
   .claude/model-routing.md need an `Owner-approved:` trailer.
2. Grill gate: worker-start for a build worker needs the owner's grill approval on the issue.
3. Owning lead: worker-start on another host needs `--from <lead handle>`.
4. SessionStart:compact prints a checklist.

Run from the repo root: python3 -m unittest discover -s .claude/hooks/tests
`gh` is faked with a script on PATH and git runs in a throwaway repo, so nothing touches the network.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HOOKS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(HOOKS, "guard-bash.py")
SETTINGS = os.path.join(os.path.dirname(HOOKS), "settings.json")
TRAILER = "\n\nOwner-approved: mingster 2026-11-04"


def sh(cwd, *cmd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


class Gate(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="gate-home-")
        self.bin = os.path.join(self.home, "bin")
        os.makedirs(self.bin)
        self.issue = {"labels": [], "body": "", "comments": []}
        self.gh_fails = False
        self.gh_log = os.path.join(self.home, "gh.log")

    def gh_calls(self):
        try:
            with open(self.gh_log) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def fake_gh(self):
        path = os.path.join(self.bin, "gh")
        record = f'echo "$@" >> {self.gh_log}\n'
        with open(path, "w") as f:
            if self.gh_fails:
                f.write("#!/bin/sh\n" + record + "exit 1\n")
            else:
                f.write("#!/bin/sh\n" + record + "cat <<'JSON'\n" + json.dumps(self.issue) + "\nJSON\n")
        os.chmod(path, 0o755)

    def bash(self, command, cwd=None):
        self.fake_gh()
        env = dict(os.environ, HOME=self.home, PATH=self.bin + os.pathsep + os.environ["PATH"])
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": cwd or self.home}
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True,
                             capture_output=True, env=env, cwd=cwd or self.home, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        if not out.stdout.strip():
            return None
        return json.loads(out.stdout)["hookSpecificOutput"]["permissionDecisionReason"]

    def assertDenied(self, command, needle, cwd=None):
        reason = self.bash(command, cwd)
        self.assertIsNotNone(reason, f"expected deny: {command}")
        self.assertIn(needle, reason)

    def assertAllowed(self, command, cwd=None):
        self.assertIsNone(self.bash(command, cwd), f"expected allow: {command}")


class RoleFileGate(Gate):
    def setUp(self):
        super().setUp()
        origin = os.path.join(self.home, "origin.git")
        self.repo = os.path.join(self.home, "repo")
        sh(self.home, "git", "init", "-q", "--bare", "-b", "main", origin)
        sh(self.home, "git", "clone", "-q", origin, self.repo)
        for k, v in (("user.email", "t@example.com"), ("user.name", "t"), ("commit.gpgsign", "false")):
            sh(self.repo, "git", "config", k, v)
        self.write(".claude/agents/elon.md", "v1\n")
        self.write("web/app.ts", "v1\n")
        sh(self.repo, "git", "add", "-A")
        sh(self.repo, "git", "commit", "-q", "-m", "base")
        sh(self.repo, "git", "push", "-q", "origin", "HEAD:main")
        sh(self.repo, "git", "fetch", "-q", "origin")
        sh(self.repo, "git", "checkout", "-q", "-b", "work")

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def commit_real(self, rel, message):
        self.write(rel, message + "\n")
        sh(self.repo, "git", "add", rel)
        sh(self.repo, "git", "commit", "-q", "-m", message)

    def test_commit_staged_role_file_denied(self):
        self.write(".claude/agents/elon.md", "v2\n")
        sh(self.repo, "git", "add", "-A")
        self.assertDenied('git commit -m "tweak elon"', "Owner-approved:", self.repo)

    def test_commit_with_trailer_allowed(self):
        self.write("docs/agents/team-facts.md", "x\n")
        sh(self.repo, "git", "add", "-A")
        self.assertAllowed(f'git commit -m "tweak team-facts{TRAILER}"', self.repo)

    def test_commit_protected_docs_and_template_paths_denied_without_trailer(self):
        for rel in (
            "docs/agents/issue-tracker.md",
            "docs/agents/triage-labels.md",
            "docs/agents/domain.md",
            "docs/agents/team-facts.md",
            "docs/agents/deploy-facts.md",
            "templates/agent-team/docs/agents/team.md",
            "templates/agent-team/.claude/agents/elon.md",
        ):
            with self.subTest(rel=rel):
                sh(self.repo, "git", "reset", "-q", "--hard", "HEAD")
                self.write(rel, "x\n")
                sh(self.repo, "git", "add", "-A")
                self.assertDenied('git commit -m "tweak protected"', "Owner-approved:", self.repo)
                self.assertAllowed(f'git commit -m "tweak protected{TRAILER}"', self.repo)

    def test_commit_unprotected_docs_agents_files_allowed_without_trailer(self):
        for rel in (
            "docs/agents/learned.md",
            "docs/agents/experiences/gotcha.md",
            "docs/agents/team.md",
            "docs/other.md",
        ):
            with self.subTest(rel=rel):
                sh(self.repo, "git", "reset", "-q", "--hard", "HEAD")
                self.write(rel, "x\n")
                sh(self.repo, "git", "add", "-A")
                self.assertAllowed('git commit -m "tweak unprotected"', self.repo)

    def test_commit_with_heredoc_trailer_allowed(self):
        self.write(".claude/model-routing.md", "x\n")
        sh(self.repo, "git", "add", "-A")
        cmd = 'git commit -m "$(cat <<\'EOF\'\ntweak routing\n\nOwner-approved: mingster 2026-11-04\nEOF\n)"'
        self.assertAllowed(cmd, self.repo)

    def test_commit_other_files_allowed(self):
        self.write("web/app.ts", "v2\n")
        sh(self.repo, "git", "add", "-A")
        self.assertAllowed('git commit -m "app"', self.repo)

    def test_commit_all_flag_sees_unstaged_role_file(self):
        self.write(".claude/agents/elon.md", "v2\n")
        self.assertDenied('git commit -am "tweak elon"', "Owner-approved:", self.repo)

    def test_push_with_untrailered_role_commit_denied(self):
        self.commit_real(".claude/agents/elon.md", "tweak elon")
        self.assertDenied("git push origin work", "Owner-approved:", self.repo)

    def test_push_with_trailer_allowed(self):
        self.commit_real("docs/agents/team-facts.md", "tweak team-facts" + TRAILER)
        self.assertAllowed("git push origin work", self.repo)

    def test_push_without_role_files_allowed(self):
        self.commit_real("web/app.ts", "app")
        self.assertAllowed("git push origin work", self.repo)

    def test_pr_create_with_untrailered_role_commit_denied(self):
        self.commit_real(".claude/model-routing.md", "tweak routing")
        self.assertDenied('gh pr create --title "x" --body "y"', "Owner-approved:", self.repo)

    def test_pr_create_with_trailer_allowed(self):
        self.commit_real(".claude/model-routing.md", "tweak routing" + TRAILER)
        self.assertAllowed('gh pr create --title "x" --body "y"', self.repo)


class GrillGate(Gate):
    BUILD = 'orca orchestration worker-start --agent claude --worktree new-child --spec "You are fullstack-dev. Ticket: mingster/project-a#6936"'

    def test_build_worker_without_approval_denied(self):
        self.issue["comments"] = [{"body": "grill notes from architect-pm"}]
        self.assertDenied(self.BUILD, "owner's approval of the grill results")

    def test_denial_names_the_issue(self):
        self.assertDenied(self.BUILD, "#6936")

    def test_build_worker_with_approval_allowed(self):
        self.issue["comments"] = [{"body": "Owner approved the grill results on 2026-11-04."}]
        self.assertAllowed(self.BUILD)

    def test_hotfix_label_exempt(self):
        self.issue["labels"] = [{"name": "hotfix"}]
        self.assertAllowed(self.BUILD)

    def test_mechanical_label_exempt(self):
        self.issue["labels"] = [{"name": "mechanical-lane"}]
        self.assertAllowed(self.BUILD)

    def test_elon_take_over_exempt(self):
        self.issue["comments"] = [{"body": "Elon take over, decide and record."}]
        self.assertAllowed(self.BUILD)

    def test_elon_take_over_in_the_body_is_not_an_exemption(self):
        self.issue["body"] = 'Exempt: hotfix, mechanical text only and "Elon take over" (team.md).'
        self.assertDenied(self.BUILD, "owner's approval of the grill results")

    def test_worktree_issue_selector_names_the_issue(self):
        cmd = 'orca orchestration worker-start --agent claude --worktree issue:4242 --spec "You are fullstack-dev."'
        self.assertDenied(cmd, "#4242")

    def test_build_worker_without_issue_number_denied(self):
        cmd = 'orca orchestration worker-start --agent claude --spec "You are fullstack-dev. Fix the thing."'
        self.assertDenied(cmd, "issue number")

    def test_review_worker_not_gated(self):
        cmd = 'orca orchestration worker-start --agent claude --spec "You are qa-sdet. Review #6936."'
        self.assertAllowed(cmd)

    def test_gh_failure_lets_the_command_through(self):
        self.gh_fails = True
        self.assertAllowed(self.BUILD)


class GrillGateRepo(Gate):
    """A spec naming dotfiles#<n> reads that issue in the dotfiles repo, not the project's own."""
    def setUp(self):
        super().setUp()
        previous = os.environ.get("DOTFILES_REPO")
        os.environ["DOTFILES_REPO"] = "acme/dotfiles"
        self.addCleanup(lambda: os.environ.pop("DOTFILES_REPO", None) if previous is None
                        else os.environ.__setitem__("DOTFILES_REPO", previous))

    def spec(self, ref):
        return f'orca orchestration worker-start --agent claude --worktree new-child --spec "You are fullstack-dev. Ticket {ref}"'

    def reset_log(self):
        if os.path.exists(self.gh_log):
            os.remove(self.gh_log)

    def test_dotfiles_issue_is_read_in_the_dotfiles_repo(self):
        for ref in ("dotfiles#522", "acme/dotfiles#522"):
            self.reset_log()
            self.issue["comments"] = [{"body": "Owner approved the grill results."}]
            self.assertAllowed(self.spec(ref))
            calls = self.gh_calls()
            self.assertEqual(len(calls), 1, calls)
            self.assertIn("issue view 522", calls[0])
            self.assertIn("-R acme/dotfiles", calls[0])

    def test_dotfiles_issue_without_approval_denied_naming_the_repo(self):
        self.assertDenied(self.spec("dotfiles#522"), "acme/dotfiles#522")

    def test_bare_issue_number_has_no_repo_flag(self):
        for ref in ("#7114", "project#7114", "acme/project#7114"):
            self.reset_log()
            self.assertDenied(self.spec(ref), "#7114")
            calls = self.gh_calls()
            self.assertEqual(len(calls), 1, calls)
            self.assertIn("issue view 7114", calls[0])
            self.assertNotIn("-R", calls[0])

    def test_worktree_selector_stays_on_this_repo(self):
        cmd = 'orca orchestration worker-start --agent claude --worktree issue:4242 --spec "You are fullstack-dev. See dotfiles#522"'
        self.assertDenied(cmd, "#4242")
        self.assertNotIn("-R", self.gh_calls()[0])


class CursorWorkerScript(Gate):
    """start-cursor-worker.sh takes the same grill check; its --spec is a brief file."""
    SCRIPT = "~/dotfiles/script/start-cursor-worker.sh --run r1 --title t --model composer-2.5 --from term_abc --name n --repo id:x"

    def write_brief(self, text):
        with open(os.path.join(self.home, "brief.md"), "w") as f:
            f.write(text)

    def test_build_brief_without_approval_denied(self):
        self.write_brief("You are fullstack-dev. Ticket #7114\n")
        self.assertDenied(f"{self.SCRIPT} --spec brief.md", "#7114")

    def test_build_brief_with_approval_allowed(self):
        self.write_brief("You are fullstack-dev. Ticket #7114\n")
        self.issue["comments"] = [{"body": "Owner approved the grill results."}]
        self.assertAllowed(f"{self.SCRIPT} --spec brief.md")

    def test_unreadable_brief_is_denied(self):
        self.assertDenied(f"{self.SCRIPT} --spec missing.md", "could not be read")

    def test_brief_without_a_build_role_passes(self):
        self.write_brief("You are qa-sdet. Review #7114.\n")
        self.assertAllowed(f"{self.SCRIPT} --spec brief.md")

    def test_remote_run_is_not_denied_for_a_missing_lead(self):
        # The script reads the lead from ORCA_TERMINAL_HANDLE when --from is absent.
        self.write_brief("You are qa-sdet. Review #7114.\n")
        self.assertAllowed(f"{self.SCRIPT.replace('--from term_abc', '')} --spec brief.md --on remote-host")


class OwningLead(Gate):
    REVIEW = 'orca orchestration worker-start --agent claude --spec "You are qa-sdet. Review #6936."'

    def test_remote_worker_without_lead_denied(self):
        for flag in ("--environment bluedevil", "--on bluedevil", "--pairing-code orca://pair?x=1"):
            self.assertDenied(f"{self.REVIEW} {flag}", "owning lead")

    def test_remote_worker_with_lead_allowed(self):
        self.assertAllowed(f"{self.REVIEW} --environment bluedevil --from term_abc")

    def test_remote_worker_with_lead_equals_form_allowed(self):
        self.assertAllowed(f"{self.REVIEW} --on bluedevil --from=term_abc")

    def test_local_worker_without_lead_allowed(self):
        self.assertAllowed(self.REVIEW)


class CompactReminder(unittest.TestCase):
    def command(self):
        with open(SETTINGS) as f:
            groups = json.load(f)["hooks"]["SessionStart"]
        return next(h["command"] for g in groups if g["matcher"] == "compact" for h in g["hooks"])

    def test_checklist_replaces_the_rescan_advice(self):
        text = self.command()
        self.assertNotIn("Do not re-scan", text)
        for needle in (".claude/agents/<role>.md", ".agents/skills/crew/OPERATIONS.md",
                       "Pre-build grill gate", "docs/agents/team.md",
                       "do not raise host or provider caps",
                       "do not commit or open a PR while the owner is discussing"):
            self.assertIn(needle, text)

    def test_command_runs_and_prints_the_checklist(self):
        out = subprocess.run(["sh", "-c", self.command()], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        self.assertIn("OPERATIONS.md", out.stdout)


if __name__ == "__main__":
    unittest.main()
