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
            ev = lambda p, w: json.dumps({"timestamp": "x", "payload": {"type": "token_count",
                "rate_limits": {"primary": {"used_percent": p, "window_minutes": w, "resets_at": 5}}}})
            open(t + "/2026/10/05/rollout-a.jsonl", "w").write(ev(10, 10080) + "\n" + ev(33, 10080) + "\n" + ev(99, 300) + "\n")
            self.assertEqual(ug.codex_reading(t)["pct"], 33.0)

    def codex(self, *limits):
        with tempfile.TemporaryDirectory() as t:
            os.makedirs(t + "/2026/10/05")
            lines = [json.dumps({"timestamp": "x", "payload": {"type": "token_count", "rate_limits": r}}) for r in limits]
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


if __name__ == "__main__":
    unittest.main()
