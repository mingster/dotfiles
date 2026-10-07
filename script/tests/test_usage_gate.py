import contextlib, importlib.util, io, json, os, sys, tempfile, unittest
from unittest import mock
spec = importlib.util.spec_from_file_location("ug", os.path.join(os.path.dirname(__file__), "..", "usage-gate.py"))
ug = importlib.util.module_from_spec(spec); spec.loader.exec_module(ug)
NOW = 1_000_000_000.0
FUT = NOW + 86400
D = lambda pct, resets=FUT: {"pct": pct, "resets_at": resets}


class Decide(unittest.TestCase):
    def go(self, reading, state, today="d1"):
        return ug.decide(reading, state, today, NOW, 12, 95)

    def test_first_reading_sets_baseline_and_allows(self):
        v, d, st = self.go(D(40), None)
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 0.0, 40))

    def test_blocks_at_daily_cap(self):
        v, d, _ = self.go(D(52), {"date": "d1", "baseline": 40, "resets_at": FUT})
        self.assertEqual((v, d["reason"]), ("blocked", "daily cap"))

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
        self.assertEqual((v, d["weekly_used"]), ("allowed", 0.0))

    def test_resets_at_jitter_is_the_same_week(self):
        v, d, st = self.go(D(40, FUT + 1), {"date": "d1", "baseline": 38, "resets_at": FUT})
        self.assertEqual((v, d["today_used"], st["baseline"]), ("allowed", 2.0, 38))

    def test_no_reading_is_unknown(self):
        self.assertEqual(self.go(None, None)[0], "unknown")


class Main(unittest.TestCase):
    def test_unreadable_provider_is_no_reading_not_a_usage_error(self):
        for name in ("cursor", "antigravity", "made-up"):
            with self.subTest(name), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ug.main(["check", "--provider", name]), 4)
            self.assertEqual(json.loads(out.getvalue())["reason"], "no reading")


class Fresh(unittest.TestCase):
    def test_old_reading_past_its_reset_is_no_reading(self):
        old = {"pct": 99.0, "resets_at": NOW - 5, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertIsNone(ug.fresh(old, NOW))

    def test_old_reading_before_its_reset_is_kept_as_stale(self):
        old = {"pct": 99.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        self.assertEqual(ug.fresh(old, NOW), {**old, "stale": True})

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
        self.assertEqual(self.check({"pct": 99.0, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}), 3)

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
        self.assertEqual((v, d["reason"], d["reserve"]), ("blocked", "daily cap", 1))

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
        self.assertEqual(self.run_with(2)["verdict"], "blocked")       # 10 + 2 >= 12
        self.assertEqual(self.run_with(1, per_worker=2.0)["verdict"], "blocked")

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
        self.assertEqual((v, d["today_used"], st["baseline"]), ("blocked", 15.0, 45))

    def test_week_reset_since_the_day_start_counts_from_zero(self):
        v, d, _ = self.go(D(13, FUT + 604800), D(80, FUT))   # codex reset at noon: week = today
        self.assertEqual((v, d["today_used"]), ("blocked", 13.0))

    def test_a_week_that_began_today_started_from_zero(self):
        mid = NOW - 3600
        began_today = {"pct": 13.0, "resets_at": mid + 3600 + 604800 - 1800}      # reset - 7 days = 30 min after midnight
        self.assertEqual(ug.start_of_day(began_today, "codex", mid), {"pct": 0.0, "resets_at": began_today["resets_at"]})
        older = {"pct": 13.0, "resets_at": mid + 604800 - 1}                       # began 1 s before midnight
        with mock.patch.dict(ug.DAY_START, {"codex": lambda m: "from logs"}):
            self.assertEqual(ug.start_of_day(older, "codex", mid), "from logs")
        self.assertIsNone(ug.start_of_day(older, "cursor", mid))

    def test_no_day_start_falls_back_to_the_first_check(self):
        self.assertEqual(self.go(D(60), None)[1]["today_used"], 0.0)

    def test_a_day_start_never_exceeds_the_reading(self):
        self.assertEqual(self.go(D(40), D(50))[1]["today_used"], 0.0)

    def test_blocked_until_is_local_midnight_for_the_daily_cap_and_the_reset_for_the_ceiling(self):
        mid = ug.next_midnight(NOW)
        self.assertEqual(ug.blocked_until({"reason": "daily cap", "resets_at": FUT + 9 * 86400}, NOW), mid)
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
        for name in ("claude", "codex", "cursor", "antigravity", "not gated"):
            self.assertIn(name, text)
        self.assertEqual(len([l for l in text.splitlines() if l.startswith("claude")]), 1)

    def test_show_json_is_a_list(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: None, "codex": lambda: None}), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            ug.main(["show", "--json"])
        self.assertEqual(sorted(r["provider"] for r in json.loads(out.getvalue())), ["antigravity", "claude", "codex", "cursor"])


if __name__ == "__main__":
    unittest.main()
