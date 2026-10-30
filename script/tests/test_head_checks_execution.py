#!/usr/bin/env python3
"""Verify execution receipts through real Bun runs in disposable Git repositories."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1]


class ExecutionReceipt(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "fixture"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "base").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        (self.repo / ".agents").mkdir()
        self.bun = shutil.which("bun")
        self.assertIsNotNone(self.bun, "real Bun is required")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def run_checks(self, command, cap=20000):
        (self.repo / ".agents/head-checks.conf").write_text(command + "\n")
        self.git("add", ".")
        self.git("commit", "-qm", "head")
        result = subprocess.run([
            "bash", str(SCRIPT / "head-checks.sh"), "--repo", str(self.repo),
            "--ref", "HEAD", "--base", self.base,
        ], env={**os.environ, "HOME": str(self.root / "home"),
                "HEAD_CHECKS_GATE_HELD": "1", "HEAD_CHECKS_SLOTS": "1",
                "HEAD_CHECKS_RECEIPT_CAP": str(cap)}, text=True, capture_output=True)
        return result

    def test_pass_and_fail_summaries_count_executed_tests(self):
        (self.repo / "sample.test.ts").write_text(
            "import {test,expect} from 'bun:test';\n"
            "test('one',()=>expect(1).toBe(1));\n"
            "test('two',()=>expect(2).toBe(2));\n"
            "test('three',()=>expect(3).toBe(4));\n")
        result = self.run_checks(f"{self.bun} test ./sample.test.ts")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Tests executed: 3\nLoad errors: 0\n", result.stdout)

    def test_module_load_error_is_counted(self):
        (self.repo / "sample.test.ts").write_text("import {test} from './missing-module'; test('missing', () => {});\n")
        result = self.run_checks(f"{self.bun} test ./sample.test.ts")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Tests executed: 1\nLoad errors: 1\n", result.stdout)

    def test_syntax_load_error_is_counted(self):
        (self.repo / "sample.test.ts").write_text("export const broken = ;\n")
        result = self.run_checks(f"{self.bun} test ./sample.test.ts")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Tests executed: 1\nLoad errors: 1\n", result.stdout)

    def test_skipped_only_run_records_zero_executed(self):
        (self.repo / "sample.test.ts").write_text(
            "import {test} from 'bun:test'; test.skip('skipped',()=>{});\n")
        result = self.run_checks(f"{self.bun} test ./sample.test.ts")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Tests executed: 0\nLoad errors: 0\n", result.stdout)

    def test_non_test_command_has_no_execution_metadata(self):
        result = self.run_checks("printf 'documentation checked\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Tests executed:", result.stdout)
        self.assertNotIn("Load errors:", result.stdout)

    def test_execution_metadata_survives_tail_and_receipt_cap(self):
        (self.repo / "sample.test.ts").write_text(
            "import {test,expect} from 'bun:test';\n"
            "test('one',()=>expect(1).toBe(1));\n")
        result = self.run_checks(f"{self.bun} test ./sample.test.ts; "
                                 "for i in {1..40}; do printf '%0300d\\n' 0; done", cap=700)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(result.stdout), 700)
        self.assertIn("Tests executed: 1\nLoad errors: 0\n", result.stdout)
        self.assertIn("Receipt cut", result.stdout)


if __name__ == "__main__":
    unittest.main()
