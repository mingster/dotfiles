import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile, time, unittest
from unittest import mock
from datetime import datetime, timezone
HOOK = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
FUT = time.time() + 3 * 86400


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state, self.codex = self.tmp.name + "/state", self.tmp.name + "/codex"
        self.presets = self.tmp.name + "/presets.json"
        with open(self.presets, "w") as f:
            json.dump({"roles": {"fullstack-dev": {"tier": "workhorse", "chain": [
                {"provider": "claude", "model": "sonnet"},
                {"provider": "codex", "model": "gpt-test"}]}}}, f)
        os.makedirs(self.tmp.name + "/bin")
        for command in ("security", "codex"):
            path = self.tmp.name + "/bin/" + command
            with open(path, "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            os.chmod(path, 0o755)
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
        env = dict(os.environ, HOME=self.tmp.name, PATH=self.tmp.name + "/bin:" + os.environ["PATH"], USAGE_GATE_STATE=self.state, USAGE_GATE_CODEX_SESSIONS=self.codex, USAGE_GATE_ORCA="false", USAGE_GATE_PRESETS=self.presets)
        r = subprocess.run([sys.executable, HOOK], input=json.dumps({"tool_name": tool, "tool_input": {"command": command}}),
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        deny = json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"] if r.stdout.strip() else None
        return deny, r.stderr

    def test_allowed_under_cap(self):
        self.claude(11)
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent claude --json")
        self.assertIsNone(deny)
        self.assertIn("no known role prefix", err)

    def test_blocked_at_weekly_ceiling(self):
        self.codex_reading(100)
        deny, _ = self.run_hook("orca orchestration worker-start --task t --worktree current --agent codex")
        self.assertIn("blocked codex: weekly ceiling", deny)
        self.assertIn("Resets " + time.strftime("%a %d %b %H:%M %Z", time.localtime(FUT)) + " (local time)", deny)

    def test_daily_cap_does_not_deny_a_start(self):
        self.claude(65, baseline=40)  # 25 spent; cap = 55 left over about 3.5 days
        deny, _ = self.run_hook('orca orchestration worker-start --spec "fix x; then y" --agent=claude')
        self.assertIsNone(deny)

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
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent unknown")
        self.assertIsNone(deny)
        self.assertIn("no usage reading for agent unknown", err)

    def run_stubbed_pool_hook(self, command, provider="antigravity"):
        spec = importlib.util.spec_from_file_location("hook", HOOK)
        hook = importlib.util.module_from_spec(spec)
        with mock.patch("sys.stdin", io.StringIO('{"tool_name":"Read"}')), \
                mock.patch("sys.exit"):
            spec.loader.exec_module(hook)

        def gate(argv, **kwargs):
            self.assertEqual(argv[:5], [sys.executable, hook.GATE, "check", "--provider", provider])
            allowed = argv[5:] == ["--model", "gemini-flash"]
            if argv[5:] == ["--model", "unknown-model"]:
                return mock.Mock(returncode=4, stdout=json.dumps({"reason": "unknown model"}))
            return mock.Mock(returncode=0 if allowed else 3, stdout=json.dumps({
                "weekly_used": 0 if allowed else 100, "ceiling": 95}))

        data = {"tool_name": "Bash", "tool_input": {"command": command}}
        with mock.patch("sys.stdin", io.StringIO(json.dumps(data))), \
                mock.patch.object(hook.subprocess, "run", side_effect=gate) as run, \
                mock.patch.object(hook, "routing", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            hook.main()
        return out.getvalue(), [call.args[0][5:] for call in run.call_args_list]

    def test_antigravity_gemini_allowed_while_claude_pool_blocked(self):
        for option in ("--model gemini-flash", "--model=gemini-flash", "--model 'gemini-flash'"):
            with self.subTest(option=option):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity " + option)
                self.assertEqual(out, "")
                self.assertEqual(checks, [["--model", "gemini-flash"]])

    def test_antigravity_claude_pool_still_denied(self):
        out, checks = self.run_stubbed_pool_hook(
            "orca orchestration worker-start --agent antigravity --model claude-sonnet")
        self.assertIn("blocked antigravity: weekly ceiling", out)
        self.assertEqual(checks, [["--model", "claude-sonnet"]])

    def test_antigravity_without_model_still_checks_worst_pool(self):
        out, checks = self.run_stubbed_pool_hook(
            "orca orchestration worker-start --agent antigravity")
        self.assertIn("blocked antigravity: weekly ceiling", out)
        self.assertEqual(checks, [[]])

    def test_antigravity_unknown_model_falls_back_to_worst_pool(self):
        for option in ("--model unknown-model", '--model "$M"'):
            with self.subTest(option=option):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity " + option)
                self.assertIn("blocked antigravity: weekly ceiling", out)
                self.assertEqual(checks[-1], [])

    def test_antigravity_chain_checks_each_model_and_model_less_start(self):
        for suffix, expected in (("--model claude-sonnet", ["--model", "claude-sonnet"]),
                                 ("", [])):
            with self.subTest(suffix=suffix):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity --model gemini-flash && "
                    "orca orchestration worker-start --agent antigravity " + suffix)
                self.assertIn("blocked antigravity: weekly ceiling", out)
                self.assertEqual(checks, [["--model", "gemini-flash"], expected])

    def test_other_providers_and_codex_launcher_do_not_forward_model(self):
        for provider in ("claude", "codex", "cursor"):
            with self.subTest(provider=provider):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent " + provider + " --model gemini-flash",
                    provider=provider)
                self.assertIn("blocked " + provider + ": weekly ceiling", out)
                self.assertEqual(checks, [[]])
        out, checks = self.run_stubbed_pool_hook(
            "script/start-codex-worker.sh --model gemini-flash", provider="codex")
        self.assertIn("blocked codex: weekly ceiling", out)
        self.assertEqual(checks, [[]])

    def cursor(self, pct, baseline):
        ends = datetime.fromtimestamp(FUT, timezone.utc).isoformat()
        json.dump({"billingCycleStart": "2026-09-25T00:00:00+00:00", "billingCycleEnd": ends,
                   "individualUsage": {"plan": {"enabled": True, "totalPercentUsed": pct}}},
                  open(self.state + "/summary.json", "w"))
        json.dump({"date": datetime.now().strftime("%Y-%m-%d"), "baseline": baseline, "resets_at": FUT.__float__()},
                  open(self.state + "/cursor.json", "w"))
        os.environ["USAGE_GATE_CURSOR_SUMMARY"] = self.state + "/summary.json"
        self.addCleanup(os.environ.pop, "USAGE_GATE_CURSOR_SUMMARY", None)

    def test_cursor_start_goes_through_the_gate(self):
        cmd = "orca orchestration worker-start --task t --agent cursor"
        self.cursor(40, 38)
        self.assertIsNone(self.run_hook(cmd)[0])
        self.cursor(95, 90)
        deny, _ = self.run_hook(cmd)
        self.assertIn("Usage gate blocked cursor", deny)

    def test_no_reading_passes_with_warning(self):
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent claude")
        self.assertIsNone(deny)
        self.assertIn("gate exit 4", err)

    def test_stale_reading_at_ceiling_still_blocks_before_reset(self):
        self.claude(99, written_at=time.time() - 7 * 3600)
        deny, _ = self.run_hook("orca orchestration worker-start --task t --agent claude")
        self.assertIsNone(deny)

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

    def test_start_must_use_pick_even_on_retry(self):
        self.claude(44, baseline=40)
        self.codex_reading(41)
        # Codex's first check has zero today spend, so it has more room.
        for retry in ("", " --retry-of dispatch_old"):
            deny, err = self.run_hook("orca orchestration worker-start --task t --agent claude "
                                    "--task-title 'fullstack-dev - job'" + retry)
            self.assertIsNone(deny)
            self.assertIn("pick recommends codex", err)
            self.assertIn("claude headroom", err)
            self.assertIn("codex headroom", err)
        self.assertEqual(self.run_hook("orca orchestration worker-start --agent codex "
                                      "--task-title 'fullstack-dev - job'"), (None, ""))

    def test_codex_launcher_is_checked_and_unknown_role_warns(self):
        self.claude(41, baseline=40)
        self.codex_reading(45)
        json.dump({"date": datetime.now().strftime("%Y-%m-%d"), "baseline": 40, "resets_at": FUT},
                  open(self.state + "/codex.json", "w"))
        deny, err = self.run_hook("~/dotfiles/script/start-codex-worker.sh --title 'fullstack-dev - job'")
        self.assertIsNone(deny)
        self.assertIn("pick recommends claude", err)
        deny, err = self.run_hook("orca orchestration worker-start --agent codex --task-title 'mystery - job'")
        self.assertIsNone(deny)
        self.assertIn("no known role prefix", err)

    def test_override_allows_routing_mismatch_logs_reason_and_keeps_daily_cap(self):
        self.claude(44, baseline=40)
        self.codex_reading(41)
        cmd = "USAGE_GATE_OVERRIDE='provider outage' orca orchestration worker-start --agent claude " \
              "--task-title 'fullstack-dev - job'"
        self.assertIsNone(self.run_hook(cmd)[0])
        with open(self.state + "/overrides.log") as f:
            log = f.read()
        self.assertIn("provider outage", log)
        self.assertIn("fullstack-dev", log)
        self.claude(80, baseline=40)
        self.assertIsNone(self.run_hook(cmd)[0])
        self.claude(95)
        self.assertIn("weekly ceiling", self.run_hook(cmd)[0] or "")

    def test_override_only_applies_to_its_command_and_not_spec_text(self):
        self.claude(44, baseline=40)
        self.codex_reading(41)
        start = "orca orchestration worker-start --agent claude --task-title 'fullstack-dev - job'"
        for cmd in ("USAGE_GATE_OVERRIDE=outage " + start + " && " + start,
                    start + " --spec 'USAGE_GATE_OVERRIDE=outage'",
                    "echo USAGE_GATE_OVERRIDE=outage; " + start):
            self.assertIsNone(self.run_hook(cmd)[0])
            self.assertIn("pick recommends codex", self.run_hook(cmd)[1])

    def test_launcher_mentions_are_not_starts(self):
        self.codex_reading(100)
        for command in ("cat script/start-codex-worker.sh", "echo script/start-codex-worker.sh"):
            self.assertEqual(self.run_hook(command), (None, ""))

    def test_unknown_role_override_is_also_logged(self):
        self.claude(44)
        deny, err = self.run_hook("USAGE_GATE_OVERRIDE='manual recovery' orca orchestration worker-start "
                                  "--agent claude --task-title 'unknown - job'")
        self.assertIsNone(deny)
        self.assertIn("no known role prefix", err)
        with open(self.state + "/overrides.log") as f:
            self.assertIn("manual recovery", f.read())


if __name__ == "__main__":
    unittest.main()
