#!/usr/bin/env python3
"""Exercise reviewer dispatch with real picker logic and stubbed usage/Orca."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1]


class ReviewerDispatch(unittest.TestCase):
    def dispatch(self, author, only_author_available=False, receipts=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            presets = root / "presets.json"
            presets.write_text(json.dumps({"roles": {"reviewer": {"chain": [
                {"provider": "codex", "model": "gpt-test"},
                {"provider": "cursor", "model": "composer-test"},
                {"provider": "antigravity", "model": "gemini-test"},
                {"provider": "claude", "model": "sonnet"},
            ]}}}))
            gate = root / "gate"
            gate.write_text(f'''#!/usr/bin/env python3
import importlib.util
import os
import sys
spec = importlib.util.spec_from_file_location("usage_gate", {str(SCRIPT / "usage-gate.py")!r})
ug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ug)
def usage(provider, *args, **kwargs):
    author = os.environ["TEST_AUTHOR"]
    blocked = os.environ["TEST_ONLY_AUTHOR"] == "1" and provider != author
    room = 90 if provider == author else {{"codex": 60, "cursor": 50, "antigravity": 40, "claude": 30}}[provider]
    return {{"verdict": "blocked" if blocked else "allowed", "weekly_used": 100 if blocked else 95 - room, "ceiling": 95}}
ug.run = usage
ug.antigravity_models = lambda: None
sys.exit(ug.main())
''')
            gate.chmod(0o755)
            orca = root / "orca"
            orca.write_text('''#!/usr/bin/env python3
import json
import os
import sys
with open(os.environ["TEST_ORCA_LOG"], "w") as log:
    json.dump(sys.argv[1:], log)
''')
            orca.chmod(0o755)
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\nimport os\nprint(os.environ['TEST_COMMENTS'])\n")
            gh.chmod(0o755)
            if receipts is None:
                receipts = ["Checks: PASS head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 0\nTests executed: 2\nLoad errors: 0\n"]
            log = root / "orca.json"
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "TEST_COMMENTS": json.dumps({"comments": [{"body": body} for body in receipts]}),
                   "ON_WORKER_DONE_USAGE_GATE": str(gate),
                   "ORCA_CLI_COMMAND": str(orca), "USAGE_GATE_PRESETS": str(presets),
                   "TEST_AUTHOR": author, "TEST_ONLY_AUTHOR": str(int(only_author_available)),
                   "TEST_ORCA_LOG": str(log), "TMPDIR": tmp}
            result = subprocess.run([
                "bash", str(SCRIPT / "on-worker-done.sh"), "--repo", "o/n",
                "--pr", "42", "--head", "a" * 40, "--author-family", author,
                "--worktree", tmp, "--run", "run_test",
            ], env=env, text=True, capture_output=True, timeout=30)
            if result.returncode != 0:
                self.assertFalse(list(root.glob("reviewer-brief.*")), "refused QA must not create a brief")
            return result, json.loads(log.read_text()) if log.exists() else None

    def test_zero_executed_refuses_start(self):
        receipt = "Checks: PASS head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 0\nTests executed: 0\nLoad errors: 0\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a" * 40, result.stderr)
        self.assertIn("Tests executed: 0", result.stderr)
        self.assertIsNone(args)

    def test_load_errors_refuse_even_with_executed_tests(self):
        receipt = "Checks: FAIL head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 1\nTests executed: 2\nLoad errors: 1\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a" * 40, result.stderr)
        self.assertIn("Load errors: 1", result.stderr)
        self.assertIsNone(args)

    def test_failed_checks_with_executed_tests_refuse_start(self):
        receipt = "Checks: FAIL head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 1\nTests executed: 3\nLoad errors: 0\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(args)

    def test_failed_non_test_check_refuses_start(self):
        receipt = "Checks: FAIL head=" + "a" * 40 + "\nCommand: check-doc-links\nResult: exit 1\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(args)

    def test_failed_checks_refusal_names_head_and_status(self):
        receipt = "Checks: FAIL head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 1\nTests executed: 3\nLoad errors: 0\n"
        result, _ = self.dispatch("claude", receipts=[receipt])
        self.assertIn("QA start refused head=" + "a" * 40 + ": Checks: FAIL", result.stderr)

    def test_docs_check_without_test_command_proceeds(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "a" * 40 + "\nCommand: check-doc-links\nResult: exit 0\n"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)

    def test_receipt_for_another_head_refuses_start(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "b" * 40 + "\nTests executed: 2\nLoad errors: 0\n"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a" * 40, result.stderr)
        self.assertIn("no receipt", result.stderr)
        self.assertIsNone(args)

    def test_later_zero_command_cannot_hide_behind_clean_command(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "a" * 40 + "\nTests executed: 2\nLoad errors: 0\nTests executed: 0\nLoad errors: 0\n"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(args)

    def test_latest_exact_head_receipt_decides_start(self):
        prefix = "Checks: PASS head=" + "a" * 40 + "\nCommand: bun test\n"
        clean = prefix + "Tests executed: 2\nLoad errors: 0\n"
        zero = prefix + "Tests executed: 0\nLoad errors: 0\n"
        for receipts, allowed in (([zero, clean], True), ([clean, zero], False)):
            with self.subTest(allowed=allowed):
                result, args = self.dispatch("claude", receipts=receipts)
                self.assertEqual(result.returncode == 0, allowed, result.stderr)
                self.assertEqual(args is not None, allowed)

    def test_incomplete_execution_metadata_refuses(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "a" * 40 + "\nTests executed: 2\n"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete test execution metadata", result.stderr)
        self.assertIsNone(args)

    def test_legacy_bun_receipt_without_counts_refuses(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 0\n"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test command has no execution metadata", result.stderr)
        self.assertIsNone(args)

    def assert_reviewer(self, author, expected):
        result, args = self.dispatch(author)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[:2], ["orchestration", "worker-start"])
        self.assertEqual(args[args.index("--agent") + 1], expected)

    def test_antigravity_author_dispatches_codex_reviewer(self):
        self.assert_reviewer("antigravity", "codex")

    def test_cursor_author_dispatches_antigravity_reviewer(self):
        self.assert_reviewer("cursor", "antigravity")

    def test_claude_and_codex_authors_dispatch_other_providers(self):
        for author, expected in (("claude", "codex"), ("codex", "cursor")):
            with self.subTest(author=author):
                self.assert_reviewer(author, expected)

    def test_only_author_available_starts_nothing(self):
        for author in ("claude", "cursor", "codex", "antigravity"):
            with self.subTest(author=author):
                result, args = self.dispatch(author, only_author_available=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cross-family unavailable", result.stderr)
                self.assertIsNone(args)


if __name__ == "__main__":
    unittest.main()
