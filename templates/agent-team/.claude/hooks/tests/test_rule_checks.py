"""Tests for .claude/hooks/rule-checks.py, the mechanical CLAUDE.md and AGENTS.md rules.

Run from the repo root: python3 -m unittest discover -s templates/agent-team/.claude/hooks/tests
The hook runs as Claude Code does (JSON on stdin).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HOOKS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(HOOKS, "rule-checks.py")
SETTINGS = os.path.join(os.path.dirname(HOOKS), "settings.json")
NAME = "Claude " + "Code"


class RuleChecksTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="rule-checks-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def run_hook(self, event, tool, tool_input, process_cwd=None):
        payload = {"hook_event_name": event, "tool_name": tool, "tool_input": tool_input, "cwd": self.dir}
        out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), text=True,
                             capture_output=True, timeout=20, cwd=process_cwd)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)["hookSpecificOutput"] if out.stdout.strip() else None

    def bash(self, command):
        return self.run_hook("PreToolUse", "Bash", {"command": command})

    def assert_denied(self, result, needle=""):
        self.assertIsNotNone(result)
        self.assertEqual(result["permissionDecision"], "deny")
        self.assertIn(needle, result["permissionDecisionReason"])

    # Row 1: assistant product name in PR or issue text
    def test_product_name_in_pr_body_is_denied(self):
        self.assert_denied(self.bash(f'gh pr create --title "x" --body "Built with {NAME}"'), "product name")

    def test_product_name_in_issue_comment_heredoc_is_denied(self):
        self.assert_denied(self.bash(f"gh issue comment 5 --body \"$(cat <<'EOF'\nmade by {NAME}\nEOF\n)\""))

    def test_product_name_in_title_is_denied(self):
        self.assert_denied(self.bash(f'gh pr edit 3 --title "{NAME} fix"'))

    def test_product_name_in_body_file_is_denied(self):
        path = os.path.join(self.dir, "body.md")
        with open(path, "w") as f:
            f.write(f"Generated with {NAME}\n")
        self.assert_denied(self.bash(f"gh pr create --title x --body-file {path}"))

    def test_clean_pr_body_is_allowed(self):
        self.assertIsNone(self.bash('gh pr create --title "x" --body "Fixes the hook"'))

    def test_clean_body_file_is_allowed(self):
        path = os.path.join(self.dir, "body.md")
        with open(path, "w") as f:
            f.write("Plain text\n")
        self.assertIsNone(self.bash(f"gh pr create --title x --body-file {path}"))

    def test_product_name_outside_gh_text_commands_is_allowed(self):
        self.assertIsNone(self.bash(f'echo "{NAME}"'))
        self.assertIsNone(self.bash(f'gh pr view 3 --json title # {NAME}'))

    # Row 2: Test plan heading
    def test_test_plan_heading_is_denied(self):
        self.assert_denied(self.bash('gh pr create --title x --body "## Why\nx\n\n## Test plan\n- run"'), "Test plan")

    def test_test_plan_heading_in_body_file_is_denied(self):
        path = os.path.join(self.dir, "body.md")
        with open(path, "w") as f:
            f.write("## Why\nx\n### Test Plan\n- run\n")
        self.assert_denied(self.bash(f"gh pr edit 2 --body-file {path}"), "Test plan")

    def test_test_plan_in_prose_is_allowed(self):
        self.assertIsNone(self.bash('gh pr create --title x --body "The test plan section is gone"'))

    # Row 3: dashes as punctuation in markdown
    def elsewhere(self):
        path = tempfile.mkdtemp(prefix="elsewhere-")
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def write_md(self, content, name="notes.md"):
        return self.run_hook("PostToolUse", "Write", {"file_path": os.path.join(self.dir, name), "content": content})

    def test_em_dash_between_words_warns_with_line(self):
        result = self.write_md("# T\n\nThis is fine — mostly.\n")
        self.assertIn("line 3", result["additionalContext"])

    def test_spaced_hyphen_and_en_dash_warn(self):
        self.assertIsNotNone(self.write_md("one - two\n"))
        self.assertIsNotNone(self.write_md("one – two\n"))

    def test_list_item_hyphen_is_not_a_dash(self):
        self.assertIsNone(self.write_md("- foo\n- bar baz\n  - nested\n"))

    def test_compound_hyphen_and_rule_are_not_dashes(self):
        self.assertIsNone(self.write_md("A well-known fix\n\n---\n\nnext\n"))

    def test_dash_in_code_block_or_inline_code_is_skipped(self):
        self.assertIsNone(self.write_md("```\nrun a - b\n```\nUse `a - b` here\n"))

    def test_dash_in_non_markdown_file_is_skipped(self):
        self.assertIsNone(self.write_md("a — b\n", name="x.txt"))

    def test_edit_checks_only_new_text(self):
        path = os.path.join(self.dir, "e.md")
        with open(path, "w") as f:
            f.write("old — dash\nnew line\n")
        result = self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "new line", "new_string": "fresh line"})
        self.assertIsNone(result)

    # Row 4: AGENTS.md length
    def test_agents_md_over_200_lines_warns_with_count(self):
        result = self.write_md("x\n" * 201, name="AGENTS.md")
        self.assertIn("201", result["additionalContext"])

    def test_agents_md_at_200_lines_is_allowed(self):
        self.assertIsNone(self.write_md("x\n" * 200, name="AGENTS.md"))

    def test_other_md_over_200_lines_is_allowed(self):
        self.assertIsNone(self.write_md("x\n" * 300, name="guide.md"))

    def test_edit_to_long_agents_md_warns(self):
        path = os.path.join(self.dir, "AGENTS.md")
        with open(path, "w") as f:
            f.write("x\n" * 250)
        result = self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "x", "new_string": "y"})
        self.assertIn("250", result["additionalContext"])

    def test_relative_agents_md_resolves_against_payload_cwd(self):
        with open(os.path.join(self.dir, "AGENTS.md"), "w") as f:
            f.write("x\n" * 205)
        result = self.run_hook("PostToolUse", "Edit", {"file_path": "AGENTS.md", "old_string": "x", "new_string": "y"},
                               process_cwd=self.elsewhere())
        self.assertIn("205", result["additionalContext"])

    # Row 3 with Edit: a dash is judged by its place in the whole file, not in new_string alone
    def test_edit_inside_open_fence_with_spaced_dash_is_allowed(self):
        path = os.path.join(self.dir, "fenced.md")
        with open(path, "w") as f:
            f.write("# T\n\n```\nx = a - b\n```\n")
        self.assertIsNone(self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "x = 1", "new_string": "x = a - b"}))

    def test_edit_outside_fence_with_spaced_dash_warns(self):
        path = os.path.join(self.dir, "plain.md")
        with open(path, "w") as f:
            f.write("# T\n\n```\ncode\n```\n\nfoo a - b\n")
        result = self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "foo", "new_string": "foo a - b"})
        self.assertIn("line 7", result["additionalContext"])

    def test_edit_ending_in_newline_does_not_flag_the_next_line(self):
        path = os.path.join(self.dir, "newline.md")
        with open(path, "w") as f:
            f.write("# T\n\nedited\nuntouched - dash\n")
        self.assertIsNone(self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "x", "new_string": "edited\n"}))

    def test_edit_without_dash_on_line_that_already_has_one_is_allowed(self):
        path = os.path.join(self.dir, "sameline.md")
        with open(path, "w") as f:
            f.write("# T\n\nold - dash fresh\n")
        self.assertIsNone(self.run_hook("PostToolUse", "Edit", {"file_path": path, "old_string": "x", "new_string": "fresh"}))

    # Row 5: CHANGELOG.md
    def test_changelog_edit_denied_when_fragments_dir_exists(self):
        os.mkdir(os.path.join(self.dir, "changelog.d"))
        result = self.run_hook("PreToolUse", "Edit", {"file_path": os.path.join(self.dir, "CHANGELOG.md"), "old_string": "a", "new_string": "b"})
        self.assert_denied(result, "changelog.d")

    def test_relative_changelog_path_resolves_against_payload_cwd(self):
        os.mkdir(os.path.join(self.dir, "changelog.d"))
        result = self.run_hook("PreToolUse", "Edit", {"file_path": "CHANGELOG.md", "old_string": "a", "new_string": "b"},
                               process_cwd=self.elsewhere())
        self.assert_denied(result, "changelog.d")

    def test_changelog_edit_allowed_without_fragments_dir(self):
        result = self.run_hook("PreToolUse", "Write", {"file_path": os.path.join(self.dir, "CHANGELOG.md"), "content": "x"})
        self.assertIsNone(result)

    def test_fragment_write_is_allowed(self):
        os.mkdir(os.path.join(self.dir, "changelog.d"))
        result = self.run_hook("PreToolUse", "Write", {"file_path": os.path.join(self.dir, "changelog.d", "1-x.md"), "content": "x"})
        self.assertIsNone(result)

    # Wiring and speed
    def test_settings_register_the_hook_once_per_event(self):
        with open(SETTINGS) as f:
            hooks = json.load(f)["hooks"]
        for event in ("PreToolUse", "PostToolUse"):
            count = sum("rule-checks.py" in h["command"] for g in hooks[event] for h in g["hooks"])
            self.assertEqual(count, 1, event)

    def test_hook_adds_under_100ms(self):
        payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}})
        runs = []
        for _ in range(5):
            start = time.perf_counter()
            subprocess.run([sys.executable, HOOK], input=payload, text=True, capture_output=True, timeout=20)
            runs.append(time.perf_counter() - start)
        self.assertLess(min(runs), 0.1)


if __name__ == "__main__":
    unittest.main()
