import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile, time, unittest
from unittest import mock
from datetime import datetime, timezone
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import asdf_pin  # noqa: E402
asdf_pin.pin()  # before any test sets HOME
HOOK = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
FUT = time.time() + 3 * 86400


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = self.tmp.name + "/state"
        self.presets = self.tmp.name + "/presets.json"
        with open(self.presets, "w") as f:
            json.dump({"roles": {"fullstack-dev": {"tier": "workhorse", "chain": [
                {"provider": "claude", "model": "sonnet"},
                {"provider": "cursor", "model": "composer-test"}]}}}, f)
        os.makedirs(self.tmp.name + "/bin")
        for command in ("security",):
            path = self.tmp.name + "/bin/" + command
            with open(path, "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            os.chmod(path, 0o755)
        os.makedirs(self.state)

    def tearDown(self):
        self.tmp.cleanup()

    def claude(self, pct, baseline=None, written_at=None):
        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT}, "_written_at": written_at or time.time()},
                  open(self.state + "/claude-rate-limits.json", "w"))
        if baseline is not None:
            today = datetime.now().strftime("%Y-%m-%d")
            json.dump({"date": today, "baseline": baseline, "resets_at": FUT}, open(self.state + "/claude.json", "w"))

    def run_hook(self, command, tool="Bash"):
        env = dict(os.environ, HOME=self.tmp.name, PATH=self.tmp.name + "/bin:" + os.environ["PATH"], USAGE_GATE_STATE=self.state, USAGE_GATE_ORCA="false", USAGE_GATE_PRESETS=self.presets)
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
        self.claude(100)
        deny, _ = self.run_hook("orca orchestration worker-start --task t --worktree current --agent claude")
        self.assertIn("blocked claude: weekly ceiling", deny)
        self.assertIn("Resets " + time.strftime("%a %d %b %H:%M %Z", time.localtime(FUT)) + " (local time)", deny)

    def test_daily_cap_does_not_deny_a_start(self):
        self.claude(65, baseline=40)  # 25 spent; cap = 55 left over about 3.5 days
        deny, _ = self.run_hook('orca orchestration worker-start --spec "fix x; then y" --agent=claude')
        self.assertIsNone(deny)

    def test_agent_from_a_shell_variable_or_loop_is_gated(self):
        self.claude(100)
        for cmd in ('A=claude; orca orchestration worker-start --task t --agent "$A"',
                    "for a in claude cursor; do orca orchestration worker-start --task t --agent ${a}; done",
                    "(orca orchestration worker-start --task t --agent claude)"):
            self.assertIn("blocked claude", self.run_hook(cmd)[0] or "", cmd)

    def test_heredoc_text_is_not_a_command(self):
        self.claude(100)
        cmd = "git commit -F - <<'EOF'\nDocs: don't run orca orchestration worker-start --agent claude\nEOF"
        self.assertEqual(self.run_hook(cmd), (None, ""))

    def test_empty_or_heredoc_spec_is_denied_before_orca(self):
        # 2026-10-28: a heredoc inside $( ) expanded to an empty --spec and Orca got no brief.
        self.claude(11)
        for cmd in ('orca orchestration worker-start --task t --agent claude --spec ""',
                    "orca orchestration worker-start --task t --agent claude --spec \"$(cat <<'EOF'\nDo x.\nEOF\n)\""):
            self.assertIn("empty --spec", self.run_hook(cmd)[0] or "", cmd)
        deny, _ = self.run_hook('orca orchestration worker-start --task t --agent claude --spec "$(cat brief.md)"')
        self.assertIsNone(deny)

    def test_one_blocked_start_in_a_chain_blocks_the_command(self):
        self.cursor(40, 38); self.claude(100)
        deny, _ = self.run_hook("orca orchestration worker-start --task a --agent cursor && "
                                "orca orchestration worker-start --task b \\\n  --agent claude")
        self.assertIn("claude", deny); self.assertNotIn("cursor", deny)

    def test_unknown_provider_passes_with_warning(self):
        deny, err = self.run_hook("orca orchestration worker-start --task t --agent unknown")
        self.assertIsNone(deny)
        self.assertIn("no usage reading for agent unknown", err)

    def run_stubbed_pool_hook(self, command, provider="antigravity", unavailable_model=None):
        spec = importlib.util.spec_from_file_location("hook", HOOK)
        hook = importlib.util.module_from_spec(spec)
        with mock.patch("sys.stdin", io.StringIO('{"tool_name":"Read"}')), \
                mock.patch("sys.exit"):
            spec.loader.exec_module(hook)

        def gate(argv, **kwargs):
            self.assertEqual(argv[:5], [sys.executable, hook.GATE, "check", "--provider", provider])
            extra = argv[5:]
            allowed = extra in ([], ["--model", "gemini-flash"]) if provider == "antigravity" else extra == []
            if unavailable_model and extra == ["--model", unavailable_model]:
                return mock.Mock(returncode=4, stdout=json.dumps({"reason": "no pool reading"}))
            if unavailable_model and not extra:
                allowed = False
            if extra == ["--model", "unknown-model"]:
                return mock.Mock(returncode=4, stdout=json.dumps({"reason": "unknown model"}))
            if extra == ["--model", "--x"]:
                return mock.Mock(returncode=2, stdout="")
            if provider == "cursor" and extra == ["--model", "gpt-5.6-sol-high"]:
                return mock.Mock(returncode=4, stdout=json.dumps({
                    "reason": "auto+composer allowance does not measure Cursor model gpt-5.6-sol-high; "
                              "read the Cursor dashboard",
                    "source": "summary"}))
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

    def test_antigravity_without_model_uses_default_flash_pool(self):
        out, checks = self.run_stubbed_pool_hook(
            "orca orchestration worker-start --agent antigravity")
        self.assertEqual(out, "")
        self.assertEqual(checks, [[]])

    def test_antigravity_missing_named_pool_never_uses_exhausted_flash(self):
        for model in ("gemini-4-argon-low", "claude-sonnet", "unknown-model"):
            with self.subTest(model=model):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity --model " + model,
                    unavailable_model=model)
                self.assertEqual(out, "")
                self.assertEqual(checks, [["--model", model]])

    def test_antigravity_invalid_model_arguments_use_default_flash_pool(self):
        for option in ('--model "$M"', "--model=--x", "--model -h",
                       "--model gemini-flash --model claude-sonnet",
                       "--model claude-sonnet --model=gemini-flash"):
            with self.subTest(option=option):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity " + option)
                self.assertEqual(out, "")
                self.assertEqual(checks[-1], [])

    def test_antigravity_chain_checks_each_model_and_model_less_start(self):
        for suffix, expected in (("--model claude-sonnet", ["--model", "claude-sonnet"]),
                                 ("", [])):
            with self.subTest(suffix=suffix):
                out, checks = self.run_stubbed_pool_hook(
                    "orca orchestration worker-start --agent antigravity --model gemini-flash && "
                    "orca orchestration worker-start --agent antigravity " + suffix)
                if suffix:
                    self.assertIn("blocked antigravity: weekly ceiling", out)
                else:
                    self.assertEqual(out, "")
                self.assertEqual(checks, [["--model", "gemini-flash"], expected])

    def test_claude_does_not_forward_model(self):
        out, checks = self.run_stubbed_pool_hook(
            "orca orchestration worker-start --agent claude --model gemini-flash",
            provider="claude")
        self.assertEqual(out, "")
        self.assertEqual(checks, [[]])

    def test_cursor_forwards_model_to_gate_check(self):
        _, checks = self.run_stubbed_pool_hook(
            "orca orchestration worker-start --agent cursor --model gpt-5.6-sol-high",
            provider="cursor")
        self.assertEqual(checks, [["--model", "gpt-5.6-sol-high"]])

    def cursor(self, pct, baseline):
        ends = datetime.fromtimestamp(FUT, timezone.utc).isoformat()
        json.dump({"billingCycleStart": "2026-09-25T00:00:00+00:00", "billingCycleEnd": ends,
                   "individualUsage": {"plan": {"enabled": True, "totalPercentUsed": pct}}},
                  open(self.state + "/summary.json", "w"))
        json.dump({"date": datetime.now().strftime("%Y-%m-%d"), "baseline": baseline, "resets_at": FUT.__float__()},
                  open(self.state + "/cursor.json", "w"))
        os.environ["USAGE_GATE_CURSOR_SUMMARY"] = self.state + "/summary.json"
        self.addCleanup(os.environ.pop, "USAGE_GATE_CURSOR_SUMMARY", None)

    def composer_pool(self, auto_pct, baseline):
        ends = datetime.fromtimestamp(FUT, timezone.utc).isoformat()
        json.dump({"billingCycleStart": "2026-09-25T00:00:00+00:00", "billingCycleEnd": ends,
                   "individualUsage": {"plan": {"enabled": True, "totalPercentUsed": auto_pct,
                                                "autoPercentUsed": auto_pct, "apiPercentUsed": 100}}},
                  open(self.state + "/summary.json", "w"))
        json.dump({"date": datetime.now().strftime("%Y-%m-%d"), "baseline": baseline, "resets_at": FUT},
                  open(self.state + "/cursor.json", "w"))
        os.environ["USAGE_GATE_CURSOR_SUMMARY"] = self.state + "/summary.json"
        self.addCleanup(os.environ.pop, "USAGE_GATE_CURSOR_SUMMARY", None)

    def test_cursor_non_composer_model_warns_when_composer_pool_has_headroom(self):
        cmd = ("orca orchestration worker-start --task t --agent cursor --model gpt-5.6-sol-high "
               "--task-title 'qa-sdet - review'")
        self.composer_pool(16, 14)
        deny, err = self.run_hook(cmd)
        self.assertIsNone(deny)
        self.assertIn("no usage reading for cursor", err)

    def test_cursor_non_composer_model_with_unreadable_summary_warns(self):
        cmd = "orca orchestration worker-start --task t --agent cursor --model gpt-5.6-sol-high"
        self.cursor(10, 8)
        deny, err = self.run_hook(cmd)
        self.assertIsNone(deny)
        self.assertIn("no usage reading for cursor", err)

    def test_cursor_non_composer_model_blocked_at_exhausted_composer_pool(self):
        cmd = "orca orchestration worker-start --task t --agent cursor --model gpt-5.6-sol-high"
        self.composer_pool(95, 90)
        deny, err = self.run_hook(cmd)
        self.assertIn("blocked cursor", deny or "")
        self.assertNotIn("no usage reading for cursor", err)

    def test_cursor_aggregate_usage_warns_without_blocking_composer(self):
        cmd = "orca orchestration worker-start --task t --agent cursor"
        self.cursor(40, 38)
        self.assertIsNone(self.run_hook(cmd)[0])
        self.cursor(95, 90)
        deny, err = self.run_hook(cmd)
        self.assertIsNone(deny)
        self.assertIn("read the Cursor dashboard", err)

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
        self.claude(100)
        for cmd in ("git status", "orca orchestration check --terminal x --json", "grep worker-start notes.md"):
            self.assertEqual(self.run_hook(cmd), (None, ""))
        self.assertEqual(self.run_hook("orca orchestration worker-start --agent claude", tool="Read"), (None, ""))
        self.assertFalse(os.path.exists(self.state + "/claude.json"))

    def test_start_must_use_pick_even_on_retry(self):
        self.claude(44, baseline=40)
        # Cursor has no reliable reading, so the pick lands on claude and a cursor start is flagged.
        for retry in ("", " --retry-of dispatch_old"):
            deny, err = self.run_hook("orca orchestration worker-start --task t --agent cursor "
                                    "--task-title 'fullstack-dev - job'" + retry)
            self.assertIsNone(deny)
            self.assertIn("pick recommends claude", err)
            self.assertIn("claude headroom", err)
        self.assertEqual(self.run_hook("orca orchestration worker-start --agent claude "
                                      "--task-title 'fullstack-dev - job'"), (None, ""))

    def test_unknown_role_warns(self):
        self.claude(41, baseline=40)
        deny, err = self.run_hook("orca orchestration worker-start --agent cursor --task-title 'mystery - job'")
        self.assertIsNone(deny)
        self.assertIn("no known role prefix", err)

    def test_override_allows_routing_mismatch_logs_reason_and_keeps_daily_cap(self):
        self.claude(44, baseline=40)
        cmd = "USAGE_GATE_OVERRIDE='provider outage' orca orchestration worker-start --agent cursor " \
              "--task-title 'fullstack-dev - job'"
        self.assertIsNone(self.run_hook(cmd)[0])
        with open(self.state + "/overrides.log") as f:
            log = f.read()
        self.assertIn("provider outage", log)
        self.assertIn("fullstack-dev", log)
        cmd = cmd.replace("--agent cursor", "--agent claude")
        self.claude(80, baseline=40)
        self.assertIsNone(self.run_hook(cmd)[0])
        self.claude(95)
        self.assertIn("weekly ceiling", self.run_hook(cmd)[0] or "")

    def test_override_only_applies_to_its_command_and_not_spec_text(self):
        self.claude(44, baseline=40)
        start = "orca orchestration worker-start --agent cursor --task-title 'fullstack-dev - job'"
        for cmd in ("USAGE_GATE_OVERRIDE=outage " + start + " && " + start,
                    start + " --spec 'USAGE_GATE_OVERRIDE=outage'",
                    "echo USAGE_GATE_OVERRIDE=outage; " + start):
            self.assertIsNone(self.run_hook(cmd)[0])
            self.assertIn("pick recommends claude", self.run_hook(cmd)[1])

    def test_unknown_role_override_is_also_logged(self):
        self.claude(44)
        deny, err = self.run_hook("USAGE_GATE_OVERRIDE='manual recovery' orca orchestration worker-start "
                                  "--agent claude --task-title 'unknown - job'")
        self.assertIsNone(deny)
        self.assertIn("no known role prefix", err)
        with open(self.state + "/overrides.log") as f:
            self.assertIn("manual recovery", f.read())


class LeadContext(unittest.TestCase):
    """Context limit for a session identified as a lead by its worktree basename (lead-*)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dirs = {}
        for name, rel in (("lead", "lead-one"), ("build", "build-one"), ("nested", "lead-parent/build-one")):
            path = os.path.join(self.tmp.name, rel)
            os.makedirs(path)
            subprocess.run(["git", "init", "-q", path], check=True)
            self.dirs[name] = path
        self.plain = os.path.join(self.tmp.name, "not-a-repo")
        os.makedirs(self.plain)

    def tearDown(self):
        self.tmp.cleanup()

    def transcript(self, tokens, name="t.jsonl", extra=""):
        path = os.path.join(self.tmp.name, name)
        usage = lambda n: {"type": "assistant", "message": {"usage": {
            "input_tokens": 3, "cache_read_input_tokens": n - 3 - 10, "cache_creation_input_tokens": 10, "output_tokens": 99}}}
        with open(path, "w") as f:
            f.write(json.dumps(usage(900000)) + "\n")  # an older, larger entry: the latest wins, never a sum
            f.write(json.dumps(usage(tokens)) + "\n" + extra)
        return path

    def run_hook(self, command, tokens=None, where="lead", transcript=None, project=None):
        path = transcript or (self.transcript(tokens) if tokens is not None else None)
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": self.dirs.get(where, self.plain)}
        if path:
            payload["transcript_path"] = path
        env = dict(os.environ, HOME=self.tmp.name, USAGE_GATE_STATE=self.tmp.name + "/state", USAGE_GATE_ORCA="false")
        env.pop("CLAUDE_PROJECT_DIR", None)
        if project:
            env["CLAUDE_PROJECT_DIR"] = self.dirs.get(project, project)
        r = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        out = json.loads(r.stdout)["hookSpecificOutput"] if r.stdout.strip() else {}
        return out.get("permissionDecisionReason"), out.get("additionalContext"), r.stderr

    def test_lead_under_warn_line_passes_silently(self):
        deny, note, err = self.run_hook("git status", 149999)
        self.assertEqual((deny, note, err), (None, None, ""))

    def test_lead_at_150k_is_warned_not_denied(self):
        deny, note, _ = self.run_hook("git status", 150000)
        self.assertIsNone(deny)
        self.assertIn("150k", note)
        self.assertIn("lead-handoff.sh", note)

    def test_lead_at_171k_plain_command_denied_with_handoff_command(self):
        deny, _, _ = self.run_hook("git status", 171000)
        self.assertIn("lead-handoff.sh --branch", deny)
        self.assertIn("--dispatch-ids", deny)

    def test_lead_at_171k_allow_list(self):
        for command in ("script/lead-handoff.sh --branch b --head h --remainder r --dispatch-ids i",
                        "~/dotfiles/script/lead-merge.sh --repo o/r --pr 3 --head abc",
                        "bash script/lead-merge.sh --repo o/r --pr 3 --head abc",
                        "orca orchestration check --json",
                        "orca terminal read --terminal t 2>&1 >/dev/null",
                        "LEAD_X=1 orca orchestration send --body 'a; git push'"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNone(deny)

    def test_lead_at_171k_compound_hiding_a_denied_command(self):
        for command in ("orca orchestration check && git push", "orca x; rm -rf y", "orca x | sh", "orca x & git push",
                        "script/lead-merge.sh --pr 1\ngit push", "orca $(git push)", "orca `git push`",
                        "orca x > out; cat y", "(git push)", "git push || orca x", "orca x\n cat <<EOF\nhi\nEOF\ngit push"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_heredoc_body_is_text_for_an_allowed_command(self):
        deny, _, _ = self.run_hook("orca orchestration send --body \"$(cat <<'EOF'\nline; git push\nEOF\n)\"", 171000)
        self.assertIsNone(deny)

    def test_lead_at_171k_handoff_head_from_git_rev_parse(self):
        for command in ('script/lead-handoff.sh --branch b --head "$(git rev-parse HEAD)" --remainder r --dispatch-ids i',
                        "script/lead-handoff.sh --branch b --head $(git rev-parse --short HEAD) --remainder r --dispatch-ids i",
                        'orca orchestration send --body "$(git rev-parse origin/main)"'):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNone(deny)

    def test_lead_at_171k_other_git_in_a_substitution_stays_denied(self):
        for command in ('script/lead-handoff.sh --head "$(git push)"', "orca send $(git push)",
                        "orca send $(git rev-parse HEAD; git push)", "orca send $(git rev-parse HEAD && rm x)",
                        "orca send $(git rev-parse `git push`)", "orca send $(git rev-parse HEAD > x)"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_lead_at_171k_newline_in_a_substitution_stays_denied(self):
        for command in ('orca send "$(git rev-parse HEAD\ntouch marker)"', 'orca send "$(git rev-parse HEAD\ngit push origin main)"',
                        'orca send "$(cat\ntouch)"', 'orca send "$(cat\nmarker)"'):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_lead_at_171k_bash_or_sh_cd_is_denied(self):
        # `bash cd x` runs a file named cd; only a real cd is a harmless first word.
        for command in ("bash cd x", "sh cd x", "FOO=1 bash cd x", "bash cd x && orca orchestration check"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_lead_at_171k_bare_cd_is_allowed(self):
        for command in ("cd x", "FOO=1 cd x"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNone(deny)

    def test_lead_at_171k_cd_then_a_denied_command_is_denied(self):
        for command in ("cd x; git push", "FOO=1 cd x; rm -rf y"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_a_cd_into_a_nested_repo_does_not_end_lead_detection(self):
        nested = os.path.join(self.dirs["lead"], "inner")
        os.makedirs(nested)
        subprocess.run(["git", "init", "-q", nested], check=True)
        self.dirs["inner"] = nested
        deny, _, _ = self.run_hook("git push", 171000, where="inner", project="lead")
        self.assertIsNotNone(deny)
        deny, _, _ = self.run_hook("git push", 171000, where="inner")   # no project dir: the cwd alone is not a lead
        self.assertIsNone(deny)
        deny, _, _ = self.run_hook("git push", 171000, where="build", project="build")   # neither is a lead
        self.assertIsNone(deny)
        deny, _, _ = self.run_hook("git push", 171000, where="plain", project="lead")   # cwd outside any repo
        self.assertIsNotNone(deny)

    def test_deny_text_uses_a_path_that_works_from_any_folder(self):
        deny, _, _ = self.run_hook("git status", 171000)
        self.assertIn("~/dotfiles/script/lead-handoff.sh --branch", deny)
        self.assertNotIn(" script/lead-handoff.sh", deny.replace("~/dotfiles/script/lead-handoff.sh", ""))

    def test_lead_at_171k_cd_then_allowed_command(self):
        for command in ("cd /some/dir && script/lead-merge.sh --repo o/r --pr 3 --head abc",
                        "cd ~/work && orca orchestration check --json"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNone(deny)

    def test_lead_at_171k_cd_then_denied_command_stays_denied(self):
        for command in ("cd /some/dir && git push", "cd /some/dir; rm -rf y", "cd a b && orca x", "cd $(git push) && orca x"):
            with self.subTest(command=command):
                deny, _, _ = self.run_hook(command, 171000)
                self.assertIsNotNone(deny)

    def test_deny_text_says_a_literal_sha_also_works(self):
        deny, _, _ = self.run_hook("git status", 171000)
        self.assertIn("literal sha", deny)
        self.assertIn("git rev-parse", deny)

    def test_a_lead_limit_error_never_skips_the_worker_start_gate(self):
        original = open(HOOK).read()
        source = original.replace("def lead_limit(data, cmd):\n", "def lead_limit(data, cmd):\n    raise RuntimeError('boom')\n")
        self.assertNotEqual(source, original)   # the replace must really patch the hook
        patched = os.path.join(self.tmp.name, "patched-hook.py")
        open(patched, "w").write(source)
        payload = {"tool_name": "Bash", "cwd": self.dirs["lead"],
                   "tool_input": {"command": "orca orchestration worker-start --spec '' --agent unknownagent"}}
        r = subprocess.run([sys.executable, patched], input=json.dumps(payload), capture_output=True, text=True,
                           env=dict(os.environ, HOME=self.tmp.name, USAGE_GATE_STATE=self.tmp.name + "/state"))
        self.assertIn("empty --spec", json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"])

    def test_a_lead_limit_error_never_skips_a_gate_exit_3_denial(self):
        stub = os.path.join(self.tmp.name, "gate-stub.py")
        open(stub, "w").write("import json, sys\nprint(json.dumps({'weekly_used': 99, 'ceiling': 95}))\nsys.exit(3)\n")
        original = open(HOOK).read()
        source = original.replace("def lead_limit(data, cmd):\n", "def lead_limit(data, cmd):\n    raise RuntimeError('boom')\n")
        self.assertNotEqual(source, original)   # the replace must really patch the hook
        gate_line = next(line for line in source.splitlines() if line.startswith("GATE = "))
        patched_source = source.replace(gate_line, f"GATE = {stub!r}")
        self.assertNotEqual(patched_source, source)
        patched = os.path.join(self.tmp.name, "patched-hook.py")
        open(patched, "w").write(patched_source)
        payload = {"tool_name": "Bash", "cwd": self.dirs["lead"],
                   "tool_input": {"command": "orca orchestration worker-start --spec x --agent claude"}}
        r = subprocess.run([sys.executable, patched], input=json.dumps(payload), capture_output=True, text=True,
                           env=dict(os.environ, HOME=self.tmp.name, USAGE_GATE_STATE=self.tmp.name + "/state",
                                    USAGE_GATE_PRESETS=self.tmp.name + "/none.json"))
        self.assertIn("Usage gate blocked claude", json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"])

    def test_non_leads_at_171k_pass(self):
        for where in ("build", "nested", "plain"):
            with self.subTest(where=where):
                deny, note, _ = self.run_hook("git status", 171000, where=where)
                self.assertEqual((deny, note), (None, None))

    def test_missing_cwd_is_not_a_lead(self):
        path = self.transcript(171000)
        r = subprocess.run([sys.executable, HOOK], input=json.dumps(
            {"tool_name": "Bash", "tool_input": {"command": "git status"}, "transcript_path": path}),
            capture_output=True, text=True, env=dict(os.environ, HOME=self.tmp.name))
        self.assertEqual(r.stdout.strip(), "")

    def test_missing_transcript_warns_only(self):
        deny, _, err = self.run_hook("git status", transcript=self.tmp.name + "/none.jsonl")
        self.assertIsNone(deny)
        self.assertIn("context size unreadable", err)
        deny, _, err = self.run_hook("git status")
        self.assertIsNone(deny)
        self.assertIn("context size unreadable", err)

    def test_malformed_transcript_warns_only(self):
        path = os.path.join(self.tmp.name, "bad.jsonl")
        open(path, "w").write("not json\n{\"message\": {\"usage\": \n\x00\x01 garbage")
        deny, _, err = self.run_hook("git status", transcript=path)
        self.assertIsNone(deny)
        self.assertIn("context size unreadable", err)

    def test_truncated_last_line_uses_the_last_complete_entry(self):
        path = self.transcript(171000, extra='{"type":"assistant","message":{"usage":{"input_to')
        deny, _, _ = self.run_hook("git status", transcript=path)
        self.assertIsNotNone(deny)

    def test_reads_only_the_end_of_a_large_transcript(self):
        path = self.transcript(171000, name="big.jsonl", extra=json.dumps({"type": "user", "pad": "x" * 3000000}) + "\n")
        start = time.time()
        deny, _, _ = self.run_hook("git status", transcript=path)
        self.assertIsNotNone(deny)
        self.assertLess(time.time() - start, 2)

    def test_worker_start_gate_still_runs_for_a_lead_under_the_limit(self):
        deny, note, _ = self.run_hook("orca orchestration worker-start --spec '' --agent claude", 100000)
        self.assertIn("empty --spec", deny)

    def test_lead_over_limit_worker_start_is_allowed_by_context_gate(self):
        deny, _, _ = self.run_hook("orca orchestration worker-start --spec x --agent unknownagent", 171000)
        self.assertIsNone(deny)


if __name__ == "__main__":
    unittest.main()
