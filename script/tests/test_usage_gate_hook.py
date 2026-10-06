import json, os, subprocess, sys, tempfile, time, unittest
from datetime import datetime
HOOK = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
FUT = time.time() + 3 * 86400


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, self.codex = self.tmp.name + "/state", self.tmp.name + "/codex"
        os.makedirs(self.state); os.makedirs(self.codex + "/2026/10/06")

    def tearDown(self):
        self.tmp.cleanup()

    def claude(self, pct, baseline=None):
        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT}}, open(self.state + "/claude-rate-limits.json", "w"))
        if baseline is not None:
            today = datetime.now().strftime("%Y-%m-%d")
            json.dump({"date": today, "baseline": baseline, "resets_at": FUT}, open(self.state + "/claude.json", "w"))

    def codex_reading(self, pct):
        ev = {"timestamp": "x", "payload": {"rate_limits": {"primary": {"used_percent": pct, "window_minutes": 10080, "resets_at": FUT}}}}
        open(self.codex + "/2026/10/06/rollout-a.jsonl", "w").write(json.dumps(ev) + "\n")

    def run_hook(self, command, tool="Bash"):
        env = dict(os.environ, USAGE_GATE_STATE=self.state, USAGE_GATE_CODEX_SESSIONS=self.codex)
        r = subprocess.run([sys.executable, HOOK], input=json.dumps({"tool_name": tool, "tool_input": {"command": command}}),
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        deny = json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"] if r.stdout.strip() else None
        return deny, r.stderr

    def test_allowed_under_cap(self):
        self.claude(11)
        self.assertEqual(self.run_hook("orca orchestration worker-start --task t --agent claude --json"), (None, ""))

    def test_blocked_at_weekly_ceiling(self):
        self.codex_reading(100)
        deny, _ = self.run_hook("orca orchestration worker-start --task t --worktree current --agent codex")
        self.assertIn("blocked codex: weekly ceiling", deny)
        self.assertIn("Resets ", deny)
        self.assertNotIn("Resets unknown", deny)

    def test_blocked_at_daily_cap(self):
        self.claude(52, baseline=40)
        deny, _ = self.run_hook('orca orchestration worker-start --spec "fix x; then y" --agent=claude')
        self.assertIn("blocked claude: daily cap", deny)

    def test_one_blocked_start_in_a_chain_blocks_the_command(self):
        self.claude(11); self.codex_reading(100)
        deny, _ = self.run_hook("orca orchestration worker-start --task a --agent claude && "
                                "orca orchestration worker-start --task b \\\n  --agent codex")
        self.assertIn("codex", deny); self.assertNotIn("claude", deny)

    def test_unknown_provider_passes_with_warning(self):
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent cursor")
        self.assertIsNone(deny)
        self.assertIn("no usage reading for agent cursor", err)

    def test_no_reading_passes_with_warning(self):
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent claude")
        self.assertIsNone(deny)
        self.assertIn("gate exit 4", err)

    def test_other_commands_pass_without_running_the_gate(self):
        self.codex_reading(100)
        for cmd in ("git status", "orca orchestration check --terminal x --json", "grep worker-start notes.md"):
            self.assertEqual(self.run_hook(cmd), (None, ""))
        self.assertEqual(self.run_hook("orca orchestration worker-start --agent codex", tool="Read"), (None, ""))
        self.assertFalse(os.path.exists(self.state + "/codex.json"))


if __name__ == "__main__":
    unittest.main()
