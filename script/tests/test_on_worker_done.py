#!/usr/bin/env python3
"""Exercise reviewer dispatch with real picker logic and stubbed usage/Orca."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from qa_admission_fixture import NativeFixture


SCRIPT = Path(__file__).resolve().parents[1]


class ReviewerDispatch(unittest.TestCase):
    def dispatch(self, author, only_author_available=False, receipts=None, full_hosts=(), local=False,
                 configuration='explicit', author_model=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            presets = root / "presets.json"
            presets.write_text(json.dumps({"roles": {"reviewer": {"chain": [
                {"provider": "cursor", "model": "grok-4.7-high"},
                {"provider": "claude", "model": "sonnet"},
                {"provider": "antigravity", "model": "gemini-4-argon-high"},
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
    room = 90 if provider == author else {{"cursor": 60, "antigravity": 50, "claude": 30}}[provider]
    return {{"verdict": "blocked" if blocked else "allowed", "weekly_used": 100 if blocked else 95 - room, "ceiling": 95}}
ug.run = usage
ug.antigravity_models = lambda: None
sys.exit(ug.main())
''')
            gate.chmod(0o755)
            wt = root / "wt"
            wt.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=wt, check=True,
                           env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
            subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=wt, check=True)
            subprocess.run(["git", "config", "user.name", "Fixture"], cwd=wt, check=True)
            (wt / "README.md").write_text("fixture\n")
            subprocess.run(["git", "add", "README.md"], cwd=wt, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=wt, check=True)
            head_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=wt, text=True).strip()
            native = NativeFixture(root, path=str(wt))
            for host in ('alpha', 'beta'):
                for row in native.data[host]['worktrees']['worktrees']:
                    row['git']['head'] = head_sha
                    row['head'] = head_sha
            native.occupy('alpha', 1)
            for h in full_hosts: native.occupy(h, 2)
            if local:
                native.config['local_host'] = 'alpha'
                native.data['environments'] = [r for r in native.data['environments'] if r['name'] != 'alpha']
                native.data['local'] = native.data.pop('alpha')
            local_repos = native.data.setdefault('local', {}).setdefault('repos', [{'id': 'repo-id'}])
            for entry in local_repos:
                entry.update({'kind': 'git', 'path': str(wt)})
            gh = root / "gh"
            gh.write_text("""#!/usr/bin/env python3
import json, os, sys
if len(sys.argv) >= 4 and sys.argv[1:3] == ['pr', 'view']:
    joined = ' '.join(sys.argv)
    if 'headRefName' in joined:
        print(json.dumps({'headRefName': 'feature/pr-42'}))
    elif 'comments' in joined:
        print(os.environ['TEST_COMMENTS'])
    else:
        print(os.environ['TEST_COMMENTS'])
""")
            gh.chmod(0o755)
            cursor_stub = root / "cursor-stub.sh"
            cursor_stub.write_text("""#!/usr/bin/env bash
set -euo pipefail
model="" run="" spec="" title="" from="" repo="" on=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    --run) run=$2; shift 2 ;;
    --spec) spec=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --on) on=$2; shift 2 ;;
    *) shift ;;
  esac
done
args=(orchestration worker-start --run "$run" --spec "$(cat "$spec")" --agent cursor --model "$model"
  --worktree "$repo" --task-title "$title" --from "$from" --json)
[ -z "${on:-}" ] || args+=(--on "$on")
exec "${ORCA_CLI_COMMAND:-orca}" "${args[@]}"
""")
            cursor_stub.chmod(0o755)
            if receipts is None:
                receipts = [f"Checks: PASS head={head_sha}\nCommand: bun test\nResult: exit 0\nTests executed: 2\nLoad errors: 0\n"]
            else:
                legacy = "a" * 40
                if head_sha != legacy:
                    receipts = [body.replace(legacy, head_sha) for body in receipts]
            log = root / "launch.json"
            env = {**native.env(), "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "TEST_COMMENTS": json.dumps({"comments": [{"body": body} for body in receipts]}),
                   "ON_WORKER_DONE_USAGE_GATE": str(gate),
                   "USAGE_GATE_PRESETS": str(presets),
                   "ON_WORKER_DONE_CURSOR_START": str(cursor_stub),
                   "ORCA_TERMINAL_HANDLE": "term_fixture",
                   "TEST_AUTHOR": author, "TEST_ONLY_AUTHOR": str(int(only_author_available)),
                   "TEST_ORCA_LOG": str(log), "TMPDIR": tmp}
            if configuration != 'explicit':
                env['HOME'] = tmp
                env.pop('ON_WORKER_DONE_FLEET_CONFIG', None)
                if configuration != 'missing':
                    config = root / '.config/fleet-watch/config.json'
                    config.parent.mkdir(parents=True)
                    config.write_text(json.dumps(native.config if configuration == 'default' else {}))
            result = subprocess.run([
                "bash", str(SCRIPT / "on-worker-done.sh"), "--repo", "o/n",
                "--pr", "42", "--head", head_sha,
                *(["--author-provider", author, "--author-model", author_model] if author_model
                  else ["--author-family", author]),
                "--worktree", str(wt), "--run", "run_test",
            ], env=env, text=True, capture_output=True, timeout=30)
            if result.returncode != 0:
                self.assertFalse(list(root.glob("reviewer-brief.*")), "refused QA must not create a brief")
            self._head_sha = head_sha
            return result, json.loads(log.read_text()) if log.exists() else None

    def head(self):
        return getattr(self, "_head_sha", "a" * 40)

    def test_default_installed_configuration_path_preserves_ordinary_launches(self):
        for author in ('claude', 'cursor', 'antigravity', 'gemini'):
            with self.subTest(author=author):
                result, args = self.dispatch(author, configuration='default')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(args[args.index('--on')+1], 'alpha-saved')
                self.assertEqual(args[args.index('--worktree')+1], 'id:repo-id')
                self.assertEqual(args[args.index('--agent')+1], 'cursor')
                self.assertEqual(args[args.index('--model')+1], 'grok-4.7-high')

    def test_unconfigured_installed_invocation_refuses_without_launch(self):
        for configuration in ('missing', 'unknown'):
            with self.subTest(configuration=configuration):
                result, args = self.dispatch('claude', configuration=configuration)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('fleet config', result.stderr)
                self.assertIsNone(args)

    def test_real_admission_pins_native_launch_argv(self):
        result, args = self.dispatch('claude')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index('--on')+1], 'alpha-saved')
        self.assertEqual(args[args.index('--worktree')+1], 'id:repo-id')
        self.assertEqual(args[args.index('--model')+1], 'grok-4.7-high')

    def test_full_host_fallback_pins_actual_native_argv(self):
        result, args = self.dispatch('claude', full_hosts=('alpha',))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index('--on')+1], 'beta-saved')
        self.assertEqual(args[args.index('--worktree')+1], 'id:repo-id')
        self.assertEqual(args[args.index('--model')+1], 'grok-4.7-high')

    def test_all_full_starts_nothing_and_reports_counts(self):
        result, args = self.dispatch('claude', full_hosts=('alpha', 'beta'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(args)
        self.assertIn('alpha 2/2', result.stderr)
        self.assertIn('beta 2/2', result.stderr)

    def test_local_launch_pins_identity_without_saved_server_guess(self):
        result, args = self.dispatch('claude', local=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('--on', args)
        self.assertEqual(args[args.index('--worktree')+1], 'id:repo-id')

    def test_zero_executed_refuses_start(self):
        receipt = "Checks: PASS head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 0\nTests executed: 0\nLoad errors: 0\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.head(), result.stderr)
        self.assertIn("Tests executed: 0", result.stderr)
        self.assertIsNone(args)

    def test_load_errors_refuse_even_with_executed_tests(self):
        receipt = "Checks: FAIL head=" + "a" * 40 + "\nCommand: bun test\nResult: exit 1\nTests executed: 2\nLoad errors: 1\n"
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.head(), result.stderr)
        self.assertIn("Checks: FAIL", result.stderr)
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
        self.assertIn("QA start refused head=" + self.head() + ": Checks: FAIL", result.stderr)

    def test_docs_check_without_test_command_proceeds(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "a" * 40 + "\nCommand: check-doc-links\nResult: exit 0\n"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)

    def test_receipt_for_another_head_starts_qa_with_checks_pending(self):
        result, args = self.dispatch("claude", receipts=["Checks: PASS head=" + "b" * 40 + "\nTests executed: 2\nLoad errors: 0\n"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)
        brief = args[args.index("--spec") + 1]
        self.assertIn("Checks are pending: no Checks receipt exists for head " + self.head(), brief)

    def test_no_receipt_at_all_starts_qa_with_checks_pending(self):
        result, args = self.dispatch("claude", receipts=[])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)
        self.assertIn("Checks are pending", args[args.index("--spec") + 1])

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

    def test_skipped_bun_test_step_starts_qa(self):
        receipt = (
            "Checks: PASS head=" + "a" * 40 + "\n"
            "Command: bun test\n"
            "Skipped: no app code changed\n"
        )
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)

    def test_ran_bun_test_without_counts_still_refuses(self):
        result, args = self.dispatch(
            "claude",
            receipts=[
                "Checks: PASS head="
                + "a" * 40
                + "\nCommand: bun test\nResult: exit 0\nbun test v1.2.3 (abc)\n"
            ],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test command has no execution metadata", result.stderr)
        self.assertIsNone(args)

    def test_scoped_runner_line_then_bun_test_with_counts_starts_qa(self):
        head = "a" * 40
        receipt = (
            f"Checks: PASS head={head}\n"
            'Command: python3 run-scoped-tests.py --runner "bun test --isolate" --components lint\n'
            "Result: exit 0\n"
            "Command: bun test\n"
            "Result: exit 0\n"
            "Tests executed: 4\n"
            "Load errors: 0\n"
        )
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)

    def test_scoped_tests_zero_line_then_bun_test_with_counts_starts_qa(self):
        head = "a" * 40
        receipt = (
            f"Checks: PASS head={head}\n"
            'Command: python3 run-scoped-tests.py --runner "bun test --isolate" --components lint\n'
            "Result: exit 0\n"
            "Scoped tests: 0\n"
            "Command: bun test\n"
            "Result: exit 0\n"
            "Tests executed: 4\n"
            "Load errors: 0\n"
        )
        result, args = self.dispatch("claude", receipts=[receipt])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(args)

    def assert_reviewer(self, author, expected):
        result, args = self.dispatch(author)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[:2], ["orchestration", "worker-start"])
        self.assertEqual(args[args.index("--agent") + 1], expected)

    def test_antigravity_author_dispatches_cursor_reviewer(self):
        self.assert_reviewer("antigravity", "cursor")

    def test_cursor_author_dispatches_cursor_grok_reviewer(self):
        result, args = self.dispatch("cursor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("--agent") + 1], "cursor")
        self.assertEqual(args[args.index("--model") + 1], "grok-4.7-high")

    def test_claude_and_gemini_authors_dispatch_other_providers(self):
        for author in ("claude", "gemini"):
            with self.subTest(author=author):
                self.assert_reviewer(author, "cursor")

    def test_antigravity_claude_author_with_claude_blocked_picks_gemini_on_antigravity(self):
        result, args = self.dispatch("antigravity", only_author_available=True,
                                     author_model="claude-sonnet-5-5-medium")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("--agent") + 1], "antigravity")
        self.assertEqual(args[args.index("--model") + 1], "gemini-4-argon-high")

    def test_only_author_available_starts_nothing(self):
        for author in ("claude", "gemini", "antigravity"):
            with self.subTest(author=author):
                result, args = self.dispatch(author, only_author_available=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cross-family unavailable", result.stderr)
                self.assertIsNone(args)

    def test_only_cursor_available_still_cross_reviews_with_grok(self):
        result, args = self.dispatch("cursor", only_author_available=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("--model") + 1], "grok-4.7-high")


if __name__ == "__main__":
    unittest.main()
