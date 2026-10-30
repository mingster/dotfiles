import contextlib, importlib.util, io, json, os, sys, tempfile, unittest
from datetime import timezone
from unittest import mock
spec = importlib.util.spec_from_file_location("ug", os.path.join(os.path.dirname(__file__), "..", "usage-gate.py"))
ug = importlib.util.module_from_spec(spec); spec.loader.exec_module(ug)
NO_CURSOR = "/nonexistent/cursor-summary.json"
ug.READERS["antigravity"] = lambda: None  # tests never query the local server
ug.antigravity_models = lambda: None  # tests never run the Antigravity CLI
ug.BANNER_FILE = "/nonexistent/antigravity-banner.json"  # tests never read real banners
ug.refresh_reading = lambda provider: None  # isolate provider refresh transport in legacy unit cases
ug.CURSOR_SUMMARY = NO_CURSOR  # tests never reach the network
NOW = 1_000_000_000.0
FUT = NOW + 86400
D = lambda pct, resets=FUT: {"pct": pct, "resets_at": resets}
REVIEWER_CHAIN = [{"provider": "codex", "model": "gpt-6.1-sol", "effort": "medium"},
                  {"provider": "cursor", "model": "composer-2.5"},
                  {"provider": "antigravity", "model": "gemini-3.8-flash"}]


class Antigravity(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(ug, "running_workers", return_value=0)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_flash_uses_its_own_live_quota_instead_of_exhausted_argon(self):
        # Redacted GetUserStatus projection: zero remaining is omitted by protobuf.
        payload = {"userStatus": {"cascadeModelConfigData": {"clientModelConfigs": [
            {"label": "Gemini 4 Argon (Medium)",
             "quotaInfo": {"resetTime": "2026-11-02T07:12:32Z"}},
            {"label": "Gemini 3.8 Flash (High)",
             "quotaInfo": {"remainingFraction": 0.9889657,
                           "resetTime": "2026-10-29T19:29:49Z"}},
            {"label": "Claude Sonnet 5.5 (High)",
             "quotaInfo": {"remainingFraction": 1,
                           "resetTime": "2026-10-29T19:59:15Z"}}]}}}
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: ug.antigravity_reading(fetch=lambda: payload)}), \
                mock.patch.object(ug.time, "time", return_value=ug.epoch("2026-10-29T12:00:00Z")):
            for model, status, used, reset in [
                ("gemini-3.8-flash", 0, 1.10343, "2026-10-29T19:29:49Z"),
                ("gemini-4-argon-low", 3, 100, "2026-11-02T07:12:32Z"),
                ("gemini-3.1-pro-high", 3, 100, "2026-11-02T07:12:32Z"),
                ("claude-sonnet-5-5-high", 0, 0, "2026-10-29T19:59:15Z")]:
                with self.subTest(model=model), contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(ug.main(["check", "--provider", "antigravity", "--model", model]), status)
                    row = json.loads(out.getvalue())
                    self.assertEqual((row["weekly_used"], row["resets_at"]), (used, ug.epoch(reset)))

    def test_reads_model_pools_with_shared_quota(self):
        payload = {"userStatus": {"cascadeModelConfigData": {"clientModelConfigs": [
            {"label": label, "quotaInfo": {"remainingFraction": remaining,
                                           "resetTime": "2026-10-20T01:49:00Z"}}
            for label, remaining in [("Claude Sonnet", .5), ("GPT-OSS 120B", .5),
                                     ("Gemini Flash", .98), ("Other", 0)]
        ]}}}
        readings = ug.antigravity_reading(fetch=lambda: payload)
        self.assertEqual(set(readings), {"claude", "gemini-flash"})
        self.assertEqual(readings["claude"]["pct"], 50)
        self.assertAlmostEqual(readings["gemini-flash"]["pct"], 2)
        self.assertEqual(readings["claude"]["resets_at"], ug.epoch("2026-10-20T01:49:00Z"))

    def test_exhausted_pool_omits_remaining_fraction(self):
        payload = {"userStatus": {"cascadeModelConfigData": {"clientModelConfigs": [
            {"label": "Claude Opus", "quotaInfo": {"resetTime": "2026-10-28T05:51:14Z"}},
            {"label": "Gemini Flash", "quotaInfo": {"remainingFraction": 1,
                                                    "resetTime": "2026-10-22T08:26:09Z"}}]}}}
        readings = ug.antigravity_reading(fetch=lambda: payload)
        self.assertEqual(readings["claude"]["pct"], 100)
        self.assertEqual(readings["gemini-flash"]["pct"], 0)

    def test_default_check_uses_flash_even_when_pro_is_exhausted(self):
        pools = {"gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW},
                 "gemini-pro": {"pct": 100, "resets_at": FUT, "observed_at": NOW}}
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                mock.patch.object(ug.time, "time", return_value=NOW):
            self.assertEqual(ug.main(["check", "--provider", "antigravity"]), 0)
        self.assertEqual(json.loads(out.getvalue())["weekly_used"], 2)

    def test_check_selects_model_pool_and_blocks_at_ceiling(self):
        pools = {"claude": {"pct": 95, "resets_at": FUT, "observed_at": NOW},
                 "gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW}}
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            for model, status in [("claude-sonnet", 3), ("gpt-oss-120b", 3),
                                  ("gemini-flash", 0), (None, 0), ("unknown", 4)]:
                with self.subTest(model=model), contextlib.redirect_stdout(io.StringIO()) as out:
                    args = ["check", "--provider", "antigravity"]
                    self.assertEqual(ug.main(args + (["--model", model] if model else [])), status)
                    detail = json.loads(out.getvalue())
                    self.assertNotIn("today_used", detail)
            pools["claude"]["pct"] = 94.99
            self.assertEqual(ug.run("antigravity", None, 95, now=NOW, model="claude-sonnet")["verdict"], "allowed")

    def test_missing_server_timeout_and_bad_payload_have_no_reading(self):
        with mock.patch.object(ug.subprocess, "run", return_value=mock.Mock(stdout="")):
            self.assertIsNone(ug.antigravity_reading())
        for payload in (None, {}, {"userStatus": []}):
            self.assertIsNone(ug.antigravity_reading(fetch=lambda: payload))
        def timeout():
            raise TimeoutError()
        self.assertIsNone(ug.antigravity_reading(fetch=timeout))
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: None}), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ug.main(["check", "--provider", "antigravity"]), 4)

    def test_transport_timeout_or_bad_json_produces_no_reading(self):
        import urllib.request
        processes = mock.Mock(stdout="123 language_server_macos_arm --csrf_token synthetic")
        ports = mock.Mock(stdout="server 123 TCP 127.0.0.1:12345 (LISTEN)")
        for error in (TimeoutError(), ValueError("bad JSON")):
            with mock.patch.object(ug.subprocess, "run", side_effect=[processes, ports]), \
                    mock.patch.object(urllib.request, "build_opener") as build:
                build.return_value.open.side_effect = error
                self.assertIsNone(ug.antigravity_reading())

    def test_picker_uses_candidate_model_pool(self):
        pools = {"claude": {"pct": 95, "resets_at": FUT, "observed_at": NOW},
                 "gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW}}
        chain = [{"provider": "antigravity", "model": model}
                 for model in ("claude-sonnet", "gemini-flash")]
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            path = t + "/presets.json"
            with open(path, "w") as f:
                json.dump({"roles": {"dev": {"chain": chain}}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}):
                result = ug.pick("dev", None, None, 95, 1)
        self.assertEqual(result["selected"]["model"], "gemini-flash")
        self.assertEqual([c["verdict"] for c in result["candidates"]], ["blocked", "allowed"])

    def test_show_lists_three_pools_with_local_resets(self):
        pools = {"claude": {"pct": 50, "resets_at": FUT, "observed_at": NOW},
                 "gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW},
                 "gemini-pro": {"pct": 100, "resets_at": FUT, "observed_at": NOW}}
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show", "--provider", "antigravity"]), 0)
        for pool, pct in (("claude", "50"), ("gemini-flash", "2"), ("gemini-pro", "100")):
            lines = [line for line in out.getvalue().splitlines() if line.startswith("antigravity/" + pool)]
            self.assertEqual(len(lines), 1)
            self.assertIn(pct, lines[0])
            self.assertIn(ug.local(FUT), lines[0])


class Decide(unittest.TestCase):
    def go(self, reading, state, today="d1"):
        return ug.decide(reading, state, today, NOW, 12, 95)

    def test_first_reading_sets_baseline_and_allows(self):
        v, d, st = self.go(D(40), None)
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 0.0, 40))

    def test_daily_cap_is_only_a_pacing_hint(self):
        v, d, _ = self.go(D(52), {"date": "d1", "baseline": 40, "resets_at": FUT})
        self.assertEqual((v, d["note"]), ("allowed", "pacing: prefer a lighter model"))

    def test_allows_below_cap(self):
        v, _, _ = self.go(D(51.9), {"date": "d1", "baseline": 40, "resets_at": FUT})
        self.assertEqual(v, "allowed")

    def test_new_day_resets_baseline(self):
        v, d, st = self.go(D(70), {"date": "d0", "baseline": 40, "resets_at": FUT})
        self.assertEqual((v, st["baseline"], st["date"]), ("allowed", 70, "d1"))

    def test_weekly_ceiling_blocks_even_under_cap(self):
        v, d, _ = self.go(D(96), {"date": "d1", "baseline": 95, "resets_at": FUT})
        self.assertEqual((v, d["reason"]), ("blocked", "weekly ceiling"))

    def test_week_rollover_counts_from_zero(self):
        v, d, _ = self.go(D(3, FUT + 604800), {"date": "d1", "baseline": 90, "resets_at": FUT})
        self.assertEqual((v, d["today_used"]), ("allowed", 3.0))

    def test_expired_reading_is_zero(self):
        v, d, _ = self.go(D(99, NOW - 5), {"date": "d1", "baseline": 90, "resets_at": NOW - 5})
        self.assertEqual((v, d["reason"]), ("unknown", "stale or expired reading"))

    def test_resets_at_jitter_is_the_same_week(self):
        v, d, st = self.go(D(40, FUT + 1), {"date": "d1", "baseline": 38, "resets_at": FUT})
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 2.0, 38))

    def test_no_reading_is_unknown(self):
        self.assertEqual(self.go(None, None)[0], "unknown")


class Main(unittest.TestCase):
    def test_unreadable_provider_is_no_reading_not_a_usage_error(self):
        for name in ("antigravity", "made-up"):
            with self.subTest(name), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ug.main(["check", "--provider", name]), 4)
            self.assertEqual(json.loads(out.getvalue())["verdict"], "unknown")


class Fresh(unittest.TestCase):
    def test_old_reading_past_its_reset_is_no_reading(self):
        old = {"pct": 99.0, "resets_at": NOW - 5, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertIsNone(ug.fresh(old, NOW))

    def test_old_reading_before_its_reset_is_kept_as_stale(self):
        old = {"pct": 99.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertIsNone(ug.fresh(old, NOW))

    def test_recent_reading_is_kept_whatever_its_timestamp_format(self):
        for at in (NOW - 60, "2001-09-09T01:45:40.000Z"):  # epoch seconds (claude) or ISO (codex)
            self.assertEqual(ug.fresh({"pct": 5.0, "observed_at": at}, NOW)["pct"], 5.0, at)

    def test_reading_from_the_far_future_is_no_reading(self):
        for at in (NOW * 1000, NOW + ug.MAX_AGE + 1):  # a millisecond epoch, or a badly skewed clock
            self.assertIsNone(ug.fresh({"pct": 5.0, "observed_at": at}, NOW), at)

    def test_reading_of_unknown_age_is_no_reading(self):
        for at in (None, "x"):
            self.assertIsNone(ug.fresh({"pct": 5.0, "observed_at": at}, NOW), at)


class StaleReading(unittest.TestCase):
    """Weekly usage cannot fall before the reset, so an old reading still counts against the ceiling."""

    def check(self, reading):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading}), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()):
            return ug.main(["check", "--provider", "claude"])

    def test_stale_reading_at_ceiling_before_reset_blocks(self):
        self.assertEqual(self.check({"pct": 99.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}), 4)

    def test_stale_reading_past_reset_is_unknown(self):
        self.assertEqual(self.check({"pct": 99.0, "resets_at": NOW - 5, "observed_at": NOW - ug.MAX_AGE - 1}), 4)

    def test_stale_reading_under_ceiling_is_unknown_for_the_daily_cap(self):
        self.assertEqual(self.check({"pct": 50.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}), 4)


class Readers(unittest.TestCase):
    def test_codex_reads_latest_weekly_percent(self):
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(t + "/2026/10/05")
            ev = lambda p, w: json.dumps({"timestamp": "2026-10-05T01:00:00Z", "payload": {"type": "token_count",
                "rate_limits": {"primary": {"used_percent": p, "window_minutes": w, "resets_at": 5}}}})
            open(t + "/2026/10/05/rollout-a.jsonl", "w").write(ev(10, 10080) + "\n" + ev(33, 10080) + "\n" + ev(99, 300) + "\n")
            self.assertEqual(ug.codex_reading(t)["pct"], 33.0)

    def codex(self, *limits):
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(t + "/2026/10/05")
            lines = [json.dumps({"timestamp": "2026-10-05T01:00:00Z", "payload": {"type": "token_count", "rate_limits": r}}) for r in limits]
            open(t + "/2026/10/05/rollout-a.jsonl", "w").write("\n".join(lines) + "\n")
            return ug.codex_reading(t)

    def test_codex_skips_events_with_null_primary(self):
        week = {"used_percent": 20, "window_minutes": 10080, "resets_at": 5}
        r = self.codex({"primary": week}, {"primary": None, "secondary": None}, None)
        self.assertEqual(r["pct"], 20.0)

    def test_codex_reads_weekly_window_under_secondary(self):
        r = self.codex({"primary": {"used_percent": 70, "window_minutes": 300, "resets_at": 1},
                        "secondary": {"used_percent": 41, "window_minutes": 10080, "resets_at": 9}})
        self.assertEqual((r["pct"], r["resets_at"]), (41.0, 9))

    def test_claude_reads_seven_day(self):
        with tempfile.TemporaryDirectory() as t:
            p = t + "/c.json"
            json.dump({"seven_day": {"used_percentage": 21.5, "resets_at": 7}}, open(p, "w"))
            self.assertEqual(ug.claude_reading(p)["pct"], 21.5)
            self.assertIsNone(ug.claude_reading(t + "/missing.json"))


class Reserve(unittest.TestCase):
    """Room held back for workers already running."""

    def go(self, reading, state, reserve):
        return ug.decide(reading, state, "d1", NOW, 12, 95, reserve)

    ST = {"date": "d1", "baseline": 40, "resets_at": FUT}

    def test_reserve_lowers_the_cap_for_new_starts(self):
        self.assertEqual(self.go(D(50.9), self.ST, 1)[0], "allowed")
        v, d, _ = self.go(D(51), self.ST, 1)       # 11 spent + 1 reserved = 12
        self.assertEqual((v, d["note"], d["reserve"]), ("allowed", "pacing: prefer a lighter model", 1))

    def test_reserve_lowers_the_ceiling_too(self):
        st = {"date": "d1", "baseline": 90, "resets_at": FUT}
        self.assertEqual(self.go(D(93), st, 1)[0], "allowed")
        self.assertEqual(self.go(D(94), st, 1)[1]["reason"], "weekly ceiling")

    def test_no_running_workers_keeps_the_plain_cap(self):
        self.assertEqual(self.go(D(51.9), self.ST, 0)[0], "allowed")

    def run_with(self, running, per_worker=1.0, pct=50.0):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": pct, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug, "running_workers", return_value=running), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            ug.json.dump({"date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"), "baseline": 40,
                          "resets_at": FUT}, open(t + "/claude.json", "w"))
            return ug.run("claude", 12, 95, per_worker=per_worker)

    def test_each_running_worker_reserves_its_share(self):
        self.assertEqual(self.run_with(1)["verdict"], "allowed")       # 10 + 1 < 12
        self.assertEqual(self.run_with(2)["verdict"], "allowed")       # 10 + 2 >= 12
        self.assertEqual(self.run_with(1, per_worker=2.0)["verdict"], "allowed")

    def test_orca_unavailable_counts_as_no_running_workers(self):
        r = self.run_with(None)
        self.assertEqual((r["verdict"], r["reserve"], r["running"]), ("allowed", 0.0, None))

    def test_running_workers_counts_active_terminals_of_one_provider(self):
        rows = [{"projection": {"provider": {"id": p}}} for p in ("claude", "codex", "claude")]
        out = mock.Mock(stdout=json.dumps({"result": {"workers": rows}}))
        with mock.patch.object(ug.subprocess, "run", return_value=out):
            self.assertEqual((ug.running_workers("claude"), ug.running_workers("codex")), (2, 1))
        with mock.patch.object(ug.subprocess, "run", side_effect=FileNotFoundError):
            self.assertIsNone(ug.running_workers("claude"))


class DayStart(unittest.TestCase):
    """'Today' counts from the start of the local day, not from the first check."""

    def go(self, reading, day_start):
        return ug.decide(reading, None, "d1", NOW, 12, 95, 0.0, day_start)

    def test_first_check_late_in_the_day_still_counts_the_morning(self):
        v, d, st = self.go(D(60), D(45))
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 15.0, 45))

    def test_week_reset_since_the_day_start_counts_from_zero(self):
        v, d, _ = self.go(D(13, FUT + 604800), D(80, FUT))   # codex reset at noon: week = today
        self.assertEqual((v, d["today_used"]), ("allowed", 13.0))

    def test_a_week_that_began_today_started_from_zero(self):
        mid = NOW - 3600
        began_today = {"pct": 13.0, "resets_at": mid + 3600 + 604800 - 1800}      # reset - 7 days = 30 min after midnight
        self.assertEqual(ug.start_of_day(began_today, "codex", mid), {"pct": 0.0, "resets_at": began_today["resets_at"]})
        older = {"pct": 13.0, "resets_at": mid + 604800 - 1}                       # began 1 s before midnight
        with mock.patch.dict(ug.DAY_START, {"codex": lambda m: "from logs"}):
            self.assertEqual(ug.start_of_day(older, "codex", mid), "from logs")
        self.assertIsNone(ug.start_of_day(older, "antigravity", mid))

    def test_no_day_start_falls_back_to_the_first_check(self):
        self.assertEqual(self.go(D(60), None)[1]["today_used"], 0.0)

    def test_a_day_start_never_exceeds_the_reading(self):
        self.assertEqual(self.go(D(40), D(50))[1]["today_used"], 0.0)

    def test_blocked_until_is_local_midnight_for_the_daily_cap_and_the_reset_for_the_ceiling(self):
        mid = ug.next_midnight(NOW)
        self.assertEqual(ug.blocked_until({"reason": "daily cap", "resets_at": FUT + 9 * 86400}, NOW), FUT + 9 * 86400)
        self.assertEqual(ug.blocked_until({"reason": "daily cap", "resets_at": NOW + 60}, NOW), NOW + 60)
        self.assertEqual(ug.blocked_until({"reason": "weekly ceiling", "resets_at": FUT}, NOW), FUT)
        self.assertGreater(mid, NOW)
        self.assertLessEqual(mid - NOW, 86400 + 3600)


class NewestReading(unittest.TestCase):
    def write(self, root, name, events, mtime):
        os.makedirs(root + "/2026/10/05", exist_ok=True)
        p = f"{root}/2026/10/05/{name}"
        lines = [json.dumps({"timestamp": ts, "payload": {"rate_limits": {"primary":
                 {"used_percent": pct, "window_minutes": 10080, "resets_at": 5}}}}) for ts, pct in events]
        open(p, "w").write("\n".join(lines) + "\n")
        os.utime(p, (mtime, mtime))

    def test_newest_event_wins_even_from_an_earlier_named_file(self):
        with tempfile.TemporaryDirectory() as t:
            # started later (name sorts last) but went quiet; the earlier session kept writing
            self.write(t, "rollout-2026-10-05T22.jsonl", [("2026-10-05T14:00:00Z", 12)], 100)
            self.write(t, "rollout-2026-10-05T18.jsonl", [("2026-10-05T14:50:00Z", 13)], 200)
            self.assertEqual(ug.codex_reading(t)["pct"], 13.0)

    def test_day_start_is_the_last_event_before_midnight(self):
        with tempfile.TemporaryDirectory() as t:
            self.write(t, "rollout-a.jsonl", [("2026-10-05T10:00:00Z", 20), ("2026-10-05T15:00:00Z", 26)],
                       ug.epoch("2026-10-05T15:00:00Z"))
            self.write(t, "rollout-b.jsonl", [("2026-10-05T17:00:00Z", 31)], ug.epoch("2026-10-05T17:00:00Z"))
            mid = ug.epoch("2026-10-05T16:00:00Z")
            with mock.patch.object(ug, "CODEX", t):
                self.assertEqual(ug.codex_day_start(mid)["pct"], 26.0)
                self.assertIsNone(ug.codex_day_start(ug.epoch("2026-10-05T09:00:00Z")))
                self.assertEqual(ug.codex_reading()["pct"], 31.0)

    def test_claude_day_start_must_be_from_today(self):
        with tempfile.TemporaryDirectory() as t:
            p = t + "/d.json"
            json.dump({"seven_day": {"used_percentage": 21, "resets_at": 7}, "_written_at": NOW}, open(p, "w"))
            self.assertEqual(ug.claude_day_start(NOW - 100, p)["pct"], 21.0)
            self.assertIsNone(ug.claude_day_start(NOW + 100, p))


class Show(unittest.TestCase):
    def test_show_lists_every_provider_in_one_table(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 31.0, "resets_at": FUT, "observed_at": NOW},
                                             "codex": lambda: None}), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show"]), 0)
        text = out.getvalue()
        for name in ("claude", "codex", "cursor", "antigravity/claude", "antigravity/gemini-flash", "antigravity/gemini-pro", "no fresh"):
            self.assertIn(name, text)
        self.assertEqual(len([l for l in text.splitlines() if l.startswith("claude")]), 1)

    def test_show_json_is_a_list(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: None, "codex": lambda: None}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            ug.main(["show", "--json"])
        self.assertEqual(sorted(r["provider"] for r in json.loads(out.getvalue())), ["antigravity/claude", "antigravity/gemini-flash", "antigravity/gemini-pro", "claude", "codex", "cursor"])


def summary(pct, ends=FUT, began=NOW - 29 * 86400, enabled=True):
    return {"billingCycleStart": ug.datetime.fromtimestamp(began, timezone.utc).isoformat(),
            "billingCycleEnd": ug.datetime.fromtimestamp(ends, timezone.utc).isoformat(),
            "individualUsage": {"plan": {"enabled": enabled, "totalPercentUsed": pct}}}


class Cursor(unittest.TestCase):
    """Only the Auto + Composer pool establishes Composer headroom."""

    def test_auto_composer_pool_controls_verdict_and_show(self):
        for pct, expected in [(0, 0), (42.5, 0), (95, 3), (100, 3)]:
            with self.subTest(pct=pct), tempfile.TemporaryDirectory() as t, \
                    mock.patch.object(ug, "STATE", t), \
                    mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.object(ug, "running_workers", return_value=0):
                payload = summary(100 if pct < 95 else 0)
                payload["individualUsage"]["plan"].update(autoPercentUsed=pct, apiPercentUsed=100)
                reading = ug.cursor_parse(payload, NOW)
                self.assertEqual(reading, {"pct": pct, "resets_at": FUT, "observed_at": NOW})
                with mock.patch.dict(ug.READERS, {"cursor": lambda: reading}), \
                        contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(ug.main(["check", "--provider", "cursor"]), expected)
                    row = json.loads(out.getvalue())
                    self.assertEqual(row["weekly_used"], pct)
                    self.assertEqual(row["resets_at"], FUT)
                    self.assertIn("cursor auto+composer", ug.table([row]))

    def check(self, pct, baseline=None, ends=NOW + 10 * 86400, running=0, cap=None):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "running_workers", return_value=running):
            if pct is not None:
                path = t + "/summary.json"
                json.dump(summary(pct, ends), open(path, "w"))
                os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
                ug.CURSOR_SUMMARY = path
            else:
                ug.CURSOR_SUMMARY = NO_CURSOR
            if baseline is not None:
                json.dump({"date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"), "baseline": baseline,
                           "resets_at": ends}, open(t + "/cursor.json", "w"))
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    status = ug.main(["check", "--provider", "cursor", *(["--cap", str(cap)] if cap else [])])
            finally:
                ug.CURSOR_SUMMARY = NO_CURSOR
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)
            return status, json.loads(out.getvalue())

    def test_composer_allowance_cannot_be_inferred_from_aggregate_plan_usage(self):
        status, row = self.check(100, baseline=100)
        self.assertEqual((status, row["verdict"]), (4, "unknown"))
        self.assertIn("Composer 2.5", row["reason"])
        self.assertNotIn("weekly_used", row)

    def test_aggregate_plan_usage_never_supplies_composer_usage(self):
        for pct, baseline, running in [(0, 0, 0), (53, 48, 0), (100, 100, 3)]:
            with self.subTest(pct=pct):
                status, row = self.check(pct, baseline=baseline, running=running)
                self.assertEqual((status, row["verdict"]), (4, "unknown"))
                self.assertNotIn("weekly_used", row)
                self.assertIn("read the Cursor dashboard", row["reason"])

    def test_missing_plan_and_source_have_no_composer_reading(self):
        self.assertIsNone(ug.cursor_parse({}, NOW))
        self.assertIsNone(ug.cursor_parse(summary(10, enabled=False), NOW))
        self.assertEqual(self.check(None)[0], 4)

    def test_desktop_and_cli_credentials_read_the_same_pool_without_disclosure(self):
        import base64, sqlite3, urllib.parse, urllib.request
        token = "synthetic." + base64.urlsafe_b64encode(
            b'{"sub":"auth|synthetic-user"}').decode().rstrip("=") + ".signature"
        cases = [("darwin", "desktop"), ("linux", "desktop"),
                 ("darwin", "keychain"), ("darwin", "file"),
                 ("linux", "file"), ("linux", "xdg"),
                 ("darwin", "opaque-desktop-cli"), ("linux", "broken-desktop-cli"),
                 ("darwin", "none"), ("linux", "none")]
        for platform, source in cases:
            with self.subTest(platform=platform, source=source), tempfile.TemporaryDirectory() as t, \
                    mock.patch.object(ug, "HOME", t), mock.patch.object(ug, "CURSOR_SUMMARY", None), \
                    mock.patch.object(ug.sys, "platform", platform), \
                    mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": t + "/config-override"} if source == "xdg" else {}, clear=True), \
                    mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.object(ug.subprocess, "run", return_value=mock.Mock(
                        returncode=0 if source == "keychain" else 44,
                        stdout=token if source == "keychain" else "", stderr="")) as command, \
                    mock.patch.object(urllib.request, "urlopen") as fetch, \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                if source in ("desktop", "opaque-desktop-cli", "broken-desktop-cli"):
                    db = t + ("/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
                              if platform == "darwin" else "/.config/Cursor/User/globalStorage/state.vscdb")
                    os.makedirs(os.path.dirname(db))
                    if source == "broken-desktop-cli":
                        with open(db, "w") as f:
                            f.write("invalid database")
                    else:
                        with sqlite3.connect(db) as con:
                            con.execute("create table ItemTable (key text, value text)")
                            con.execute("insert into ItemTable values (?, ?)",
                                        ("cursorAuth/accessToken", "opaque" if source == "opaque-desktop-cli" else token))
                if source in ("file", "xdg", "opaque-desktop-cli", "broken-desktop-cli"):
                    auth = (t + "/.cursor/auth.json" if platform == "darwin" else
                            t + ("/config-override" if source == "xdg" else "/.config") + "/cursor/auth.json")
                    os.makedirs(os.path.dirname(auth), exist_ok=True)
                    with open(auth, "w") as f:
                        json.dump({"accessToken": token}, f)
                payload = summary(100)
                payload["individualUsage"]["plan"]["autoPercentUsed"] = 23.5
                fetch.return_value.__enter__.return_value = io.StringIO(json.dumps(payload))
                reading = ug.cursor_reading()
                if source == "none":
                    self.assertIsNone(reading)
                    fetch.assert_not_called()
                else:
                    self.assertEqual(reading, {"pct": 23.5, "resets_at": FUT, "observed_at": NOW})
                    request = fetch.call_args.args[0]
                    self.assertEqual(request.full_url, ug.CURSOR_URL)
                    self.assertEqual(urllib.parse.unquote(request.get_header("Cookie")),
                                     "WorkosCursorSessionToken=synthetic-user::" + token)
                if source == "keychain":
                    self.assertEqual(command.call_args.args[0], ["security", "find-generic-password",
                                     "-a", "cursor-user", "-s", "cursor-access-token", "-w"])
                self.assertNotIn(token, output.getvalue() + errors.getvalue())
                for call in command.call_args_list:
                    self.assertNotIn(token, str(call))


class AutoCap(unittest.TestCase):
    """Default cap: what is left of the week under the ceiling, spread over the days left."""

    def mid(self):
        return ug.local_midnight(NOW)

    def test_cap_is_remaining_week_over_days_left(self):
        resets = self.mid() + 4 * 86400                      # today plus 3 more days
        self.assertEqual(ug.auto_cap(35.0, resets, NOW, 95), 15.0)   # (95 - 35) / 4

    def test_a_partial_last_day_counts_as_a_fraction(self):
        resets = self.mid() + 3.125 * 86400                  # resets 03:00 on the 4th day
        self.assertEqual(ug.auto_cap(42.0, resets, NOW, 95), 17.0)   # 53 / 3.125

    def test_the_last_day_may_use_everything_left(self):
        resets = self.mid() + 0.5 * 86400
        self.assertEqual(ug.auto_cap(80.0, resets, NOW, 95), 15.0)

    def test_nothing_left_is_a_zero_cap(self):
        self.assertEqual(ug.auto_cap(97.0, self.mid() + 3 * 86400, NOW, 95), 0.0)

    def test_unknown_reset_falls_back_to_a_seventh_of_the_ceiling(self):
        self.assertEqual(ug.auto_cap(10.0, None, NOW, 95), round(95 / 7, 1))

    def test_decide_uses_the_auto_cap_when_cap_is_none(self):
        resets = self.mid() + 4 * 86400
        v, d, _ = ug.decide(D(50, resets), None, "d1", NOW, None, 95, 0.0, D(35, resets))
        self.assertEqual((v, d["cap"], d["today_used"]), ("allowed", 15.0, 15.0))   # spent 15 of 15
        v, d, _ = ug.decide(D(45, resets), None, "d1", NOW, None, 95, 0.0, D(35, resets))
        self.assertEqual((v, d["cap"], d["today_used"]), ("allowed", 15.0, 10.0))

    def test_cli_default_is_the_auto_cap_and_a_number_still_fixes_it(self):
        resets = self.mid() + 4 * 86400
        reading = {"pct": 45.0, "resets_at": resets, "observed_at": NOW}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading}), \
                mock.patch.object(ug, "running_workers", lambda p: 0), \
                mock.patch.object(ug, "start_of_day", lambda r, p, m: {"pct": 35.0, "resets_at": resets}), \
                mock.patch.object(ug.time, "time", lambda: NOW):
            self.assertEqual(ug.run("claude", None, 95)["cap"], 15.0)
            os.remove(t + "/claude.json")
            self.assertEqual(ug.run("claude", 12, 95)["cap"], 12)


class IdleCodex(unittest.TestCase):
    def test_old_unreset_reading_without_activity_today_is_zero_spend(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t + "/state"), \
                mock.patch.object(ug, "CODEX", t + "/sessions"), \
                mock.patch.object(ug, "running_workers", return_value=1):
            os.makedirs(t + "/sessions")
            p = t + "/sessions/rollout-old.jsonl"
            old = ug.local_midnight(NOW) - 10
            with open(p, "w") as f:
                f.write(json.dumps({"timestamp": old, "payload": {"rate_limits": {"primary":
                    {"used_percent": 39, "window_minutes": 10080, "resets_at": FUT}}}}))
            os.utime(p, (old, old))
            r = ug.run("codex", 12, 95, now=NOW)
            self.assertEqual(r["verdict"], "unknown")
            # Activity without a new rate reading must preserve unknown, including non-rollout files.
            with open(t + "/sessions/other.jsonl", "w") as f:
                f.write("{}")
            os.utime(t + "/sessions/other.jsonl", (NOW, NOW))
            self.assertEqual(ug.run("codex", 12, 95, now=NOW)["verdict"], "unknown")

    def test_idle_reading_still_blocks_with_running_reserve_and_expired_week_stays_unknown(self):
        old = ug.local_midnight(NOW) - 10
        reading = {"pct": 94.0, "resets_at": FUT, "observed_at": old}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug, "CODEX", t + "/sessions"), \
                mock.patch.dict(ug.READERS, {"codex": lambda: reading, "claude": lambda: reading}), \
                mock.patch.object(ug, "running_workers", return_value=1):
            r = ug.run("codex", 12, 95, now=NOW)
            self.assertEqual(r["verdict"], "unknown")
            self.assertEqual(ug.run("claude", 12, 95, now=NOW)["verdict"], "unknown")
            reading["resets_at"] = NOW - 1
            self.assertEqual(ug.run("codex", 12, 95, now=NOW)["verdict"], "unknown")



class Pick(unittest.TestCase):
    def invoke(self, chain=None, role="fullstack-dev", claude=44, codex=41, extra=(), pin=False,
               running=0, default=False, cap=12, codex_baseline=40):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug, "CODEX", t + "/sessions"), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "running_workers", return_value=running), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()) as err:
            chain = chain or [{"provider": "claude", "model": "sonnet", "effort": "medium"},
                              {"provider": "codex", "model": "gpt-test", "effort": "low"},
                              {"provider": "cursor", "model": "claude-test"},
                              {"provider": "antigravity", "model": "gemini-test"}]
            presets = {"default_chain": ["codex", "claude", "cursor", "antigravity"],
                       "roles": {"fullstack-dev" if default else role:
                                 {"chain": chain, "tier": "workhorse", "pin": pin}}}
            with open(t + "/presets.json", "w") as f:
                json.dump(presets, f)
            for provider, pct in (("claude", claude), ("codex", codex)):
                if pct is None:
                    continue
                with open(t + "/" + provider + ".json", "w") as f:
                    json.dump({"date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"),
                               "baseline": codex_baseline if provider == "codex" else 40, "resets_at": FUT}, f)
                if provider == "claude":
                    with open(t + "/claude-rate-limits.json", "w") as f:
                        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT},
                                   "_written_at": NOW}, f)
                else:
                    os.makedirs(t + "/sessions")
                    with open(t + "/sessions/rollout-test.jsonl", "w") as f:
                        json.dump({"timestamp": NOW, "payload": {"rate_limits": {"primary":
                            {"used_percent": pct, "window_minutes": 10080, "resets_at": FUT}}}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/presets.json"}):
                status = ug.main(["pick", "--role", role, *(["--cap", str(cap)] if cap is not None else []), *extra])
            return status, out.getvalue(), err.getvalue()

    def test_picks_largest_fraction_and_prints_flags_and_reasons(self):
        status, out, err = self.invoke()
        self.assertEqual((status, out.strip()), (0, "--agent codex --model gpt-test --effort low"))
        for provider in ("claude", "codex", "cursor", "antigravity"):
            self.assertIn(provider, err)

    def test_ranks_by_fraction_of_auto_cap_rather_than_absolute_room(self):
        status, out, _ = self.invoke(claude=44, codex=81, codex_baseline=80, cap=None, extra=("--json",))
        result = json.loads(out)
        claude, codex = result["candidates"][:2]
        self.assertGreater(claude["headroom"], codex["headroom"])
        self.assertEqual((status, result["selected"]["provider"]), (0, "claude"))

    def test_near_tie_keeps_the_preset_provider_whichever_reads_higher(self):
        # Readings 1 point apart in either direction must not flip the pick (issue 107).
        for claude, codex in ((44, 44), (45, 44), (44, 45), (46, 44)):
            with self.subTest(claude=claude, codex=codex):
                self.assertIn("--agent claude", self.invoke(claude=claude, codex=codex, cap=None)[1])

    def test_clearly_lower_preset_switches_and_blocked_preset_switches(self):
        self.assertIn("--agent codex", self.invoke(claude=60, codex=44, cap=None)[1])
        self.assertIn("--agent codex", self.invoke(claude=95, codex=44, cap=None)[1])

    def test_ties_keep_chain_order_and_reserve_can_block_all_gated_providers(self):
        self.assertIn("--agent claude", self.invoke(codex=44)[1])
        self.assertEqual(self.invoke(claude=94, codex=94, running=1)[0], 4)   # cursor has no reading, which proves nothing

    def test_pinned_roles_keep_first_allowed_entry(self):
        for role, pin in (("elon", False), ("release-manager", False), ("custom", True)):
            with self.subTest(role):
                self.assertIn("--agent claude", self.invoke(role=role, pin=pin)[1])
                self.assertIn("--agent codex", self.invoke(role=role, pin=pin, claude=95)[1])

    def test_review_excludes_family_even_for_pinned_roles(self):
        self.assertIn("--agent claude", self.invoke(extra=("--avoid-family", "gpt"))[1])
        self.assertIn("--agent codex", self.invoke(role="elon", extra=("--avoid-family", "claude"))[1])
        # Claude models on both ungated providers are also excluded.
        chain = [{"provider": "claude", "model": "opus"},
                 {"provider": "cursor", "model": "claude-opus"},
                 {"provider": "antigravity", "model": "claude-opus"}]
        status, out, err = self.invoke(chain=chain, claude=95, extra=("--avoid-family", "claude"))
        self.assertEqual((status, out), (4, ""))
        self.assertIn(ug.local(FUT), err)
        chain = [{"provider": "cursor", "model": "gpt-test"}]
        self.assertEqual(self.invoke(chain=chain, extra=("--avoid-family", "gpt"))[0], 4)

    def test_ungated_is_only_a_last_resort_and_unknown_does_not_prove_blocked(self):
        self.assertIn("--agent codex", self.invoke(claude=95)[1])
        self.assertEqual(self.invoke(claude=95, codex=95)[0], 4)   # cursor has no reading, so antigravity is not a fallback yet
        self.assertEqual(self.invoke(claude=None, codex=95)[0], 4)
        self.assertEqual(self.invoke(extra=("--avoid-family", "gpt"), claude=None)[0], 4)

    def test_unknown_role_uses_default_chain_and_models_from_file(self):
        status, out, _ = self.invoke(role="unlisted", default=True, claude=41)
        self.assertEqual((status, out.strip()), (0, "--agent codex --model gpt-test --effort low"))

    def test_json_includes_selection_headroom_and_every_candidate(self):
        status, out, _ = self.invoke(extra=("--json",), running=2)
        result = json.loads(out)
        self.assertEqual((status, result["selected"]["provider"], result["selected"]["headroom"]),
                         (0, "codex", 52))
        self.assertEqual(len(result["candidates"]), 4)

    def test_no_allowed_entry_reports_earliest_reset_and_exit_three_in_json(self):
        chain = [{"provider": "claude", "model": "opus"}, {"provider": "codex", "model": "gpt-test"}]
        status, out, _ = self.invoke(chain=chain, claude=96, codex=95, extra=("--json",))
        result = json.loads(out)
        self.assertEqual((status, result["selected"], result["blocked_until"]),
                         (3, None, FUT))

    def test_reviewer_avoid_claude_picks_codex_when_allowed(self):
        status, out, _ = self.invoke(role="reviewer", chain=REVIEWER_CHAIN, claude=95, codex=44,
                                     extra=("--avoid-family", "claude"))
        self.assertEqual((status, out.strip()), (0, "--agent codex --model gpt-6.1-sol --effort medium"))

    def test_reviewer_avoid_claude_picks_antigravity_flash_when_codex_blocked(self):
        pools = {"gemini-flash": {"pct": 5, "resets_at": FUT, "observed_at": NOW}}
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            presets = {"default_chain": ["codex", "cursor", "antigravity"],
                       "roles": {"reviewer": {"chain": REVIEWER_CHAIN, "tier": "workhorse"}}}
            with open(t + "/presets.json", "w") as f:
                json.dump(presets, f)
            for provider, pct in (("claude", 95), ("codex", 96)):
                with open(t + "/" + provider + ".json", "w") as f:
                    json.dump({"date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"),
                               "baseline": 40, "resets_at": FUT}, f)
                if provider == "claude":
                    with open(t + "/claude-rate-limits.json", "w") as f:
                        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT},
                                   "_written_at": NOW}, f)
                else:
                    os.makedirs(t + "/sessions")
                    with open(t + "/sessions/rollout-test.jsonl", "w") as f:
                        json.dump({"timestamp": NOW, "payload": {"rate_limits": {"primary":
                            {"used_percent": pct, "window_minutes": 10080, "resets_at": FUT}}}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/presets.json"}):
                with mock.patch.object(ug, "STATE", t):
                    status = ug.main(["pick", "--role", "reviewer", "--avoid-family", "claude"])
        self.assertEqual(status, 0)
        self.assertIn("--agent antigravity --model gemini-3.8-flash", out.getvalue().strip())

    def test_reviewer_avoid_claude_nothing_when_all_cross_family_blocked(self):
        status, out, err = self.invoke(role="reviewer", chain=REVIEWER_CHAIN, claude=95, codex=96,
                                       extra=("--avoid-family", "claude"))
        self.assertEqual((status, out), (4, ""))

    def test_reviewer_preset_chain_models(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
        with open(path) as f:
            chain = json.load(f)["roles"]["reviewer"]["chain"]
        by_provider = {entry["provider"]: entry["model"] for entry in chain}
        self.assertEqual(by_provider["codex"], "gpt-6.1-sol")
        self.assertEqual(by_provider["cursor"], "composer-2.5")
        self.assertEqual(by_provider["antigravity"], "gemini-3.8-flash")
        self.assertNotIn("gpt-5.6-sol", by_provider.values())
        self.assertTrue(all(not m.startswith("claude-") for m in by_provider.values()))


class PickOrder(unittest.TestCase):
    def test_show_orders_by_fraction_with_unknown_providers_last(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 31.0, "resets_at": FUT, "observed_at": NOW},
                                             "codex": lambda: None}), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            ug.main(["show"])
        self.assertEqual(out.getvalue().splitlines()[-1],
                         "pick order now: claude 67.4%, codex refresh returned no fresh valid usage reading, cursor no reliable Composer 2.5 allowance reading; read the Cursor dashboard, antigravity/claude GetUserStatus returned no fresh valid pool quota, antigravity/gemini-flash GetUserStatus returned no fresh valid pool quota, antigravity/gemini-pro GetUserStatus returned no fresh valid pool quota")

    def test_show_handles_a_stale_weekly_ceiling_without_daily_numbers(self):
        reading = {"pct": 96, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading, "codex": lambda: None}), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show"]), 0)
        self.assertIn("unknown", out.getvalue())
        self.assertNotIn("blocked", out.getvalue())


class CodexWorkerBase(unittest.TestCase):
    def test_new_worktree_uses_origin_head_and_preserves_explicit_override(self):
        import subprocess
        script = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "start-codex-worker.sh"))
        with tempfile.TemporaryDirectory() as t:
            subprocess.run(["git", "init", "-q", t], check=True)
            subprocess.run(["git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"],
                           cwd=t, check=True)
            stub = t + "/orca"
            with open(stub, "w") as f:
                f.write("#!/bin/sh\n")
                f.write('if [ "$1 $2" = "worktree create" ]; then\n')
                f.write('  printf "%s\\n" "$@" > "$TEST_BASE_LOG"\n')
                f.write("  echo '{\"result\":{\"worktree\":{\"path\":\"/tmp/unused\"}}}'\n")
                f.write("else exit 1; fi\n")
            os.chmod(stub, 0o755)
            env = {**os.environ, "ORCA_CLI_COMMAND": stub, "TEST_BASE_LOG": t + "/args",
                   "ORCA_TERMINAL_HANDLE": "term_test"}
            with open(t + "/spec", "w") as f:
                f.write("Check the base branch using the stub CLI.")
            args = ["bash", script, "--run", "unused", "--spec", t + "/spec", "--title", "unused",
                    "--name", "unused", "--repo", t]
            for override, expected in (([], "origin/master"), (["--base-branch", "origin/release"], "origin/release")):
                subprocess.run(args + override, env=env, capture_output=True)
                with open(t + "/args") as f:
                    flags = f.read().splitlines()
                self.assertEqual(flags[flags.index("--base-branch") + 1], expected)


class RealReadingPolicy(unittest.TestCase):
    def setUp(self):
        module_spec = importlib.util.spec_from_file_location("real_gate", spec.origin)
        self.gate = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(self.gate)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.gate.STATE = self.tmp.name

    def test_cursor_opaque_app_token_reports_dashboard_without_inventing_usage(self):
        import sqlite3, urllib.request
        gate = self.gate
        with mock.patch.object(gate, "HOME", self.tmp.name), \
                mock.patch.object(gate.sys, "platform", "darwin"), \
                mock.patch.object(gate.subprocess, "run", return_value=mock.Mock(returncode=44, stdout="")), \
                mock.patch.object(urllib.request, "urlopen") as fetch, \
                contextlib.redirect_stdout(io.StringIO()) as out:
            db = self.tmp.name + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            os.makedirs(os.path.dirname(db))
            con = sqlite3.connect(db)
            con.execute("create table ItemTable (key text, value text)")
            # Redacted real credential shape: opaque string, not a JWT with a sub.
            con.execute("insert into ItemTable values (?, ?)",
                        ("cursorAuth/accessToken", "redacted-opaque-token"))
            con.commit()
            con.close()
            self.assertEqual(gate.main(["check", "--provider", "cursor", "--model", "composer-2.5"]), 4)
            row = json.loads(out.getvalue())
            self.assertEqual(row["verdict"], "unknown")
            self.assertIn("read the Cursor dashboard", row["reason"])
            self.assertNotIn("weekly_used", row)
            self.assertNotIn("redacted-opaque-token", out.getvalue())
            fetch.assert_not_called()

    def test_stale_ceiling_refresh_can_allow_and_never_infers_zero_after_reset(self):
        gate = self.gate
        old = {"pct": 99, "resets_at": NOW - 1, "observed_at": NOW - 600}
        new = {"pct": 3, "resets_at": FUT, "observed_at": NOW}
        with mock.patch.dict(gate.READERS, {"codex": lambda: old}), \
                mock.patch.object(gate, "refresh_reading", return_value=new) as refresh, \
                mock.patch.object(gate, "running_workers", return_value=0):
            result = gate.run("codex", 1, 95, now=NOW)
        refresh.assert_called_once_with("codex")
        self.assertEqual((result["verdict"], result["weekly_used"]), ("allowed", 3))
        self.assertEqual(result["source"], "codex app-server account/rateLimits/read")

    def test_failed_refresh_is_unknown_with_exact_source_age_and_no_invented_number(self):
        gate = self.gate
        old = {"pct": 99, "resets_at": FUT, "observed_at": NOW - 600}
        with mock.patch.dict(gate.READERS, {"claude": lambda: old}), \
                mock.patch.object(gate, "refresh_reading", side_effect=TimeoutError("secret response")):
            result = gate.run("claude", None, 95, now=NOW)
        self.assertEqual(result["verdict"], "unknown")
        self.assertEqual(result["reading_age_min"], 10)
        self.assertIn("api.anthropic.com/api/oauth/usage", result["source"])
        self.assertIn("TimeoutError", result["reason"])
        self.assertNotIn("weekly_used", result)
        self.assertNotIn("secret", json.dumps(result))

    def test_missing_reading_refresh_can_block_only_on_real_week_plus_full_reserve(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"claude": lambda: None}), \
                mock.patch.object(gate, "refresh_reading", return_value={"pct": 93, "resets_at": FUT, "observed_at": NOW}), \
                mock.patch.object(gate, "running_workers", return_value=2):
            result = gate.run("claude", .1, 95, now=NOW)
        self.assertEqual((result["verdict"], result["reserve"], result["reason"]), ("blocked", 2, "weekly ceiling"))

    def test_fresh_reading_does_not_refresh_and_invalid_numbers_never_decide(self):
        gate = self.gate
        for pct in (float('nan'), float('inf'), -1, 101):
            self.assertIsNone(gate.fresh({"pct": pct, "observed_at": NOW}, NOW))
        with mock.patch.dict(gate.READERS, {"claude": lambda: {"pct": 90, "observed_at": NOW, "resets_at": FUT}}), \
                mock.patch.object(gate, "refresh_reading") as refresh, \
                mock.patch.object(gate, "running_workers", return_value=0):
            result = gate.run("claude", None, 95, now=NOW)
        refresh.assert_not_called()
        self.assertEqual(result["verdict"], "allowed")
        self.assertIn("claude-rate-limits.json", result["source"])

    def test_broken_local_reader_refreshes_instead_of_crashing(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"codex": mock.Mock(side_effect=ValueError("bad local data"))}), \
                mock.patch.object(gate, "codex_refresh", return_value={"pct": 20, "observed_at": NOW}), \
                mock.patch.object(gate, "running_workers", return_value=0):
            self.assertEqual(gate.run("codex", None, 95, now=NOW)["verdict"], "allowed")

    def test_refresh_age_uses_the_clock_after_provider_response(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"codex": lambda: None}), \
                mock.patch.object(gate, "refresh_reading", return_value={"pct": 20, "observed_at": NOW + 10}), \
                mock.patch.object(gate.time, "time", side_effect=[NOW, NOW, NOW + 10]), \
                mock.patch.object(gate, "running_workers", return_value=0):
            result = gate.run("codex", None, 95)
        self.assertEqual((result["verdict"], result["reading_age_min"]), ("allowed", 0))

    def test_codex_refresh_reads_real_account_rpc_without_a_model_turn(self):
        gate = self.gate
        path = self.tmp.name + '/codex'
        with open(path, 'w') as f:
            f.write('''#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
    d=json.loads(line)
    if d['method']=='initialize': print(json.dumps({'id':1,'result':{}}),flush=True)
    elif d['method']=='account/rateLimits/read':
        print(json.dumps({'id':2,'result':{'rateLimits':{'secondary':{
            'usedPercent':41,'windowDurationMins':10080,'resetsAt':2000000000}}}}),flush=True)
    elif d['method']!='initialized': sys.exit(1)
''')
        os.chmod(path, 0o755)
        with mock.patch.dict(os.environ, {'PATH':self.tmp.name + ':' + os.environ['PATH']}):
            reading = gate.codex_refresh()
        self.assertEqual((reading['pct'], reading['resets_at']), (41, 2000000000))
        self.assertIsNotNone(gate.fresh(reading, gate.time.time()))

    def test_claude_refresh_uses_own_usage_response(self):
        import urllib.request
        gate = self.gate
        gate.HOME = self.tmp.name
        os.makedirs(self.tmp.name + '/.claude')
        with open(self.tmp.name + '/.claude/.credentials.json', 'w') as f:
            json.dump({'claudeAiOauth':{'accessToken':'synthetic'}}, f)
        body = io.StringIO(json.dumps({'seven_day':{'utilization':42, 'resets_at':FUT}}))
        with mock.patch.object(urllib.request, 'urlopen', return_value=body) as fetch:
            reading = gate.claude_refresh()
        self.assertEqual(reading['pct'], 42)
        self.assertEqual(fetch.call_args.args[0].full_url, 'https://api.anthropic.com/api/oauth/usage')

    def test_running_reserve_includes_retained_live_workers_on_later_pages(self):
        gate = self.gate
        pages = [mock.Mock(stdout=json.dumps({'result':{'workers':[], 'page':{'hasMore':True,'nextCursor':'page2'}}})),
                 mock.Mock(stdout=json.dumps({'result':{'workers':[
                     {'terminalState':'retained','dispatchStatus':'dispatched','projection':{'provider':{'id':'codex'},'liveness':{'verdict':'live'}}},
                     {'terminalState':'retained','dispatchStatus':'completed','projection':{'provider':{'id':'codex'}}}], 'page':{'hasMore':False}}}))]
        with mock.patch.object(gate.subprocess, 'run', side_effect=pages) as query:
            self.assertEqual(gate.running_workers('codex'), 1)
        self.assertIn('page2', query.call_args.args[0])


if __name__ == "__main__":
    unittest.main()


class Banner(unittest.TestCase):
    TEXT = "Individual quota reached for claude-sonnet-5-5-high. Resets in 94h29m"

    def test_flash_banner_does_not_exhaust_pro_and_legacy_gemini_is_ignored(self):
        with tempfile.TemporaryDirectory() as t:
            path = t + "/banner.json"
            with open(path, "w") as f:
                json.dump({"gemini": FUT}, f)  # old ambiguous pool
            self.assertEqual(ug.record_quota_banner(
                "gemini-3.8-flash quota reached. Resets in 2h", NOW, path), "gemini-flash")
            with mock.patch.object(ug, "BANNER_FILE", path), \
                    mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.object(ug, "antigravity_pools", return_value={
                        "gemini-pro": {"pct": 20, "resets_at": FUT, "observed_at": NOW}}):
                pools = ug.antigravity_reading()
                self.assertEqual(set(pools), {"gemini-flash", "gemini-pro"})
                self.assertEqual(ug.antigravity_result(pools, 95, NOW,
                    model="gemini-4-argon-low")["verdict"], "allowed")
                self.assertEqual(ug.antigravity_result(pools, 95, NOW,
                    model="gemini-3.8-flash")["verdict"], "blocked")

    def test_parses_pool_and_reset(self):
        self.assertEqual(ug.parse_quota_banner(self.TEXT, NOW), ("claude", NOW + 94 * 3600 + 29 * 60))
        self.assertEqual(ug.parse_quota_banner("gemini-4-argon-low quota reached, resets in 2h", NOW),
                         ("gemini-pro", NOW + 7200))
        self.assertIsNone(ug.parse_quota_banner("gemini-4 quota reached, resets in 2h", NOW))
        self.assertIsNone(ug.parse_quota_banner("all good", NOW))
        self.assertIsNone(ug.parse_quota_banner("quota reached. Resets in 5h", NOW))  # no pool named

    def test_banner_blocks_the_pool_until_reset_and_unknown_is_not_eligible(self):
        with tempfile.TemporaryDirectory() as t:
            path = t + "/banner.json"
            self.assertEqual(ug.record_quota_banner(self.TEXT, NOW, path), "claude")
            with mock.patch.object(ug, "BANNER_FILE", path), \
                    mock.patch.object(ug, "antigravity_pools", return_value=None), \
                    mock.patch.object(ug, "running_workers", return_value=0), \
                    mock.patch.object(ug.time, "time", return_value=NOW + 60):
                pools = ug.antigravity_reading()
                self.assertEqual(set(pools), {"claude"})
                row = ug.antigravity_result(pools, 95, NOW + 60, model="claude-sonnet-5-5-high")
                self.assertEqual((row["verdict"], row["blocked_until"]), ("blocked", NOW + 94 * 3600 + 29 * 60))
                self.assertEqual(ug.antigravity_result(pools, 95, NOW + 60, model="gemini-4-argon-low")["verdict"],
                                 "unknown")
            with mock.patch.object(ug, "BANNER_FILE", path), \
                    mock.patch.object(ug, "antigravity_pools", return_value=None), \
                    mock.patch.object(ug.time, "time", return_value=NOW + 95 * 3600):
                self.assertIsNone(ug.antigravity_reading())

    def test_unlisted_model_id_is_not_eligible(self):
        pools = {"gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW}}
        chain = [{"provider": "antigravity", "model": "gemini-3.1-pro-high"}]
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug, "antigravity_models", return_value={"gemini-4-argon-low"}), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            with open(t + "/p.json", "w") as f:
                json.dump({"roles": {"dev": {"chain": chain}}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/p.json"}):
                result = ug.pick("dev", None, None, 95, 1)
        self.assertIsNone(result["selected"])
        self.assertEqual(result["candidates"][0]["verdict"], "model not recognized")
