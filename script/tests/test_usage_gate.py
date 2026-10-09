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
        self.assertEqual((v, d["cap"], d["today_used"]), ("blocked", 15.0, 15.0))   # spent 15 of 15
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
            self.assertEqual((r["verdict"], r["today_used"], r["weekly_used"], r["reserve"]),
                             ("allowed", 0, 39, 1))
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
            self.assertEqual((r["verdict"], r["reason"], r["today_used"]), ("blocked", "weekly ceiling", 0))
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
        self.assertEqual((status, result["selected"]["provider"]), (0, "codex"))

    def test_ties_keep_chain_order_and_reserve_can_block_all_gated_providers(self):
        self.assertIn("--agent claude", self.invoke(codex=44)[1])
        self.assertIn("--agent cursor", self.invoke(claude=51, codex=51, running=1)[1])

    def test_pinned_roles_keep_first_allowed_entry(self):
        for role, pin in (("elon", False), ("release-manager", False), ("custom", True)):
            with self.subTest(role):
                self.assertIn("--agent claude", self.invoke(role=role, pin=pin)[1])
                self.assertIn("--agent codex", self.invoke(role=role, pin=pin, claude=52)[1])

    def test_review_excludes_family_even_for_pinned_roles(self):
        self.assertIn("--agent claude", self.invoke(extra=("--avoid-family", "gpt"))[1])
        self.assertIn("--agent codex", self.invoke(role="elon", extra=("--avoid-family", "claude"))[1])
        # Claude models on both ungated providers are also excluded.
        chain = [{"provider": "claude", "model": "opus"},
                 {"provider": "cursor", "model": "claude-opus"},
                 {"provider": "antigravity", "model": "claude-opus"}]
        status, out, err = self.invoke(chain=chain, claude=52, extra=("--avoid-family", "claude"))
        self.assertEqual((status, out), (3, ""))
        self.assertIn(ug.local(ug.next_midnight(NOW)), err)
        chain = [{"provider": "cursor", "model": "gpt-test"}]
        self.assertEqual(self.invoke(chain=chain, extra=("--avoid-family", "gpt"))[0], 3)

    def test_ungated_is_only_a_last_resort_and_unknown_does_not_prove_blocked(self):
        self.assertIn("--agent codex", self.invoke(claude=52)[1])
        self.assertIn("--agent cursor", self.invoke(claude=52, codex=52)[1])
        self.assertEqual(self.invoke(claude=None, codex=52)[0], 3)
        self.assertEqual(self.invoke(extra=("--avoid-family", "gpt"), claude=None)[0], 3)

    def test_unknown_role_uses_default_chain_and_models_from_file(self):
        status, out, _ = self.invoke(role="unlisted", default=True, claude=41)
        self.assertEqual((status, out.strip()), (0, "--agent codex --model gpt-test --effort low"))

    def test_json_includes_selection_headroom_and_every_candidate(self):
        status, out, _ = self.invoke(extra=("--json",), running=2)
        result = json.loads(out)
        self.assertEqual((status, result["selected"]["provider"], result["selected"]["headroom"]),
                         (0, "codex", 9))
        self.assertEqual(len(result["candidates"]), 4)

    def test_no_allowed_entry_reports_earliest_reset_and_exit_three_in_json(self):
        chain = [{"provider": "claude", "model": "opus"}, {"provider": "codex", "model": "gpt-test"}]
        status, out, _ = self.invoke(chain=chain, claude=96, codex=52, extra=("--json",))
        result = json.loads(out)
        self.assertEqual((status, result["selected"], result["blocked_until"]),
                         (3, None, ug.next_midnight(NOW)))


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
                         "pick order now: claude 100.0%, codex unknown, cursor not gated, antigravity not gated")

    def test_show_handles_a_stale_weekly_ceiling_without_daily_numbers(self):
        reading = {"pct": 96, "resets_at": FUT, "observed_at": NOW - ug.MAX_AGE - 1}
        with tempfile.TemporaryDirectory() as t, mock.patch.object(ug, "STATE", t), \
                mock.patch.dict(ug.READERS, {"claude": lambda: reading, "codex": lambda: None}), \
                mock.patch.object(ug.time, "time", return_value=NOW), \
                mock.patch.object(ug, "running_workers", return_value=0), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(ug.main(["show"]), 0)
        self.assertIn("weekly ceiling (stale reading)", out.getvalue())


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
            env = {**os.environ, "ORCA_CLI_COMMAND": stub, "TEST_BASE_LOG": t + "/args"}
            args = ["bash", script, "--run", "unused", "--spec", "unused", "--title", "unused",
                    "--name", "unused", "--repo", t]
            for override, expected in (([], "origin/master"), (["--base-branch", "origin/release"], "origin/release")):
                subprocess.run(args + override, env=env, capture_output=True)
                with open(t + "/args") as f:
                    flags = f.read().splitlines()
                self.assertEqual(flags[flags.index("--base-branch") + 1], expected)


if __name__ == "__main__":
    unittest.main()
