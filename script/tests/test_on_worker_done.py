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
    def dispatch(self, author, only_author_available=False):
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
            log = root / "orca.json"
            env = {**os.environ, "ON_WORKER_DONE_USAGE_GATE": str(gate),
                   "ORCA_CLI_COMMAND": str(orca), "USAGE_GATE_PRESETS": str(presets),
                   "TEST_AUTHOR": author, "TEST_ONLY_AUTHOR": str(int(only_author_available)),
                   "TEST_ORCA_LOG": str(log), "TMPDIR": tmp}
            result = subprocess.run([
                "bash", str(SCRIPT / "on-worker-done.sh"), "--repo", "o/n",
                "--pr", "42", "--head", "a" * 40, "--author-family", author,
                "--worktree", tmp, "--run", "run_test",
            ], env=env, text=True, capture_output=True, timeout=30)
            return result, json.loads(log.read_text()) if log.exists() else None

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
