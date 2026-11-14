import contextlib, importlib.util, io, json, os, sys, tempfile, time, unittest
from datetime import timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import asdf_pin  # noqa: E402

asdf_pin.pin()  # before any test sets HOME

spec = importlib.util.spec_from_file_location("ug", os.path.join(os.path.dirname(__file__), "..", "usage-gate.py"))
ug = importlib.util.module_from_spec(spec); spec.loader.exec_module(ug)
NO_CURSOR = "/nonexistent/cursor-summary.json"
ug.READERS["antigravity"] = lambda: None  # tests never query the local server
ug.antigravity_models = lambda: None  # tests never run the Antigravity CLI
ug.BANNER_FILE = "/nonexistent/antigravity-banner.json"  # tests never read real banners
ug.refresh_reading = lambda provider: None  # isolate provider refresh transport in legacy unit cases
ug.CURSOR_SUMMARY = NO_CURSOR  # tests never reach the network
real_live_workers = ug.live_workers
ug.live_workers = lambda provider: []  # tests never run orca; the running count cases patch this


def rows(n, model="sonnet"):
    """n running worker rows (None: orca could not say)."""
    return None if n is None else [{"agent": "claude", "model": model} for _ in range(n)]
ug.CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "usage-gate.config.json")
NOW = 1_000_000_000.0
FUT = NOW + 86400
D = lambda pct, resets=FUT: {"pct": pct, "resets_at": resets}
REVIEWER_CHAIN = [{"provider": "other", "model": "gpt-6.1-sol", "effort": "medium"},
                  {"provider": "cursor", "model": "grok-4.7-xhigh"},
                  {"provider": "antigravity", "model": "gemini-3.8-flash"}]


class Antigravity(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(ug, "live_workers", return_value=rows(0))
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
                                  ("gemini-flash", 0), (None, 0), ("unknown", 0)]:
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
            self.assertEqual(ug.main(["check", "--provider", "antigravity"]), 0)

    def test_lsof_falls_back_to_usr_sbin_when_missing_from_path(self):
        import urllib.request
        processes = mock.Mock(stdout="123 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token synthetic\n")
        ports = mock.Mock(stdout="server 123 TCP 127.0.0.1:12345 (LISTEN)")
        calls = []

        def run(argv, **_kwargs):
            calls.append(argv)
            return processes if argv[0] == "ps" else ports

        real_access = os.access

        def access(path, mode):
            if path == "/usr/sbin/lsof":
                return True
            return real_access(path, mode)

        with mock.patch.object(ug.subprocess, "run", side_effect=run), \
                mock.patch.object(ug.shutil, "which", return_value=None), \
                mock.patch.object(ug.os, "access", side_effect=access), \
                mock.patch.object(urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = TimeoutError()
            self.assertIsNone(ug.antigravity_reading())
        self.assertEqual(calls[1][0], "/usr/sbin/lsof")

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

    def test_reviewer_falls_back_to_qa_sdet_chain_with_gemini(self):
        with tempfile.TemporaryDirectory() as t:
            path = t + "/presets.json"
            with open(path, "w") as f:
                json.dump(json.load(open(os.path.join(os.path.dirname(__file__), "../../.orca/presets.json")))
                          | {"roles": {k: v for k, v in json.load(open(os.path.join(
                              os.path.dirname(__file__), "../../.orca/presets.json")))["roles"].items()
                              if k != "reviewer"}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}):
                chain, _ = ug.role_chain("reviewer")
        self.assertIn({"provider": "antigravity", "model": "gemini-4-argon-high"}, chain)

    def test_show_lists_three_pools_with_local_resets(self):
        pools = {"claude": {"pct": 50, "resets_at": FUT, "observed_at": NOW},
                 "gemini-flash": {"pct": 2, "resets_at": FUT, "observed_at": NOW},
                 "gemini-pro": {"pct": 100, "resets_at": FUT, "observed_at": NOW}}
        with mock.patch.dict(ug.READERS, {"antigravity": lambda: pools}), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
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
        v, d, _ = self.go(D(52), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 40, "resets_at": FUT})
        self.assertEqual((v, d["note"]), ("allowed", "pacing: prefer a lighter model"))

    def test_allows_below_cap(self):
        v, _, _ = self.go(D(51.9), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 40, "resets_at": FUT})
        self.assertEqual(v, "allowed")

    def test_new_day_resets_baseline(self):
        v, d, st = self.go(D(70), {"v": ug.STATE_VERSION, "date": "d0", "baseline": 40, "resets_at": FUT})
        self.assertEqual((v, st["baseline"], st["date"]), ("allowed", 70, "d1"))

    def test_weekly_ceiling_blocks_even_under_cap(self):
        v, d, _ = self.go(D(96), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 95, "resets_at": FUT})
        self.assertEqual((v, d["reason"]), ("blocked", "weekly ceiling"))

    def test_week_rollover_counts_from_zero(self):
        v, d, _ = self.go(D(3, FUT + 604800), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 90, "resets_at": FUT})
        self.assertEqual((v, d["today_used"]), ("allowed", 3.0))

    def test_expired_reading_is_zero(self):
        v, d, _ = self.go(D(99, NOW - 5), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 90, "resets_at": NOW - 5})
        self.assertEqual((v, d["reason"]), ("unknown", "stale or expired reading"))

    def test_resets_at_jitter_is_the_same_week(self):
        v, d, st = self.go(D(40, FUT + 1), {"v": ug.STATE_VERSION, "date": "d1", "baseline": 38, "resets_at": FUT})
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 2.0, 38))

    def test_no_reading_is_unknown(self):
        self.assertEqual(self.go(None, None)[0], "unknown")


class Main(unittest.TestCase):
    def test_unreadable_provider_is_no_reading_not_a_usage_error(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["check", "--provider", "made-up"]), 4)
        self.assertEqual(json.loads(out.getvalue())["verdict"], "unknown")

    def test_antigravity_with_no_reading_is_allowed_and_claude_with_none_is_refused(self):
        # Owner 2026-11-12 and 2026-11-13: Antigravity starts with no quota reading and stops at the first
        # quota or sign-in error. Claude with no reading and no usable last good one is blocked.
        for name, expected, verdict in (("antigravity", 0, "allowed"), ("claude", 4, "unknown")):
            with self.subTest(name), tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                    mock.patch.dict(ug.READERS, {"claude": lambda: None}), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ug.main(["check", "--provider", name]), expected)
            row = json.loads(out.getvalue())
            self.assertEqual(row["verdict"], verdict)
            self.assertEqual("note" in row, name == "antigravity")

    def test_check_and_pick_agree_that_antigravity_with_no_reading_is_allowed(self):
        with contextlib.redirect_stdout(io.StringIO()):
            check = ug.main(["check", "--provider", "antigravity", "--model", "gemini-3.8-flash"])
        row = ug.run("antigravity", None, None, model="gemini-3.8-flash")
        self.assertEqual((check, row["verdict"]), (0, "allowed"))
        with mock.patch.object(ug, "role_chain", return_value=(
                [{"provider": "antigravity", "model": "gemini-3.8-flash"}], False)), \
                mock.patch.object(ug, "is_builder_role", return_value=False):
            chosen = ug.pick("qa-sdet", None, None, None, None)["selected"]
        self.assertEqual((chosen["provider"], chosen["verdict"]), ("antigravity", "allowed"))

    def test_antigravity_blocked_still_exits_3(self):
        with mock.patch.object(ug, "run", return_value={"provider": "antigravity", "verdict": "blocked"}), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ug.main(["check", "--provider", "antigravity"]), 3)

    def test_check_without_provider_fails_closed_on_unknown_and_mixed_verdicts(self):
        cases = [
            ({"claude": "unknown", "cursor": "unknown", "antigravity": "unknown"}, 4),
            ({"claude": "blocked", "cursor": "unknown", "antigravity": "unknown"}, 4),
            ({"claude": "blocked", "cursor": "blocked", "antigravity": "blocked"}, 3),
            ({"claude": "unknown", "cursor": "allowed", "antigravity": "blocked"}, 0),
        ]
        for verdicts, expected in cases:
            with self.subTest(verdicts=verdicts), \
                    mock.patch.object(ug, "run", side_effect=lambda name, *a, **k: {"provider": name, "verdict": verdicts[name]}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ug.main(["check"]), expected)


class Fresh(unittest.TestCase):
    def test_old_reading_past_its_reset_is_no_reading(self):
        old = {"pct": 99.0, "resets_at": NOW - 5, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertIsNone(ug.fresh(old, NOW))

    def test_old_reading_before_its_reset_is_kept_as_stale(self):
        old = {"pct": 99.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertIsNone(ug.fresh(old, NOW))

    def test_recent_reading_is_kept_whatever_its_timestamp_format(self):
        for at in (NOW - 60, "2001-09-09T01:45:40.000Z"):  # epoch seconds (claude) or ISO
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

    ST = {"v": ug.STATE_VERSION, "date": "d1", "baseline": 40, "resets_at": FUT}

    def test_reserve_lowers_the_cap_for_new_starts(self):
        self.assertEqual(self.go(D(50.9), self.ST, 1)[0], "allowed")
        v, d, _ = self.go(D(51), self.ST, 1)       # 11 spent + 1 reserved = 12
        self.assertEqual((v, d["note"], d["reserve"]), ("allowed", "pacing: prefer a lighter model", 1))

    def test_reserve_lowers_the_ceiling_too(self):
        st = {"v": ug.STATE_VERSION, "date": "d1", "baseline": 90, "resets_at": FUT}
        self.assertEqual(self.go(D(93), st, 1)[0], "allowed")
        self.assertEqual(self.go(D(94), st, 1)[1]["reason"], "weekly ceiling")

    def test_no_running_workers_keeps_the_plain_cap(self):
        self.assertEqual(self.go(D(51.9), self.ST, 0)[0], "allowed")

    def run_with(self, running, per_worker=1.0, pct=50.0):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": pct, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug, "live_workers", return_value=rows(running)), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            ug.json.dump({"v": ug.STATE_VERSION, "date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"), "baseline": 40,
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
        rows = [{"projection": {"provider": {"id": p}, "liveness": {"verdict": "live"}}}
                for p in ("claude", "cursor", "claude")]
        def out(args, **kwargs):
            result = {"runs": [{"id": "run_a"}]} if "run-list" in args else {"workers": rows}
            return mock.Mock(stdout=json.dumps({"result": result}))
        with mock.patch.object(ug, "live_workers", real_live_workers), \
                mock.patch.object(ug.subprocess, "run", side_effect=out):
            self.assertEqual((ug.running_workers("claude"), ug.running_workers("cursor")), (2, 1))
        with mock.patch.object(ug, "live_workers", real_live_workers), \
                mock.patch.object(ug.subprocess, "run", side_effect=FileNotFoundError):
            self.assertIsNone(ug.running_workers("claude"))


class DayStart(unittest.TestCase):
    """'Today' counts from the start of the local day, not from the first check."""

    def go(self, reading, day_start):
        return ug.decide(reading, None, "d1", NOW, 12, 95, 0.0, day_start)

    def test_first_check_late_in_the_day_still_counts_the_morning(self):
        v, d, st = self.go(D(60), D(45))
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 15.0, 45))

    def test_week_reset_since_the_day_start_counts_from_zero(self):
        v, d, _ = self.go(D(13, FUT + 604800), D(80, FUT))   # weekly reset at noon: week = today
        self.assertEqual((v, d["today_used"]), ("allowed", 13.0))

    def test_a_week_that_began_today_started_from_zero(self):
        mid = NOW - 3600
        began_today = {"pct": 13.0, "resets_at": mid + 3600 + 604800 - 1800}      # reset - 7 days = 30 min after midnight
        self.assertEqual(ug.start_of_day(began_today, "claude", mid), {"pct": 0.0, "resets_at": began_today["resets_at"]})
        older = {"pct": 13.0, "resets_at": mid + 604800 - 1}                       # began 1 s before midnight
        with mock.patch.dict(ug.DAY_START, {"claude": lambda m: "from logs"}):
            self.assertEqual(ug.start_of_day(older, "claude", mid), "from logs")
        self.assertIsNone(ug.start_of_day(older, "antigravity", mid))

    def test_no_day_start_falls_back_to_the_first_check(self):
        self.assertEqual(self.go(D(60), None)[1]["today_used"], 0.0)

    def test_a_day_start_never_exceeds_the_reading(self):
        self.assertEqual(self.go(D(40), D(50))[1]["today_used"], 0.0)

    def test_blocked_until_is_local_midnight_for_the_daily_cap_and_the_reset_for_the_ceiling(self):
        mid = ug.next_midnight(NOW)
        self.assertEqual(ug.blocked_until({"reason": "daily cap", "resets_at": FUT + 9 * 86400}, NOW), mid)
        self.assertEqual(ug.blocked_until({"reason": "daily cap", "resets_at": NOW + 60}, NOW), mid)
        self.assertEqual(ug.blocked_until({"reason": "weekly ceiling", "resets_at": FUT}, NOW), FUT)
        self.assertGreater(mid, NOW)
        self.assertLessEqual(mid - NOW, 86400 + 3600)


class DayStartReading(unittest.TestCase):
    def test_claude_day_start_must_be_from_today(self):
        with tempfile.TemporaryDirectory() as t:
            p = t + "/d.json"
            json.dump({"seven_day": {"used_percentage": 21, "resets_at": 7}, "_written_at": NOW}, open(p, "w"))
            self.assertEqual(ug.claude_day_start(NOW - 100, p)["pct"], 21.0)
            self.assertIsNone(ug.claude_day_start(NOW + 100, p))


class Show(unittest.TestCase):
    def test_show_lists_every_provider_in_one_table(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 31.0, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show"]), 0)
        text = out.getvalue()
        for name in ("claude", "cursor", "antigravity/claude", "antigravity/gemini-flash", "antigravity/gemini-pro", "no fresh"):
            self.assertIn(name, text)
        self.assertEqual(len([l for l in text.splitlines() if l.startswith("claude")]), 1)

    def test_show_json_is_a_list(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: None}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            ug.main(["show", "--json"])
        self.assertEqual(sorted(r["provider"] for r in json.loads(out.getvalue())), ["antigravity/claude", "antigravity/gemini-flash", "antigravity/gemini-pro", "claude", "cursor"])


def summary(pct, ends=FUT, began=NOW - 29 * 86400, enabled=True):
    return {"billingCycleStart": ug.datetime.fromtimestamp(began, timezone.utc).isoformat(),
            "billingCycleEnd": ug.datetime.fromtimestamp(ends, timezone.utc).isoformat(),
            "individualUsage": {"plan": {"enabled": enabled, "totalPercentUsed": pct}}}


class Cursor(unittest.TestCase):
    """Only the Auto + Composer pool establishes Composer headroom."""

    def test_auto_composer_pool_controls_verdict_and_show(self):
        for pct, expected in [(0, 0), (42.5, 0), (95, 0), (100, 3)]:  # Cursor included ceiling is 100
            with self.subTest(pct=pct), tempfile.TemporaryDirectory() as t, \
                    mock.patch.object(ug, "STATE", t), \
                    mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.object(ug, "live_workers", return_value=rows(0)):
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
                    self.assertIn("cursor included", ug.table([row]))

    def check(self, pct, baseline=None, ends=NOW + 10 * 86400, running=0, cap=None):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(running)):
            if pct is not None:
                path = t + "/summary.json"
                json.dump(summary(pct, ends), open(path, "w"))
                os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
                ug.CURSOR_SUMMARY = path
            else:
                ug.CURSOR_SUMMARY = NO_CURSOR
            if baseline is not None:
                json.dump({"v": ug.STATE_VERSION, "date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"), "baseline": baseline,
                           "resets_at": ends}, open(t + "/cursor.json", "w"))
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    status = ug.main(["check", "--provider", "cursor", *(["--cap", str(cap)] if cap else [])])
            finally:
                ug.CURSOR_SUMMARY = NO_CURSOR
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)
            return status, json.loads(out.getvalue())

    def test_grok_reviewer_uses_the_shared_cursor_pool(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)):
            path = t + "/summary.json"
            payload = summary(100)
            payload["individualUsage"]["plan"].update(autoPercentUsed=10)
            json.dump(payload, open(path, "w"))
            os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
            ug.CURSOR_SUMMARY = path
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(ug.main(["check", "--provider", "cursor", "--model", "grok-4.7-high"]), 0)
                self.assertEqual(json.loads(out.getvalue())["weekly_used"], 10)
            finally:
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)
                ug.CURSOR_SUMMARY = None

    def test_grok_is_its_own_family(self):
        self.assertEqual(ug.family({"provider": "cursor", "model": "grok-4.7-high"}), "grok")

    def test_recorded_period_usage_counts_a_non_composer_model(self):
        """GetCurrentPeriodUsage lists grok-4.7-xhigh in autoBucketModels.

        usage-summary's autoPercentUsed was 0 at the same time. The reading uses the
        period percent that covers the listed model, never that zero.
        """
        # Recorded GetCurrentPeriodUsage body. autoBucketModels includes grok-4.7-xhigh.
        payload = json.loads(r'''{
          "billingCycleStart": "1793972416493",
          "billingCycleEnd": "1794577216493",
          "planUsage": {"autoPercentUsed": 47.0016708954762, "totalPercentUsed": 47.0016708954762},
          "autoBucketModels": ["default", "composer-1.5", "composer-2", "composer-2-fast", "composer-2.5",
            "composer-2.5-fast", "vega", "vega-medium", "vega-high", "vega-xhigh", "vega-fast-medium",
            "vega-fast-high", "vega-fast-xhigh", "grok-4.5", "cursor-grok-4.5", "cursor-grok-4.5-low",
            "cursor-grok-4.5-low-fast", "cursor-grok-4.5-medium", "cursor-grok-4.5-medium-fast",
            "cursor-grok-4.5-high", "cursor-grok-4.5-high-fast", "grok-4.5-medium", "grok-4.5-fast-medium",
            "grok-4.5-high", "grok-4.5-fast-high", "grok-4.5-xhigh", "grok-4.5-fast-xhigh", "grok-4.6",
            "cursor-grok-4.6", "cursor-grok-4.6-low", "cursor-grok-4.6-low-fast", "cursor-grok-4.6-medium",
            "cursor-grok-4.6-medium-fast", "cursor-grok-4.6-high", "cursor-grok-4.6-high-fast",
            "cursor-grok-4.6-xhigh", "cursor-grok-4.6-xhigh-fast", "grok-4.7", "grok-4.7-fast", "grok-4.7-low",
            "grok-4.7-low-fast", "grok-4.7-medium", "grok-4.7-medium-fast", "grok-4.7-high",
            "grok-4.7-high-fast", "grok-4.7-xhigh", "grok-4.7-xhigh-fast", "composer-1"]
        }''')
        self.assertIn("grok-4.7-xhigh", payload["autoBucketModels"])
        self.assertFalse(any(model.startswith("composer") for model in ("grok-4.7-xhigh",)))
        payload["individualUsage"] = {"plan": {
            "enabled": True, "autoPercentUsed": 0, "apiPercentUsed": 0, "totalPercentUsed": 0}}
        reading = ug.cursor_parse(payload, NOW)
        counted = payload["planUsage"]["autoPercentUsed"]
        self.assertEqual(reading["pct"], counted)
        self.assertIn("grok-4.7-xhigh", reading["models"])
        self.assertEqual(reading["resets_at"], float(payload["billingCycleEnd"]) / 1000)
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)):
            path = t + "/summary.json"
            json.dump(payload, open(path, "w"))
            os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
            ug.CURSOR_SUMMARY = path
            try:
                for model in ("grok-4.7-xhigh", "grok-4.7-high", "grok-4.7-xhigh-fast"):
                    with contextlib.redirect_stdout(io.StringIO()) as out:
                        self.assertEqual(ug.main(["check", "--provider", "cursor", "--model", model]), 0)
                    self.assertEqual(json.loads(out.getvalue())["weekly_used"], counted)
            finally:
                ug.CURSOR_SUMMARY = NO_CURSOR
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)

    def test_worker_model_absent_from_the_measured_bucket_is_refused(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)):
            payload = summary(10)
            payload["individualUsage"]["plan"].update(autoPercentUsed=10, apiPercentUsed=0)
            payload["planUsage"] = {"autoPercentUsed": 10, "totalPercentUsed": 10}
            payload["autoBucketModels"] = ["composer-2.5", "composer-2.5-fast"]
            path = t + "/summary.json"
            json.dump(payload, open(path, "w"))
            os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
            ug.CURSOR_SUMMARY = path
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    status = ug.main(["check", "--provider", "cursor", "--model", "grok-4.7-xhigh"])
                    row = json.loads(out.getvalue())
                self.assertNotEqual((status, row["verdict"]), (0, "allowed"))
                self.assertNotIn("weekly_used", row)
                self.assertIn("does not measure", row["reason"])
            finally:
                ug.CURSOR_SUMMARY = NO_CURSOR
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)

    def test_non_composer_model_never_allowed_from_auto_composer_pool(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)):
            path = t + "/summary.json"
            payload = summary(100)
            payload["individualUsage"]["plan"].update(autoPercentUsed=10, apiPercentUsed=100)
            json.dump(payload, open(path, "w"))
            os.environ["USAGE_GATE_CURSOR_SUMMARY"] = path
            ug.CURSOR_SUMMARY = path
            try:
                for args in (["check", "--provider", "cursor"],
                             ["check", "--provider", "cursor", "--model", "grok-4.7-xhigh"]):
                    with contextlib.redirect_stdout(io.StringIO()) as out:
                        self.assertEqual(ug.main(args), 0)
                        row = json.loads(out.getvalue())
                        self.assertEqual(row["verdict"], "allowed")
                        self.assertEqual(row["weekly_used"], 10)
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    status = ug.main(["check", "--provider", "cursor", "--model", "gpt-5.6-sol-high"])
                    row = json.loads(out.getvalue())
                self.assertNotEqual((status, row["verdict"]), (0, "allowed"))
                self.assertNotIn("weekly_used", row)
                self.assertIn("read the Cursor dashboard", row["reason"])
            finally:
                ug.CURSOR_SUMMARY = NO_CURSOR
                os.environ.pop("USAGE_GATE_CURSOR_SUMMARY", None)

    def test_composer_allowance_cannot_be_inferred_from_aggregate_plan_usage(self):
        status, row = self.check(100, baseline=100)
        self.assertEqual((status, row["verdict"]), (4, "unknown"))
        self.assertIn("included-usage", row["reason"])
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
                    self.assertEqual(reading["pct"], 23.5)
                    self.assertEqual(reading["resets_at"], FUT)
                    request = fetch.call_args.args[0]
                    self.assertEqual(request.full_url, ug.CURSOR_PERIOD_URL)
                    self.assertEqual(request.get_header("Authorization"), "Bearer " + token)
                    self.assertEqual(request.data, b"{}")
                    self.assertIsNone(request.get_header("Cookie"))
                if source == "keychain":
                    self.assertEqual(command.call_args.args[0], ["security", "find-generic-password",
                                     "-a", "cursor-user", "-s", "cursor-access-token", "-w"])
                self.assertNotIn(token, output.getvalue() + errors.getvalue())
                for call in command.call_args_list:
                    self.assertNotIn(token, str(call))

    def test_rejected_desktop_token_falls_through_to_cli_store(self):
        import base64, sqlite3, urllib.error, urllib.request
        def jwt(user):
            return "synthetic." + base64.urlsafe_b64encode(
                ('{"sub":"auth|%s"}' % user).encode()).decode().rstrip("=") + ".signature"
        stale, live = jwt("stale-user"), jwt("live-user")
        payload = summary(100)
        payload["individualUsage"]["plan"]["autoPercentUsed"] = 7.5
        def respond(request, timeout):
            if request.get_header("Authorization") == "Bearer " + stale:
                raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized", {}, None)
            body = mock.MagicMock()
            body.__enter__.return_value = io.StringIO(json.dumps(payload))
            return body
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "HOME", t), \
                mock.patch.object(ug, "CURSOR_SUMMARY", None), mock.patch.object(ug.sys, "platform", "linux"), \
                mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(urllib.request, "urlopen", side_effect=respond) as fetch:
            db = t + "/.config/Cursor/User/globalStorage/state.vscdb"
            os.makedirs(os.path.dirname(db))
            with sqlite3.connect(db) as con:
                con.execute("create table ItemTable (key text, value text)")
                con.execute("insert into ItemTable values (?, ?)", ("cursorAuth/accessToken", stale))
            os.makedirs(t + "/.config/cursor", exist_ok=True)
            with open(t + "/.config/cursor/auth.json", "w") as f:
                json.dump({"accessToken": live}, f)
            reading = ug.cursor_reading()
            self.assertEqual(reading["pct"], 7.5)
            self.assertEqual(reading["resets_at"], FUT)
            self.assertEqual(reading["source"], ug.CURSOR_PERIOD_URL)
            self.assertEqual(fetch.call_count, 2)
            self.assertTrue(all(call.args[0].full_url == ug.CURSOR_PERIOD_URL for call in fetch.call_args_list))


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
                mock.patch.object(ug, "live_workers", lambda p: []), \
                mock.patch.object(ug, "start_of_day", lambda r, p, m: {"pct": 35.0, "resets_at": resets}), \
                mock.patch.object(ug.time, "time", lambda: NOW):
            self.assertEqual(ug.run("claude", None, 95)["cap"], 15.0)
            os.remove(t + "/claude.json")
            self.assertEqual(ug.run("claude", 12, 95)["cap"], 12)


class IdleReading(unittest.TestCase):
    def test_idle_reading_still_blocks_with_running_reserve_and_expired_week_stays_unknown(self):
        old = ug.local_midnight(NOW) - 10
        reading = {"pct": 94.0, "resets_at": FUT, "observed_at": old}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading}), \
                mock.patch.object(ug, "live_workers", return_value=rows(1)):
            self.assertEqual(ug.run("claude", 12, 95, now=NOW)["verdict"], "unknown")
            reading["resets_at"] = NOW - 1
            self.assertEqual(ug.run("claude", 12, 95, now=NOW)["verdict"], "unknown")



class Pick(unittest.TestCase):
    def invoke(self, chain=None, role="dev", claude=44, other=41, extra=(), pin=False,
               running=0, default=False, cap=12, other_baseline=40):
        readings = {}   # "other" stands in for a second gated provider with a readable weekly percent
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"other": lambda: readings.get("other")}), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(running)), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()) as err:
            chain = chain or [{"provider": "claude", "model": "sonnet", "effort": "medium"},
                              {"provider": "other", "model": "gpt-test", "effort": "low"},
                              {"provider": "cursor", "model": "claude-test"},
                              {"provider": "antigravity", "model": "gemini-test"}]
            presets = {"default_chain": ["other", "claude", "cursor", "antigravity"],
                       "roles": {"fullstack-dev" if default else role:
                                 {"chain": chain, "tier": "workhorse", "pin": pin}}}
            with open(t + "/presets.json", "w") as f:
                json.dump(presets, f)
            for provider, pct in (("claude", claude), ("other", other)):
                if pct is None:
                    continue
                with open(t + "/" + provider + ".json", "w") as f:
                    json.dump({"v": ug.STATE_VERSION, "date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"),
                               "baseline": other_baseline if provider == "other" else 40, "resets_at": FUT}, f)
                if provider == "claude":
                    with open(t + "/claude-rate-limits.json", "w") as f:
                        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT},
                                   "_written_at": NOW}, f)
                else:
                    readings["other"] = {"pct": pct, "resets_at": FUT, "observed_at": NOW}
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/presets.json"}):
                status = ug.main(["pick", "--role", role, *(["--cap", str(cap)] if cap is not None else []), *extra])
            return status, out.getvalue(), err.getvalue()

    def test_picks_largest_fraction_and_prints_flags_and_reasons(self):
        status, out, err = self.invoke()
        self.assertEqual((status, out.strip()), (0, "--agent other --model gpt-test --effort low"))
        for provider in ("claude", "other", "cursor", "antigravity"):
            self.assertIn(provider, err)

    def test_ranks_by_fraction_of_auto_cap_rather_than_absolute_room(self):
        status, out, _ = self.invoke(claude=44, other=81, other_baseline=80, cap=None, extra=("--json",))
        result = json.loads(out)
        claude, other = result["candidates"][:2]
        self.assertGreater(claude["headroom"], other["headroom"])
        self.assertEqual((status, result["selected"]["provider"]), (0, "claude"))

    def test_near_tie_keeps_the_preset_provider_whichever_reads_higher(self):
        # Readings 1 point apart in either direction must not flip the pick (issue 107).
        for claude, other in ((44, 44), (45, 44), (44, 45), (46, 44)):
            with self.subTest(claude=claude, other=other):
                self.assertIn("--agent claude", self.invoke(claude=claude, other=other, cap=None)[1])

    def test_clearly_lower_preset_switches_and_blocked_preset_switches(self):
        self.assertIn("--agent other", self.invoke(claude=60, other=44, cap=None)[1])
        self.assertIn("--agent other", self.invoke(claude=95, other=44, cap=None)[1])

    def test_ties_keep_chain_order_and_reserve_can_block_all_gated_providers(self):
        self.assertIn("--agent claude", self.invoke(other=44)[1])
        self.assertIn("--agent antigravity", self.invoke(claude=94, other=94, running=1)[1])   # no reading is allowed

    def test_pinned_roles_keep_first_allowed_entry(self):
        for role, pin in (("elon", False), ("release-manager", False), ("custom", True)):
            with self.subTest(role):
                self.assertIn("--agent claude", self.invoke(role=role, pin=pin)[1])
                self.assertIn("--agent other", self.invoke(role=role, pin=pin, claude=95)[1])

    def test_review_excludes_family_even_for_pinned_roles(self):
        self.assertIn("--agent claude", self.invoke(extra=("--avoid-family", "gpt"))[1])
        self.assertIn("--agent other", self.invoke(role="elon", extra=("--avoid-family", "claude"))[1])
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
        self.assertIn("--agent other", self.invoke(claude=95)[1])
        self.assertIn("--agent antigravity", self.invoke(claude=95, other=95)[1])   # no reading is allowed
        self.assertIn("--agent antigravity", self.invoke(claude=None, other=95)[1])
        self.assertIn("--agent antigravity", self.invoke(extra=("--avoid-family", "gpt"), claude=None)[1])

    def test_unknown_role_uses_default_chain_and_models_from_file(self):
        status, out, _ = self.invoke(role="unlisted", default=True, claude=41)
        self.assertEqual((status, out.strip()), (0, "--agent other --model gpt-test --effort low"))

    def test_json_includes_selection_headroom_and_every_candidate(self):
        status, out, _ = self.invoke(extra=("--json",), running=2)
        result = json.loads(out)
        self.assertEqual((status, result["selected"]["provider"], result["selected"]["headroom"]),
                         (0, "other", 52))
        self.assertEqual(len(result["candidates"]), 4)

    def test_no_allowed_entry_reports_earliest_reset_and_exit_three_in_json(self):
        chain = [{"provider": "claude", "model": "opus"}, {"provider": "other", "model": "gpt-test"}]
        status, out, _ = self.invoke(chain=chain, claude=96, other=95, extra=("--json",))
        result = json.loads(out)
        self.assertEqual((status, result["selected"], result["blocked_until"]),
                         (3, None, FUT))

    def test_reviewer_avoid_claude_picks_other_when_allowed(self):
        status, out, _ = self.invoke(role="reviewer", chain=REVIEWER_CHAIN, claude=95, other=44,
                                     extra=("--avoid-family", "claude"))
        self.assertEqual((status, out.strip()), (0, "--agent other --model gpt-6.1-sol --effort medium"))

    def test_reviewer_avoid_claude_picks_antigravity_flash_when_other_blocked(self):
        pools = {"gemini-flash": {"pct": 5, "resets_at": FUT, "observed_at": NOW}}
        with tempfile.TemporaryDirectory() as t, \
                mock.patch.dict(ug.READERS, {"antigravity": lambda: pools, "other": lambda: {"pct": 96, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            presets = {"default_chain": ["other", "cursor", "antigravity"],
                       "roles": {"reviewer": {"chain": REVIEWER_CHAIN, "tier": "workhorse"}}}
            with open(t + "/presets.json", "w") as f:
                json.dump(presets, f)
            for provider, pct in (("claude", 95), ("other", 96)):
                with open(t + "/" + provider + ".json", "w") as f:
                    json.dump({"v": ug.STATE_VERSION, "date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d"),
                               "baseline": 40, "resets_at": FUT}, f)
                if provider == "claude":
                    with open(t + "/claude-rate-limits.json", "w") as f:
                        json.dump({"seven_day": {"used_percentage": pct, "resets_at": FUT},
                                   "_written_at": NOW}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/presets.json"}):
                with mock.patch.object(ug, "STATE", t):
                    status = ug.main(["pick", "--role", "reviewer", "--avoid-family", "claude"])
        self.assertEqual(status, 0)
        self.assertIn("--agent antigravity --model gemini-3.8-flash", out.getvalue().strip())

    def test_reviewer_avoid_claude_nothing_when_all_cross_family_blocked(self):
        status, out, err = self.invoke(role="reviewer", chain=REVIEWER_CHAIN, claude=95, other=96,
                                       extra=("--avoid-family", "claude"))
        self.assertEqual((status, out), (0, "--agent antigravity --model gemini-3.8-flash\n"))  # no reading is allowed

    def test_reviewer_preset_chain_models(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
        with open(path) as f:
            chain = json.load(f)["roles"]["reviewer"]["chain"]
        self.assertEqual([(e["provider"], e["model"]) for e in chain],
                         [("antigravity", "gemini-4-argon-high"), ("claude", "sonnet"),
                          ("cursor", "grok-4.7-high")])
        self.assertEqual({ug.family(e) for e in chain}, {"gemini", "claude", "grok"})

    def test_claude_authored_pr_reviewer_pick_offers_cursor_grok(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
        def fake_run(provider, *a, **k):
            verdict = "allowed" if provider == "cursor" else "blocked"
            return {"provider": provider, "verdict": verdict, "ceiling": 95, "weekly_used": 10}
        with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}), \
                mock.patch.object(ug, "run", side_effect=fake_run), \
                mock.patch.object(ug, "antigravity_models", return_value=None):
            result = ug.pick("reviewer", "claude", None, 95, 1, avoid_provider="claude")
        self.assertEqual((result["selected"]["provider"], result["selected"]["model"]),
                         ("cursor", "grok-4.7-high"))
        self.assertTrue(all(ug.family(c) != "claude" for c in [result["selected"]]))

    def test_grok_authored_pr_reviewer_pick_is_claude(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
        def fake_run(provider, *a, **k):
            return {"provider": provider, "verdict": "allowed", "ceiling": 95, "weekly_used": 10}
        with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}), \
                mock.patch.object(ug, "run", side_effect=fake_run), \
                mock.patch.object(ug, "antigravity_models", return_value=None):
            result = ug.pick("reviewer", "grok", None, 95, 1)
        self.assertEqual(ug.family(result["selected"]), "claude")

    def test_cursor_composer_is_its_own_family(self):
        self.assertEqual(ug.family({"provider": "cursor", "model": "composer-2.5"}), "composer")

    def test_no_preset_lists_an_unapproved_cursor_model(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
        with open(path) as f:
            roles = json.load(f)["roles"]
        bad = [(r, e["model"]) for r, v in roles.items() for e in v.get("chain", [])
               if e["provider"] == "cursor" and e["model"] not in ug.CURSOR_MODELS]
        self.assertEqual(bad, [])


class CursorComposerOnly(unittest.TestCase):
    """Owner 2026-11-09: Cursor builds only on grok-4.7-xhigh, so pick never selects an unapproved Cursor model."""
    CHAIN = [{"provider": "cursor", "model": "gpt-5.6-sol-high"},
             {"provider": "cursor", "model": "claude-sonnet-5-5-medium"},
             {"provider": "cursor", "model": "grok-4.7-xhigh"}]

    def test_pick_skips_other_cursor_models(self):
        def row(provider, *_, **__):
            return {"verdict": "allowed", "ceiling": 95, "weekly_used": 10}
        with mock.patch.object(ug, "role_chain", return_value=(self.CHAIN, False)), \
                mock.patch.object(ug, "run", side_effect=row), \
                mock.patch.object(ug, "antigravity_models", return_value=None):
            sel = ug.pick("fullstack-dev", None, None, 95, 0)["selected"]
        self.assertEqual(sel["model"], "grok-4.7-xhigh")


class PickOrder(unittest.TestCase):
    def test_show_orders_by_fraction_with_unknown_providers_last(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 31.0, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            ug.main(["show"])
        self.assertEqual(out.getvalue().splitlines()[-1],
                         "pick order now: claude 64.0 pts/day, cursor no reliable Cursor included-usage reading; read the Cursor dashboard, antigravity/claude GetUserStatus returned no fresh valid pool quota, antigravity/gemini-flash GetUserStatus returned no fresh valid pool quota, antigravity/gemini-pro GetUserStatus returned no fresh valid pool quota")

    def test_show_handles_a_stale_weekly_ceiling_without_daily_numbers(self):
        reading = {"pct": 96, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading}), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show"]), 0)
        self.assertIn("unknown", out.getvalue())
        self.assertNotIn("blocked", out.getvalue())


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
            self.assertEqual(gate.main(["check", "--provider", "cursor", "--model", "grok-4.7-xhigh"]), 4)
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
        with mock.patch.dict(gate.READERS, {"claude": lambda: old}), \
                mock.patch.object(gate, "refresh_reading", return_value=new) as refresh, \
                mock.patch.object(gate, "live_workers", return_value=rows(0)):
            result = gate.run("claude", 1, 95, now=NOW)
        refresh.assert_called_once_with("claude")
        self.assertEqual((result["verdict"], result["weekly_used"]), ("allowed", 3))
        self.assertEqual(result["source"], "https://api.anthropic.com/api/oauth/usage seven_day")

    def test_failed_refresh_is_unknown_with_exact_source_age_and_no_invented_number(self):
        gate = self.gate
        old = {"pct": 99, "resets_at": FUT, "observed_at": NOW - 1200}
        with mock.patch.dict(gate.READERS, {"claude": lambda: old}), \
                mock.patch.object(gate, "refresh_reading", side_effect=TimeoutError("secret response")):
            result = gate.run("claude", None, 95, now=NOW)
        self.assertEqual(result["verdict"], "unknown")
        self.assertEqual(result["reading_age_min"], 20)
        self.assertIn("api.anthropic.com/api/oauth/usage", result["source"])
        self.assertIn("TimeoutError", result["reason"])
        self.assertNotIn("weekly_used", result)
        self.assertNotIn("secret", json.dumps(result))

    def test_missing_reading_refresh_can_block_only_on_real_week_plus_full_reserve(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"claude": lambda: None}), \
                mock.patch.object(gate, "refresh_reading", return_value={"pct": 93, "resets_at": FUT, "observed_at": NOW}), \
                mock.patch.object(gate, "live_workers", return_value=rows(2)):
            result = gate.run("claude", .1, 95, now=NOW)
        self.assertEqual((result["verdict"], result["reserve"], result["reason"]), ("blocked", 2, "weekly ceiling"))

    def test_fresh_reading_does_not_refresh_and_invalid_numbers_never_decide(self):
        gate = self.gate
        for pct in (float('nan'), float('inf'), -1, 101):
            self.assertIsNone(gate.fresh({"pct": pct, "observed_at": NOW}, NOW))
        with mock.patch.dict(gate.READERS, {"claude": lambda: {"pct": 90, "observed_at": NOW, "resets_at": FUT}}), \
                mock.patch.object(gate, "refresh_reading") as refresh, \
                mock.patch.object(gate, "live_workers", return_value=rows(0)):
            result = gate.run("claude", None, 95, now=NOW)
        refresh.assert_not_called()
        self.assertEqual(result["verdict"], "allowed")
        self.assertIn("claude-rate-limits.json", result["source"])

    def test_broken_local_reader_refreshes_instead_of_crashing(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"claude": mock.Mock(side_effect=ValueError("bad local data"))}), \
                mock.patch.object(gate, "claude_refresh", return_value={"pct": 20, "observed_at": NOW}), \
                mock.patch.object(gate, "live_workers", return_value=rows(0)):
            self.assertEqual(gate.run("claude", None, 95, now=NOW)["verdict"], "allowed")

    def test_refresh_age_uses_the_clock_after_provider_response(self):
        gate = self.gate
        with mock.patch.dict(gate.READERS, {"claude": lambda: None}), \
                mock.patch.object(gate, "refresh_reading", return_value={"pct": 20, "observed_at": NOW + 10}), \
                mock.patch.object(gate.time, "time", side_effect=[NOW, NOW, NOW + 10]), \
                mock.patch.object(gate, "live_workers", return_value=rows(0)):
            result = gate.run("claude", None, 95)
        self.assertEqual((result["verdict"], result["reading_age_min"]), ("allowed", 0))

    def test_claude_refresh_prefers_keychain_when_the_file_token_expired(self):
        import subprocess, urllib.request
        gate = self.gate
        gate.HOME = self.tmp.name
        os.makedirs(self.tmp.name + '/.claude')
        with open(self.tmp.name + '/.claude/.credentials.json', 'w') as f:
            json.dump({'claudeAiOauth':{'accessToken':'expired', 'expiresAt':1000}}, f)
        keychain = mock.Mock(stdout=json.dumps({'claudeAiOauth':{'accessToken':'fresh'}}))
        body = io.StringIO(json.dumps({'seven_day':{'utilization':42, 'resets_at':FUT}}))
        with mock.patch.object(gate.sys, 'platform', 'darwin'), \
                mock.patch.object(subprocess, 'run', return_value=keychain), \
                mock.patch.object(urllib.request, 'urlopen', return_value=body) as fetch:
            gate.claude_refresh()
        self.assertEqual(fetch.call_args.args[0].get_header('Authorization'), 'Bearer fresh')

    def test_claude_refresh_renews_an_expired_token_on_a_host_without_keychain(self):
        import urllib.request
        gate = self.gate
        gate.HOME = self.tmp.name
        os.makedirs(self.tmp.name + '/.claude')
        path = self.tmp.name + '/.claude/.credentials.json'
        with open(path, 'w') as f:
            json.dump({'claudeAiOauth':{'accessToken':'expired', 'expiresAt':1000}}, f)
        def renew(args, **kwargs):
            with open(path, 'w') as f:
                json.dump({'claudeAiOauth':{'accessToken':'renewed', 'expiresAt':(time.time() + 7200) * 1000}}, f)
        body = io.StringIO(json.dumps({'seven_day':{'utilization':42, 'resets_at':FUT}}))
        with mock.patch.object(gate.sys, 'platform', 'linux'), \
                mock.patch.object(gate.subprocess, 'run', side_effect=renew) as run, \
                mock.patch.object(urllib.request, 'urlopen', return_value=body) as fetch:
            reading = gate.claude_refresh()
        self.assertEqual(run.call_args.args[0][:2], ['claude', '-p'])
        self.assertEqual(fetch.call_args.args[0].get_header('Authorization'), 'Bearer renewed')
        self.assertEqual(reading['pct'], 42)

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

    def orca_stub(self, runs, workers, run_pages=None):
        """subprocess.run stand-in. workers maps a Run id (or None for no --run) to {cursor or None: result}."""
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            cursor = args[args.index('--cursor') + 1] if '--cursor' in args else None
            if 'run-list' in args:
                result = (run_pages or {None: runs})[cursor]
            else:
                result = workers[args[args.index('--run') + 1] if '--run' in args else None][cursor]
            return mock.Mock(stdout=json.dumps({'ok': True, 'result': result}))
        return run, calls

    LIVE = {'terminalState': 'retained', 'dispatchStatus': 'dispatched',
            'projection': {'provider': {'id': 'cursor'}, 'liveness': {'verdict': 'live'}}}
    DONE = {'terminalState': 'retained', 'dispatchStatus': 'completed', 'projection': {'provider': {'id': 'cursor'}}}

    def test_running_reserve_includes_retained_live_workers_on_later_pages(self):
        gate = self.gate
        run, calls = self.orca_stub({'runs': [{'id': 'run_a'}]}, {'run_a': {
            None: {'workers': [], 'page': {'hasMore': True, 'nextCursor': 'page2'}},
            'page2': {'workers': [self.LIVE, self.DONE], 'page': {'hasMore': False}}}})
        with mock.patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertEqual(gate.running_workers('cursor'), 1)
        self.assertTrue(any('page2' in c for c in calls))

    def test_running_reserve_follows_top_level_next_cursor(self):
        gate = self.gate
        run, _ = self.orca_stub({'runs': [{'id': 'run_a'}]}, {'run_a': {
            None: {'workers': [], 'scope': {'source': 'flag'}, 'nextCursor': 'page2', 'warnings': []},
            'page2': {'workers': [self.LIVE, self.DONE], 'scope': {'source': 'flag'}, 'warnings': []}}})
        with mock.patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertEqual(gate.running_workers('cursor'), 1)

    def test_running_reserve_counts_workers_of_every_run(self):
        gate = self.gate
        run, _ = self.orca_stub(
            {'runs': [{'id': 'run_a'}], 'nextCursor': 'runs2'}, {
                None: {None: {'workers': [], 'warnings': []}},  # the caller's Run alone sees nothing
                'run_a': {None: {'workers': [self.LIVE], 'warnings': []}},
                'run_b': {None: {'workers': [self.LIVE, self.LIVE], 'warnings': []}}},
            run_pages={None: {'runs': [{'id': 'run_a'}], 'nextCursor': 'runs2'},
                       'runs2': {'runs': [{'id': 'run_b'}]}})
        with mock.patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertEqual(gate.running_workers('cursor'), 3)

    def test_running_reserve_is_unknown_on_a_partial_read(self):
        gate = self.gate
        repeat = {'workers': [self.LIVE], 'nextCursor': 'same', 'warnings': []}
        run, _ = self.orca_stub({'runs': [{'id': 'run_a'}]}, {'run_a': {None: repeat, 'same': repeat}})
        with mock.patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertIsNone(gate.running_workers('cursor'))
        run, _ = self.orca_stub({'runs': [{'id': 'run_a'}]}, {'run_a': {
            None: {'workers': [self.LIVE], 'page': {'hasMore': True}}}})
        with mock.patch.object(gate.subprocess, 'run', side_effect=run):
            self.assertIsNone(gate.running_workers('cursor'))
        run, _ = self.orca_stub({'runs': [{'id': 'run_a'}], 'nextCursor': 'runs2'}, {'run_a': {None: {'workers': []}}},
                                run_pages={None: {'runs': [{'id': 'run_a'}], 'nextCursor': 'runs2'}, 'runs2': {'runs': []}})
        run_ok = run
        def fail_second_page(args, **kwargs):
            if '--cursor' in args and 'run-list' in args:
                raise RuntimeError('run-list failed')
            return run_ok(args, **kwargs)
        with mock.patch.object(gate.subprocess, 'run', side_effect=fail_second_page):
            self.assertIsNone(gate.running_workers('cursor'))


class Publish(unittest.TestCase):
    def setUp(self):
        self.reading = {"pct": 42.0, "resets_at": FUT, "observed_at": NOW}
        self.sent = []

    def publish(self, reading, hours_left=5, scp_code=0):
        def scp(cmd, **kw):
            self.sent.append((cmd[-1], open(cmd[-2]).read()))
            return mock.Mock(returncode=scp_code)
        token = {"claudeAiOauth": {"accessToken": "secret", "expiresAt": (NOW + hours_left * 3600) * 1000}}
        self.run = mock.Mock(side_effect=scp)
        with mock.patch.object(ug, "refresh_reading", return_value=reading), \
                mock.patch.object(ug, "claude_credentials", return_value=token), \
                mock.patch.object(ug.subprocess, "run", self.run), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                contextlib.redirect_stderr(io.StringIO()):
            return ug.publish(["runner-a", "runner-b"])

    def test_sends_numbers_only_to_every_host(self):
        self.assertEqual(self.publish(self.reading), 0)
        self.assertEqual([to for to, _ in self.sent], ["runner-%s:.claude/state/usage-gate/claude-rate-limits.json" % h for h in "ab"])
        body = json.loads(self.sent[0][1])
        self.assertEqual(body, {"_written_at": NOW, "seven_day": {"used_percentage": 42.0, "resets_at": FUT}})
        self.assertNotIn("secret", self.sent[0][1])

    def test_copied_file_reads_as_fresh_on_the_runner(self):
        self.publish(self.reading)
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            f.write(self.sent[0][1]); f.flush()
            self.assertEqual(ug.fresh(ug.claude_reading(f.name), NOW + ug.MAX_AGE - 1)["pct"], 42.0)

    def test_no_fresh_reading_sends_nothing(self):
        self.assertEqual(self.publish(None), 4)
        self.assertEqual(self.sent, [])

    def test_failed_copy_is_reported(self):
        self.assertEqual(self.publish(self.reading, scp_code=1), 1)

    def test_renews_a_token_with_under_an_hour_left(self):
        self.publish(self.reading, hours_left=0.5)
        self.assertEqual(self.run.call_args_list[0].args[0][:2], ["claude", "-p"])

    def test_leaves_a_healthy_token_alone(self):
        self.publish(self.reading)
        self.assertEqual(self.run.call_args_list[0].args[0][0], "scp")

    def test_reading_stays_usable_for_15_minutes(self):
        self.assertEqual(ug.MAX_AGE, 15 * 60)


class PresetLinkTests(unittest.TestCase):
    """Owner 2026-11-06: starting a worker repairs a host whose preset copy drifted from dotfiles."""

    def setUp(self):
        t = tempfile.TemporaryDirectory()
        self.addCleanup(t.cleanup)
        self.home = t.name
        os.makedirs(self.home + "/dotfiles/.orca")
        os.makedirs(self.home + "/.orca")
        self.src = self.home + "/dotfiles/.orca/presets.json"
        self.dest = self.home + "/.orca/presets.json"
        with open(self.src, "w") as f:
            f.write("new")
        patcher = mock.patch.object(ug, "HOME", self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("USAGE_GATE_PRESETS", None)

    def test_a_stale_copy_becomes_a_link_and_is_kept_as_a_backup(self):
        with open(self.dest, "w") as f:
            f.write("old")
        ug.link_presets()
        self.assertTrue(os.path.islink(self.dest))
        self.assertEqual(open(self.dest).read(), "new")
        backups = [n for n in os.listdir(self.home + "/.orca") if ".bak-" in n]
        self.assertEqual([open(self.home + "/.orca/" + n).read() for n in backups], ["old"])

    def test_a_missing_copy_becomes_a_link(self):
        ug.link_presets()
        self.assertEqual(os.readlink(self.dest), self.src)

    def test_a_correct_link_is_left_alone(self):
        os.symlink(self.src, self.dest)
        ug.link_presets()
        self.assertEqual(os.listdir(self.home + "/.orca"), ["presets.json"])

    def test_a_worker_start_check_repairs_the_host(self):
        with mock.patch.object(ug, "READERS", {}), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            try:
                ug.main(["check", "--provider", "claude"])
            except (SystemExit, KeyError):
                pass
        self.assertEqual(os.readlink(self.dest), self.src)

    def test_a_test_preset_path_turns_it_off(self):
        os.environ["USAGE_GATE_PRESETS"] = self.home + "/other.json"
        ug.link_presets()
        self.assertFalse(os.path.lexists(self.dest))


FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
HERE = os.path.dirname(os.path.abspath(__file__))


def served(stdout_for):
    return mock.patch.object(ug.subprocess, "run", side_effect=lambda args, **kw: mock.Mock(stdout=stdout_for(args)))


class Reserve987(unittest.TestCase):
    """Owner decision 4 (#987): the running count works on today's worker-list shape; strong models hold 2."""

    def sample(self):
        with open(FIXTURES + "/orca-worker-list.json") as f:
            return f.read()

    def count(self, provider):
        def stdout(args):
            return json.dumps({"ok": True, "result": {"runs": [{"id": "run_a"}]}}) if "run-list" in args else self.sample()
        with mock.patch.object(ug, "live_workers", real_live_workers), served(stdout):
            return ug.running_workers(provider)

    def test_counts_live_workers_in_a_real_captured_worker_list(self):
        self.assertNotIn("projection", self.sample())  # today's shape has no projection field
        self.assertEqual((self.count("claude"), self.count("cursor")), (3, 0))  # exited rows do not count

    def test_strong_models_reserve_two_points_and_others_one(self):
        with tempfile.TemporaryDirectory() as t:
            for dispatch, model in (("ctx_a", "opus"), ("ctx_b", "sonnet"), ("ctx_c", "gemini-4-argon-high")):
                with open(f"{t}/{dispatch}.json", "w") as f:
                    json.dump({"dispatchId": dispatch, "agent": "claude", "model": model}, f)
            workers = [{"dispatchId": d} for d in ("ctx_a", "ctx_b", "ctx_c", "ctx_unknown")]
            with mock.patch.object(ug, "LAUNCHES", t), mock.patch.object(ug, "live_workers", return_value=workers):
                self.assertEqual(ug.running_reserve("claude"), (4, 2 + 1 + 2 + 1))
                self.assertEqual(ug.running_reserve("claude", 1.0), (4, 4.0))  # --reserve N is flat

    def test_reserve_comes_from_the_config_file(self):
        self.assertEqual(ug.load_config()["reserve_points"], {"strong": 2, "other": 1})
        self.assertEqual(ug.worker_weight({"model": "opus"}), 2.0)
        self.assertEqual(ug.worker_weight({"model": "grok-4.7-xhigh"}), 1.0)


class Ceilings987(unittest.TestCase):
    """Owner decision 3 (#987): one committed config, per provider ceilings."""

    def test_config_holds_the_owner_ceilings(self):
        self.assertEqual([ug.ceiling_for(p) for p in ("claude", "cursor", "antigravity")], [95, 100, 95])
        with open(os.path.join(HERE, "..", "usage-gate.config.json")) as f:
            self.assertEqual(json.load(f)["ceilings"], {"claude": 95, "cursor": 100, "antigravity": 95})

    def test_cursor_runs_to_100_and_never_shows_negative_headroom(self):
        row = {"verdict": "blocked", "weekly_used": 100, "ceiling": ug.ceiling_for("cursor"), "reserve": 2}
        self.assertEqual(ug.headroom(row), (0.0, 0.0))
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"cursor": lambda: {"pct": 98, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            self.assertEqual(ug.run("cursor", 99, None)["verdict"], "allowed")
            self.assertEqual(ug.run("claude", 99, None)["verdict"], "unknown")  # claude has its own ceiling, no reading

    def test_check_uses_each_providers_ceiling_and_the_flag_overrides_it(self):
        for provider, pct, ceiling_flag, expected in (("claude", 96, [], 3), ("cursor", 96, [], 0),
                                                       ("cursor", 96, ["--ceiling", "95"], 3)):
            with self.subTest(provider=provider, flag=ceiling_flag), tempfile.TemporaryDirectory() as t, \
                    mock.patch.object(ug, "STATE", t), mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.dict(ug.READERS, {provider: lambda: {"pct": pct, "resets_at": FUT, "observed_at": NOW}}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ug.main(["check", "--provider", provider, *ceiling_flag]), expected)

    def test_cursor_today_is_not_read_from_a_fake_midnight_baseline(self):
        # A state file from before the baseline rules held baseline 0 for a cycle that began days ago.
        old = {"date": "d1", "baseline": 0.0, "resets_at": FUT}
        reading = {"pct": 100.0, "resets_at": FUT, "observed_at": NOW, "began_at": NOW - 5 * 86400}
        _, detail, state = ug.decide(reading, old, "d1", NOW, None, 100)
        self.assertEqual((detail["today_used"], state["baseline"]), (0.0, 100.0))
        # A reset that moved mid day for a cycle that began before today is no zero baseline either.
        moved = {"v": ug.STATE_VERSION, "date": "d1", "baseline": 50.0, "resets_at": FUT + 7200}
        _, detail, _ = ug.decide({**reading, "pct": 60.0}, moved, "d1", NOW, None, 100)
        self.assertEqual(detail["today_used"], 0.0)
        # A cycle that began today does start from zero.
        fresh_cycle = {**reading, "pct": 3.0, "began_at": ug.local_midnight(NOW) + 60}
        _, detail, _ = ug.decide(fresh_cycle, moved, "d1", NOW, None, 100)
        self.assertEqual(detail["today_used"], 3.0)


class MissingReading987(unittest.TestCase):
    """Owner decision 1 (#987): last good reading under 2 hours old and 10 points under the ceiling, else block."""

    def check(self, last_pct, age_min, ceiling_flag=()):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: None}), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            with open(t + "/claude.last-good.json", "w") as f:
                json.dump({"pct": last_pct, "resets_at": FUT, "observed_at": NOW - age_min * 60}, f)
            return ug.run("claude", None, None)

    def test_recent_reading_with_room_is_used_and_noted(self):
        row = self.check(60, 119)
        self.assertEqual((row["verdict"], row["weekly_used"], row["carried"]), ("allowed", 60, True))
        self.assertIn("last good", row["note"])
        self.assertEqual(row["reading_age_min"], 119)

    def test_old_reading_blocks(self):
        row = self.check(60, 121)
        self.assertEqual(row["verdict"], "unknown")
        self.assertIn("last good reading 121m old", row["reason"])
        self.assertEqual(row["headroom"], 35)  # fleet-watch weighs this against its notice threshold

    def test_reading_within_10_points_of_the_ceiling_blocks(self):
        self.assertEqual(self.check(86, 5)["verdict"], "unknown")
        self.assertEqual(self.check(85, 5)["verdict"], "allowed")

    def test_a_fresh_reading_is_remembered_for_the_next_outage(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 42, "resets_at": FUT, "observed_at": NOW}}), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            ug.run("claude", None, None)
            self.assertEqual(json.load(open(t + "/claude.last-good.json"))["pct"], 42)


class DailyCap987(unittest.TestCase):
    """Owner decision 2 (#987): the daily cap blocks automatic starts only."""
    ST = {"v": ug.STATE_VERSION, "date": "d1", "baseline": 40, "resets_at": FUT}

    def test_automatic_start_past_the_cap_is_blocked_until_midnight(self):
        verdict, detail, _ = ug.decide(D(52), self.ST, "d1", NOW, 12, 95, auto=True)
        self.assertEqual((verdict, detail["reason"]), ("blocked", "daily cap"))
        self.assertEqual(ug.blocked_until(detail, NOW), ug.next_midnight(NOW))

    def test_manual_start_past_the_cap_only_gets_a_note(self):
        verdict, detail, _ = ug.decide(D(52), self.ST, "d1", NOW, 12, 95)
        self.assertEqual((verdict, detail["note"]), ("allowed", "pacing: prefer a lighter model"))

    def test_automatic_start_under_the_cap_is_allowed(self):
        self.assertEqual(ug.decide(D(51), self.ST, "d1", NOW, 12, 95, auto=True)[0], "allowed")

    def test_the_auto_flag_reaches_check_and_pick(self):
        def go(*argv):
            with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                    mock.patch.object(ug.time, "time", return_value=NOW), \
                    mock.patch.dict(ug.READERS, {"claude": lambda: {"pct": 52, "resets_at": FUT, "observed_at": NOW}}), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                with open(t + "/claude.json", "w") as f:
                    json.dump({**self.ST, "date": ug.datetime.fromtimestamp(NOW).strftime("%Y-%m-%d")}, f)
                return ug.main(list(argv)), out.getvalue()
        self.assertEqual(go("check", "--provider", "claude", "--cap", "12")[0], 0)
        status, out = go("check", "--provider", "claude", "--cap", "12", "--auto")
        self.assertEqual((status, json.loads(out)["reason"]), (3, "daily cap"))

    def test_pick_marks_an_automatic_start(self):
        seen = []
        def row(provider, cap, ceiling, **kw):
            seen.append(kw["auto"])
            return {"verdict": "blocked", "reason": "daily cap", "ceiling": 95, "weekly_used": 52}
        with mock.patch.object(ug, "role_chain", return_value=([{"provider": "claude", "model": "opus"}], False)), \
                mock.patch.object(ug, "is_builder_role", return_value=False), mock.patch.object(ug, "run", side_effect=row):
            result = ug.pick("architect-pm", None, None, None, None, None, True)
        self.assertEqual((seen, result["selected"], result["candidates"][0]["reason"]), ([True], None, "daily cap"))


class Pace987(unittest.TestCase):
    """Owner decision 6 (#987): non builder roles rank by headroom per day left; builders keep the fixed order."""
    CHAIN = [{"provider": "claude", "model": "sonnet"}, {"provider": "cursor", "model": "grok-4.7-high"}]

    def rows(self, provider, cap, ceiling, **kw):
        # claude: 40 points for 5 days (8/day). cursor: 20 points resetting in half a day (40/day).
        pct, resets = (55, NOW + 5 * 86400) if provider == "claude" else (80, NOW + 43200)
        return {"verdict": "allowed", "ceiling": 95 if provider == "claude" else 100,
                "weekly_used": pct, "resets_at": resets}

    def pick(self, role, builder):
        with mock.patch.object(ug, "role_chain", return_value=(self.CHAIN, False)), \
                mock.patch.object(ug, "is_builder_role", return_value=builder), \
                mock.patch.object(ug, "run", side_effect=self.rows), \
                mock.patch.object(ug, "antigravity_models", return_value=None), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            return ug.pick(role, None, None, None, None)["selected"]["provider"]

    def test_quota_about_to_reset_is_spent_first(self):
        self.assertEqual(self.pick("qa-sdet-like", False), "cursor")

    def test_builder_roles_keep_the_fixed_order_cursor_first(self):
        self.assertEqual(self.pick("fullstack-dev", True), "cursor")
        with mock.patch.object(ug, "run", side_effect=lambda provider, *a, **k: {
                "verdict": "allowed", "ceiling": 95, "weekly_used": 95 - (90 if provider == "claude" else 1),
                "resets_at": NOW + (86400 if provider == "claude" else 5 * 86400)}), \
                mock.patch.object(ug, "role_chain", return_value=(self.CHAIN, False)), \
                mock.patch.object(ug, "is_builder_role", return_value=True), \
                mock.patch.object(ug, "antigravity_models", return_value=None):
            # claude is far ahead on pace, but a builder still takes Cursor first
            self.assertEqual(ug.pick("fullstack-dev", None, None, None, None)["selected"]["provider"], "cursor")

    def test_pace_is_headroom_per_day_with_a_floor_on_days_left(self):
        row = {"verdict": "allowed", "ceiling": 95, "weekly_used": 55, "resets_at": NOW + 2 * 86400}
        self.assertEqual(ug.pace(row, NOW), 20.0)
        soon = {**row, "resets_at": NOW + 60}
        self.assertEqual(ug.pace(soon, NOW), 40 / ug.MIN_DAYS)
        self.assertIsNone(ug.pace({"verdict": "allowed", "blind": True}, NOW))


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

    def test_banner_blocks_the_pool_until_reset_and_other_pools_start_blind(self):
        with tempfile.TemporaryDirectory() as t:
            path = t + "/banner.json"
            self.assertEqual(ug.record_quota_banner(self.TEXT, NOW, path), "claude")
            with mock.patch.object(ug, "BANNER_FILE", path), \
                    mock.patch.object(ug, "antigravity_pools", return_value=None), \
                    mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                    mock.patch.object(ug.time, "time", return_value=NOW + 60):
                pools = ug.antigravity_reading()
                self.assertEqual(set(pools), {"claude"})
                row = ug.antigravity_result(pools, 95, NOW + 60, model="claude-sonnet-5-5-high")
                self.assertEqual((row["verdict"], row["blocked_until"]), ("blocked", NOW + 94 * 3600 + 29 * 60))
                self.assertEqual(ug.antigravity_result(pools, 95, NOW + 60, model="gemini-4-argon-low")["verdict"],
                                 "allowed")  # no reading for that pool: allowed, as in check
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
                mock.patch.object(ug, "live_workers", return_value=rows(0)), \
                mock.patch.object(ug.time, "time", return_value=NOW):
            with open(t + "/p.json", "w") as f:
                json.dump({"roles": {"dev": {"chain": chain}}}, f)
            with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": t + "/p.json"}):
                result = ug.pick("dev", None, None, 95, 1)
        self.assertIsNone(result["selected"])
        self.assertEqual(result["candidates"][0]["verdict"], "model not recognized")


class ProjectPresetsMergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base_presets_path = os.path.join(self.tmp.name, "presets.json")
        with open(self.base_presets_path, "w") as f:
            json.dump({
                "default_chain": ["claude", "cursor", "antigravity"],
                "roles": {
                    "elon": {
                        "tier": "strong",
                        "chain": [
                            {"provider": "antigravity", "model": "gemini-4-argon-medium"},
                            {"provider": "claude", "model": "opus", "effort": "medium"},
                        ],
                    },
                    "fullstack-dev": {
                        "tier": "workhorse",
                        "chain": [
                            {"provider": "claude", "model": "sonnet", "effort": "medium"},
                            {"provider": "cursor", "model": "grok-4.7-xhigh"},
                        ],
                        "pin": True,
                    },
                },
            }, f)

    def test_role_chain_and_pick_merge_project_presets_via_env_and_git_root(self):
        repo_dir = os.path.join(self.tmp.name, "project-a")
        subdir = os.path.join(repo_dir, "src", "nested")
        os.makedirs(subdir)
        os.makedirs(os.path.join(repo_dir, ".git"))
        os.makedirs(os.path.join(repo_dir, ".orca"))
        proj_presets_path = os.path.join(repo_dir, ".orca", "presets.project.json")
        with open(proj_presets_path, "w") as f:
            json.dump({
                "roles": {
                    "elon": {
                        "chain": [
                            {"provider": "claude", "model": "claude-opus-5-5", "effort": "high"},
                        ],
                        "pin": True,
                    },
                },
            }, f)

        # 1. Via USAGE_GATE_PROJECT_PRESETS env var
        with mock.patch.dict(os.environ, {
            "USAGE_GATE_PRESETS": self.base_presets_path,
            "USAGE_GATE_PROJECT_PRESETS": proj_presets_path,
        }):
            chain, pinned = ug.role_chain("elon")
            self.assertTrue(pinned)
            self.assertEqual(chain, [{"provider": "claude", "model": "claude-opus-5-5", "effort": "high"}])

        # 2. Via git repo root discovery from a nested directory
        old_cwd = os.getcwd()
        try:
            os.chdir(subdir)
            env = {"USAGE_GATE_PRESETS": self.base_presets_path}
            with mock.patch.dict(os.environ, env):
                os.environ.pop("USAGE_GATE_PROJECT_PRESETS", None)
                with mock.patch.object(ug, "run", side_effect=lambda p, *a, **k: {
                    "provider": p, "verdict": "allowed", "ceiling": 95, "weekly_used": 20,
                }), contextlib.redirect_stdout(io.StringIO()) as out, \
                        contextlib.redirect_stderr(io.StringIO()):
                    rc = ug.main(["pick", "--role", "elon"])
                self.assertEqual(rc, 0)
                self.assertEqual(out.getvalue().strip(), "--agent claude --model claude-opus-5-5 --effort high")
        finally:
            os.chdir(old_cwd)

    def test_non_canonical_project_role_in_pick_and_usage_gate_hook(self):
        import subprocess
        repo_dir = os.path.join(self.tmp.name, "project-b")
        os.makedirs(os.path.join(repo_dir, ".git"))
        os.makedirs(os.path.join(repo_dir, ".orca"))
        proj_presets_path = os.path.join(repo_dir, ".orca", "presets.project.json")
        with open(proj_presets_path, "w") as f:
            json.dump({
                "roles": {
                    "stream-health": {
                        "tier": "workhorse",
                        "chain": [
                            {"provider": "claude", "model": "sonnet", "effort": "medium"},
                            {"provider": "cursor", "model": "grok-4.7-xhigh"},
                        ],
                    },
                },
            }, f)

        with mock.patch.dict(os.environ, {
            "USAGE_GATE_PRESETS": self.base_presets_path,
            "USAGE_GATE_PROJECT_PRESETS": proj_presets_path,
        }), mock.patch.object(ug, "run", side_effect=lambda p, *a, **k: {
            "provider": p, "verdict": "allowed", "ceiling": 95, "weekly_used": 10 if p == "claude" else 80,
        }), contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            rc = ug.main(["pick", "--role", "stream-health"])
            self.assertEqual(rc, 0)
            self.assertEqual(out.getvalue().strip(), "--agent claude --model sonnet --effort medium")

        # Verify usage-gate-hook.py recognizes stream-health via git repo root discovery
        state_dir = os.path.join(self.tmp.name, "state")
        os.makedirs(state_dir)
        now = ug.time.time() if hasattr(ug.time.time, "__call__") else 1_000_000_000.0
        import time as real_time
        now = real_time.time()
        fut = now + 3 * 86400
        with open(os.path.join(state_dir, "claude-rate-limits.json"), "w") as f:
            json.dump({"seven_day": {"used_percentage": 20.0, "resets_at": fut}, "_written_at": now}, f)
        summary_path = os.path.join(state_dir, "cursor-summary.json")
        ends = ug.datetime.fromtimestamp(fut, timezone.utc).isoformat()
        with open(summary_path, "w") as f:
            json.dump({
                "billingCycleStart": "2026-09-25T00:00:00+00:00",
                "billingCycleEnd": ends,
                "individualUsage": {"plan": {"enabled": True, "totalPercentUsed": 80, "autoPercentUsed": 80}},
            }, f)
        hook_path = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
        env = dict(
            os.environ,
            HOME=self.tmp.name,
            USAGE_GATE_STATE=state_dir,
            USAGE_GATE_ORCA="false",
            USAGE_GATE_PRESETS=self.base_presets_path,
            USAGE_GATE_CURSOR_SUMMARY=summary_path,
            FLEET_WATCH_TEST_LOAD_PER_CORE="0.20",
            FLEET_WATCH_TEST_FREE_GB="12.0",
        )
        env.pop("USAGE_GATE_PROJECT_PRESETS", None)
        proc = subprocess.run(
            [sys.executable, hook_path],
            input=json.dumps({
                "tool_name": "Bash",
                "tool_input": {
                    "command": "orca orchestration worker-start --task t --agent cursor --model grok-4.7-xhigh --task-title 'stream-health - check'",
                },
            }),
            capture_output=True, text=True, env=env, cwd=repo_dir, timeout=15,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertNotIn("no known role prefix", proc.stderr)
        self.assertIn("Usage gate pick recommends claude for stream-health", proc.stderr)

    def test_usage_gate_hook_enforces_coordinator_load_and_memory_hard_gate(self):
        import subprocess, time as real_time
        state_dir = os.path.join(self.tmp.name, "state-overflow")
        os.makedirs(state_dir)
        now = real_time.time()
        with open(os.path.join(state_dir, "claude-rate-limits.json"), "w") as f:
            json.dump({"seven_day": {"used_percentage": 15.0, "resets_at": now + 86400}, "_written_at": now}, f)
        fw_cfg_path = os.path.join(self.tmp.name, "fleet-watch.json")
        with open(fw_cfg_path, "w") as f:
            json.dump({"host_caps": {"local": 4, "overflow-1": 2, "overflow-2": 2}}, f)
        hook_path = os.path.join(os.path.dirname(__file__), "..", "usage-gate-hook.py")
        env = dict(
            os.environ,
            HOME=self.tmp.name,
            USAGE_GATE_STATE=state_dir,
            USAGE_GATE_ORCA="false",
            USAGE_GATE_PRESETS=self.base_presets_path,
            FLEET_WATCH_CONFIG=fw_cfg_path,
            FLEET_WATCH_TEST_LOAD_PER_CORE="0.85",
            FLEET_WATCH_TEST_FREE_GB="12.0",
        )
        env.pop("ORCA_WORKSPACE_ID", None)
        env.pop("ORCA_WORKTREE_ID", None)
        proc = subprocess.run(
            [sys.executable, hook_path],
            input=json.dumps({
                "tool_name": "Bash",
                "tool_input": {"command": "orca orchestration worker-start --task t --agent claude --spec ok"},
            }),
            capture_output=True, text=True, env=env, timeout=15,
        )
        self.assertEqual(proc.returncode, 0)
        output = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertIn("overflow-1", output["permissionDecisionReason"])
        self.assertIn("script/start-remote-worker.sh --on overflow-1", output["permissionDecisionReason"])


class BuilderCursorRoute(unittest.TestCase):
    """Owner 2026-11-09 line 7: builders take Cursor grok-4.7-xhigh first, in code.

    The preset text may still list Claude first. Strong roles never take Cursor.
    Light is whatever role pick already stores as tier light (fullstack-dev-small).
    """

    PRESETS = os.path.join(os.path.dirname(__file__), "..", "..", ".orca", "presets.json")
    FS = [{"provider": "claude", "model": "sonnet", "effort": "medium"},
          {"provider": "antigravity", "model": "gemini-4-argon-medium"},
          {"provider": "cursor", "model": "grok-4.7-xhigh"}]
    LIGHT = [{"provider": "claude", "model": "haiku"},
             {"provider": "antigravity", "model": "gemini-3.8-flash"},
             {"provider": "cursor", "model": "grok-4.7-xhigh"}]

    def flags(self, role, roles, weekly):
        path = os.path.join(self.tmp, "presets.json")
        with open(path, "w") as handle:
            json.dump({"roles": roles}, handle)

        def fake_run(provider, *_args, **_kwargs):
            used = weekly.get(provider, 10)
            verdict = weekly.get(provider + ":verdict")
            if verdict is None:
                verdict = "blocked" if used >= 95 else "allowed"
            return {"provider": provider, "verdict": verdict, "ceiling": 95,
                    "weekly_used": used, "reserve": 0}

        with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}), \
                mock.patch.object(ug, "run", side_effect=fake_run), \
                mock.patch.object(ug, "antigravity_models", return_value=None), \
                contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            status = ug.main(["pick", "--role", role])
        return status, out.getvalue().strip()

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def test_builder_names_are_fullstack_dev_and_light_tier(self):
        with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": self.PRESETS}):
            self.assertTrue(ug.is_builder_role("fullstack-dev"))
            self.assertTrue(ug.is_builder_role("fullstack-dev-small"))
            for role in ("elon", "architect-pm", "qa-sdet", "secops-finops", "release-manager"):
                self.assertFalse(ug.is_builder_role(role), role)

    def test_fullstack_dev_picks_cursor_when_allowed_even_if_text_lists_claude_first(self):
        # Cursor has less headroom than Claude and Antigravity. The old pin would stay on Claude.
        roles = {"fullstack-dev": {"tier": "workhorse", "pin": True, "chain": self.FS}}
        status, out = self.flags("fullstack-dev", roles, {"cursor": 80, "claude": 40, "antigravity": 5})
        self.assertEqual((status, out), (0, "--agent cursor --model grok-4.7-xhigh"))

    def test_fullstack_dev_picks_cursor_when_the_chain_omits_it(self):
        chain = [entry for entry in self.FS if entry["provider"] != "cursor"]
        roles = {"fullstack-dev": {"tier": "workhorse", "pin": True, "chain": chain}}
        status, out = self.flags("fullstack-dev", roles, {"cursor": 80, "claude": 10, "antigravity": 10})
        self.assertEqual((status, out), (0, "--agent cursor --model grok-4.7-xhigh"))

    def test_fullstack_dev_picks_sonnet_only_when_cursor_is_blocked(self):
        # Antigravity has more headroom. Builders still walk the chain: Claude, then Antigravity.
        roles = {"fullstack-dev": {"tier": "workhorse", "pin": True, "chain": self.FS}}
        status, out = self.flags("fullstack-dev", roles, {"cursor": 96, "claude": 40, "antigravity": 5})
        self.assertEqual((status, out), (0, "--agent claude --model sonnet --effort medium"))

    def test_fullstack_dev_picks_antigravity_after_cursor_and_claude_are_blocked(self):
        roles = {"fullstack-dev": {"tier": "workhorse", "pin": True, "chain": self.FS}}
        status, out = self.flags("fullstack-dev", roles, {"cursor": 96, "claude": 96, "antigravity": 5})
        self.assertEqual((status, out), (0, "--agent antigravity --model gemini-4-argon-medium"))

    def test_light_tier_picks_cursor_then_its_own_claude_then_antigravity(self):
        roles = {"clerk": {"tier": "light", "chain": self.LIGHT},
                 "fullstack-dev-small": {"tier": "light", "chain": self.LIGHT}}
        status, out = self.flags("clerk", roles, {"cursor": 80, "claude": 10, "antigravity": 1})
        self.assertEqual((status, out), (0, "--agent cursor --model grok-4.7-xhigh"))
        status, out = self.flags("fullstack-dev-small", roles, {"cursor": 96, "claude": 40, "antigravity": 1})
        self.assertEqual((status, out), (0, "--agent claude --model haiku"))
        status, out = self.flags("fullstack-dev-small", roles, {"cursor": 96, "claude": 96, "antigravity": 5})
        self.assertEqual((status, out), (0, "--agent antigravity --model gemini-3.8-flash"))

    def test_strong_roles_never_pick_cursor(self):
        chain = [{"provider": "cursor", "model": "grok-4.7-xhigh"},
                 {"provider": "claude", "model": "opus", "effort": "medium"},
                 {"provider": "antigravity", "model": "gemini-4-argon-high"}]
        roles = {role: {"tier": "strong", "chain": chain}
                 for role in ("elon", "architect-pm", "secops-finops")}
        for role in roles:
            with self.subTest(role=role):
                status, out = self.flags(role, roles, {"cursor": 1, "claude": 40, "antigravity": 40})
                self.assertEqual((status, out), (0, "--agent claude --model opus --effort medium"))
                self.assertNotIn("cursor", out)

    def test_qa_sdet_may_pick_cursor_grok(self):
        chain = [{"provider": "cursor", "model": "grok-4.7-xhigh"},
                 {"provider": "claude", "model": "opus", "effort": "medium"},
                 {"provider": "antigravity", "model": "gemini-4-argon-high"}]
        roles = {"qa-sdet": {"tier": "strong", "chain": chain}}
        status, out = self.flags("qa-sdet", roles, {"cursor": 1, "claude": 40, "antigravity": 40})
        self.assertEqual((status, out), (0, "--agent cursor --model grok-4.7-xhigh"))

    def test_qa_sdet_falls_back_to_a_different_claude_model_when_other_families_are_blocked(self):
        chain = [{"provider": "claude", "model": "opus", "effort": "high"},
                 {"provider": "antigravity", "model": "gemini-4-argon-high"},
                 {"provider": "cursor", "model": "grok-4.7-high"}]
        path = os.path.join(self.tmp, "fallback.json")
        with open(path, "w") as handle:
            json.dump({"roles": {"qa-sdet": {"tier": "strong", "chain": chain}}}, handle)

        def fake_run(provider, *_args, **_kwargs):
            blocked = provider != "claude"
            return {"provider": provider, "verdict": "blocked" if blocked else "allowed",
                    "ceiling": 95, "weekly_used": 96 if blocked else 10, "reserve": 0,
                    "blocked_until": FUT if blocked else None}

        with mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": path}), \
                mock.patch.object(ug, "run", side_effect=fake_run), \
                mock.patch.object(ug, "antigravity_models", return_value=None):
            result = ug.pick("qa-sdet", "claude", None, None, None)
        self.assertEqual(result["selected"]["provider"], "claude")
        self.assertTrue(result["selected"].get("same_family_fallback"))
        models = [row["model"] for row in result["candidates"] if row.get("same_family_fallback")]
        self.assertEqual(models, ["opus", "sonnet"])

    def test_shipped_chains_match_the_builder_rule(self):
        with open(self.PRESETS) as handle:
            roles = json.load(handle)["roles"]
        fullstack = roles["fullstack-dev"]["chain"]
        self.assertEqual([entry["provider"] for entry in fullstack], ["cursor", "claude", "antigravity"])
        self.assertEqual(fullstack[0]["model"], "grok-4.7-xhigh")
        self.assertEqual((fullstack[1]["model"], fullstack[1].get("effort")), ("sonnet", "medium"))
        light = roles["fullstack-dev-small"]
        self.assertEqual(light["tier"], "light")
        self.assertEqual([entry["provider"] for entry in light["chain"]], ["cursor", "claude", "antigravity"])
        self.assertEqual(light["chain"][0]["model"], "grok-4.7-xhigh")
        qa = roles["qa-sdet"]["chain"]
        self.assertEqual([entry["provider"] for entry in qa], ["claude", "antigravity", "cursor"])
        self.assertEqual(qa[-1]["model"], "grok-4.7-high")
        for role in ("elon", "architect-pm", "secops-finops"):
            providers = [entry["provider"] for entry in roles[role]["chain"]]
            self.assertNotIn("cursor", providers, role)
