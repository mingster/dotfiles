import json, os, subprocess, sys, tempfile, time, unittest
from datetime import datetime, timezone
HOOK = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
FUT = time.time() + 3 * 86400


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, self.codex = self.tmp.name + "/state", self.tmp.name + "/codex"
        os.makedirs(self.state); os.makedirs(self.codex + "/2026/10/06")

    def tearDown(self):
        self.tmp.cleanup()

    def claude(self, pct, baseline=None, written_at=None):
        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT}, "_written_at": written_at or time.time()},
                  open(self.state + "/claude-rate-limits.json", "w"))
        if baseline is not None:
            today = datetime.now().strftime("%Y-%m-%d")
            json.dump({"date": today, "baseline": baseline, "resets_at": FUT}, open(self.state + "/claude.json", "w"))

    def codex_reading(self, pct):
        ev = {"timestamp": datetime.now(timezone.utc).isoformat(), "payload": {"rate_limits": {"primary": {"used_percent": pct, "window_minutes": 10080, "resets_at": FUT}}}}
        open(self.codex + "/2026/10/06/rollout-a.jsonl", "w").write(json.dumps(ev) + "\n")

    def run_hook(self, command, tool="Bash"):
        env = dict(os.environ, USAGE_GATE_STATE=self.state, USAGE_GATE_CODEX_SESSIONS=self.codex, USAGE_GATE_ORCA="false")
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
        self.assertIn("Resets " + time.strftime("%a %d %b %H:%M %Z", time.localtime(FUT)) + " (local time)", deny)

    def test_blocked_at_daily_cap(self):
        self.claude(65, baseline=40)  # 25 spent; cap = 55 left over about 3.5 days
        deny, _ = self.run_hook('orca orchestration worker-start --spec "fix x; then y" --agent=claude')
        self.assertIn("blocked claude: daily cap", deny)
        self.assertIn("00:00", deny)  # local midnight, before the weekly reset

    def test_agent_from_a_shell_variable_or_loop_is_gated(self):
        self.codex_reading(100)
        for cmd in ('A=codex; orca orchestration worker-start --task t --agent "$A"',
                    "for a in claude codex; do orca orchestration worker-start --task t --agent ${a}; done",
                    "(orca orchestration worker-start --task t --agent codex)"):
            self.assertIn("blocked codex", self.run_hook(cmd)[0] or "", cmd)

    def test_heredoc_text_is_not_a_command(self):
        self.codex_reading(100)
        cmd = "git commit -F - <<'EOF'\nDocs: don't run orca orchestration worker-start --agent codex\nEOF"
        self.assertEqual(self.run_hook(cmd), (None, ""))

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

    def test_stale_reading_at_ceiling_still_blocks_before_reset(self):
        self.claude(99, written_at=time.time() - 7 * 3600)
        deny, _ = self.run_hook("orca orchestration worker-start --task t --agent claude")
        self.assertIn("weekly ceiling", deny)

    def test_stale_reading_under_ceiling_passes_with_warning(self):
        self.claude(50, written_at=time.time() - 7 * 3600)
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
