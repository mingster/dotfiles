#!/usr/bin/env python3
"""Daily usage gate for the agent team: stop dispatching when a provider has used
its daily share of the weekly limit, so the week never runs out.

  usage-gate.py check [--provider claude|codex|<other>] [--cap N] [--ceiling 95] [--reserve 1]
  usage-gate.py show [--json]       every provider at once, as a table
  usage-gate.py pick --role <role> [--avoid-family claude|gpt] [--json]

Reads the provider's own weekly percentage, never an estimate:
  codex   latest token_count event in ~/.codex/sessions whose weekly window is
          under rate_limits.primary or rate_limits.secondary
  claude  ~/.claude/state/usage-gate/claude-rate-limits.json, written by
          statusline.sh from Claude Code's statusline input (rate_limits.seven_day)

"Today" is the weekly percentage now minus the weekly percentage at the start of the
local day (codex: the last session event before local midnight; claude: the first
statusline render of the day; otherwise the first check of the day). It is the whole
account's use, including sessions outside Orca. The daily cap is what is left of the
week under the ceiling at the start of today, spread over the days left until the
weekly reset (a partial last day counts as a fraction, the last day may use all of it);
--cap N fixes it at N percent instead. An owner approved cap for one day lives in
STATE/<provider>.cap-override.json as {"date": "YYYY-MM-DD", "cap": N} and ends at local midnight. The gate blocks a new start when
spent + reserve >= cap, or when week + reserve >= ceiling, where reserve is
--reserve (default 1) percent of the week per worker already running on that provider
(`orca orchestration worker-list`), so running workers keep room to finish.
An older Codex reading with an unreset week and no session file modified since
local midnight means zero spend today. Every other reading older than MAX_AGE
(6 hours) says nothing about today's spend, so it never counts for the daily cap.
Weekly usage cannot fall before the reset, so while its
resets_at is still ahead it still blocks on the weekly ceiling. Past the reset, or
of unknown age, it is no reading. So is any provider without a reader (cursor,
antigravity, ...).
Exit codes: 0 allowed, 3 blocked, 4 unknown (no reading; treated as allowed by
callers, reported so the owner can see the gap).
"""
import argparse, glob, json, os, subprocess, sys, time
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
STATE = os.environ.get("USAGE_GATE_STATE", HOME + "/.claude/state/usage-gate")
CODEX = os.environ.get("USAGE_GATE_CODEX_SESSIONS", HOME + "/.codex/sessions")
WEEK_MIN = 10080
MAX_AGE = 6 * 3600  # seconds; an older reading is no reading
ORCA = os.environ.get("USAGE_GATE_ORCA", "orca")
NOT_GATED = ("cursor", "antigravity")


def epoch(at):
    """Epoch seconds from epoch seconds (claude) or an ISO timestamp (codex); None if unreadable."""
    try:
        return float(at)
    except (TypeError, ValueError):
        try:
            return datetime.fromisoformat(str(at).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None


def codex_reading(root=None, before=None, files=8):
    """Newest weekly reading by its own timestamp (not by file name: a long session started
    earlier keeps writing newer events). With before, the newest one older than that epoch
    (a session that straddles it is skipped, which can only overstate today's use)."""
    paths = glob.glob((root or CODEX) + "/**/rollout-*.jsonl", recursive=True)
    if before is not None:      # a file last written before then holds nothing newer than then
        paths = [p for p in paths if os.path.getmtime(p) < before]
    paths = sorted(paths, key=lambda p: os.path.getmtime(p), reverse=True)[:files]
    best = None
    for path in paths:
        try:
            with open(path, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 400000))
                lines = f.read().decode("utf-8", "ignore").splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if '"rate_limits"' not in line:
                continue
            try:
                d = json.loads(line)
                limits = d["payload"]["rate_limits"]
                windows = [limits.get("primary") or {}, limits.get("secondary") or {}]
            except (ValueError, KeyError, AttributeError, TypeError):
                continue
            t = epoch(d.get("timestamp"))
            if t is None or (before is not None and t >= before):
                continue
            for p in windows:
                if p.get("window_minutes") == WEEK_MIN and "used_percent" in p:
                    if best is None or t > best["t"]:
                        best = {"t": t, "pct": float(p["used_percent"]), "resets_at": p.get("resets_at"),
                                "observed_at": d.get("timestamp")}
                    break
            else:
                continue
            break   # newest usable event of this file; older ones in it cannot beat it
    if best:
        best.pop("t")
    return best


def codex_day_start(midnight):
    return codex_reading(before=midnight, files=5)


def claude_reading(path=None):
    try:
        d = json.load(open(path or STATE + "/claude-rate-limits.json"))
        w = d["seven_day"]
        return {"pct": float(w["used_percentage"]), "resets_at": w.get("resets_at"),
                "observed_at": d.get("_written_at")}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def claude_day_start(midnight, path=None):
    """First statusline reading of the local day (statusline.sh writes it once a day)."""
    r = claude_reading(path or STATE + "/claude-day-start.json")
    t = epoch((r or {}).get("observed_at"))
    return r if t is not None and t >= midnight else None


READERS = {"codex": codex_reading, "claude": claude_reading}
DAY_START = {"codex": codex_day_start, "claude": claude_day_start}


def fresh(reading, now):
    """The reading, flagged stale when it is more than MAX_AGE old but its week has not reset
    yet; None when it is old and past its reset, ahead of the clock, or of unknown age.
    observed_at is epoch seconds (claude) or an ISO timestamp (codex)."""
    t = epoch((reading or {}).get("observed_at"))
    if t is None:
        return None
    if abs(now - t) <= MAX_AGE:
        return reading
    resets = reading.get("resets_at")
    if now - t > MAX_AGE and resets and float(resets) >= now:
        return {**reading, "stale": True}
    return None


def day_baseline(day_start, pct, resets):
    """Weekly percentage at the start of the day, 0 when the week reset since, pct when unknown."""
    if not day_start:
        return pct
    then = day_start.get("resets_at")
    if (then is None) != (resets is None) or (then is not None and abs(float(then) - float(resets)) >= 3600):
        return 0.0
    return min(float(day_start["pct"]), pct)


def start_of_day(reading, provider, midnight):
    """Weekly reading at the start of the local day. A week that began today (its reset minus
    seven days is after midnight) started from 0, whatever older logs say."""
    resets = reading.get("resets_at")
    if resets and float(resets) - WEEK_MIN * 60 >= midnight:
        return {"pct": 0.0, "resets_at": resets}
    return DAY_START[provider](midnight) if provider in DAY_START else None


def local_midnight(now):
    return datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def auto_cap(baseline, resets, now, ceiling):
    """Today's share of the week: (ceiling - weekly use at the start of today) / days left
    until the reset, counted from local midnight. Unknown reset: a seventh of the ceiling."""
    if not resets:
        return round(ceiling / 7, 1)
    days = (float(resets) - local_midnight(now)) / 86400
    return round(max(ceiling - baseline, 0.0) / max(days, 1.0), 1)


def decide(reading, state, today, now, cap, ceiling, reserve=0.0, day_start=None):
    """Return (verdict, detail, new_state). verdict: allowed|blocked|unknown.
    reserve is weekly percent held back for workers already running.
    cap None means auto_cap from the day's baseline and the weekly reset."""
    if reading is None:
        return "unknown", {"reason": "no reading"}, state
    pct, resets = reading["pct"], reading.get("resets_at")
    if reading.get("stale"):                # too old for the daily cap, still binding for the ceiling
        if pct >= ceiling:
            return "blocked", {"weekly_used": pct, "ceiling": ceiling, "resets_at": resets,
                               "reason": "weekly ceiling (stale reading)"}, state
        return "unknown", {"reason": "no reading"}, state
    if resets and float(resets) < now:      # the week rolled over since this reading
        pct, resets = 0.0, None
    st = dict(state or {})
    old = st.get("resets_at")
    # codex resets_at jitters by a few seconds between events; only a jump of an hour is a new week
    moved = (old is None) != (resets is None) or (old is not None and abs(float(resets) - float(old)) >= 3600)
    rolled = moved or pct < st.get("baseline", 0)
    if st.get("date") != today or "baseline" not in st or rolled:
        st = {"date": today, "baseline": 0.0 if rolled and st.get("date") == today
              else day_baseline(day_start, pct, resets), "resets_at": resets}
    spent = round(pct - st["baseline"], 1)
    if cap is None:
        cap = auto_cap(st["baseline"], resets, now, ceiling)
    detail = {"weekly_used": pct, "today_used": spent, "cap": cap, "ceiling": ceiling,
              "reserve": reserve, "resets_at": resets}
    if pct + reserve >= ceiling:
        detail["reason"] = "weekly ceiling"
        return "blocked", detail, st
    if spent + reserve >= cap:
        detail["reason"] = "daily cap"
        return "blocked", detail, st
    return "allowed", detail, st


def running_workers(provider):
    """Orca workers with a live terminal on this provider; None when orca cannot say."""
    try:
        r = subprocess.run([ORCA, "orchestration", "worker-list", "--terminal-state", "active",
                            "--limit", "100", "--json"], capture_output=True, text=True, timeout=5)
        rows = json.loads(r.stdout)["result"]["workers"]
        return sum(1 for w in rows if ((w.get("projection") or {}).get("provider") or {}).get("id") == provider)
    except Exception:
        return None


def local(ts):
    return time.strftime("%a %d %b %H:%M %Z", time.localtime(float(ts))).strip() if ts else "unknown"


def next_midnight(now):
    return (datetime.fromtimestamp(now) + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0).timestamp()


def blocked_until(detail, now):
    """Epoch when a blocked provider can start work again (the daily share restarts at local
    midnight, but never later than the weekly reset)."""
    resets = detail.get("resets_at")
    if detail.get("reason") == "daily cap":
        return min(next_midnight(now), float(resets)) if resets else next_midnight(now)
    return float(resets) if resets else None


def run(provider, cap, ceiling, now=None, per_worker=1.0):
    now = now or time.time()
    today = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    midnight = local_midnight(now)
    path = f"{STATE}/{provider}.json"
    try:
        state = json.load(open(path))
    except (OSError, ValueError):
        state = None
    reader = READERS.get(provider)
    reading = fresh(reader(), now) if reader else None
    # An idle Codex account has spent nothing locally today. Require an unreset,
    # dated reading and check every session file, including ones without rate limits.
    if provider == "codex" and reading and reading.get("stale"):
        try:
            active = any(os.path.getmtime(p) >= midnight
                         for p in glob.glob(CODEX + "/**/*", recursive=True) if os.path.isfile(p))
        except OSError:
            active = True  # cannot prove inactivity
        if not active and float(reading["resets_at"]) > now:
            reading = {k: v for k, v in reading.items() if k != "stale"}
            state = {"date": today, "baseline": reading["pct"], "resets_at": reading["resets_at"]}
    running = running_workers(provider) if reading else None
    reserve = round(per_worker * (running or 0), 1) if cap is None else round(min(per_worker * (running or 0), cap), 1)
    day_start = None
    if reading and (state or {}).get("date") != today:
        day_start = start_of_day(reading, provider, midnight)
    if cap is None:
        # Owner approved one day cap: STATE/<provider>.cap-override.json {"date": "YYYY-MM-DD", "cap": N}.
        try:
            o = json.load(open(f"{STATE}/{provider}.cap-override.json"))
            if o.get("date") == today:
                cap = float(o["cap"])
        except (OSError, ValueError, KeyError, TypeError):
            pass
    verdict, detail, new = decide(reading, state, today, now, cap, ceiling, reserve, day_start)
    if new is not state and new:
        os.makedirs(STATE, exist_ok=True)
        json.dump(new, open(path, "w"))
    if reading:
        t = epoch(reading.get("observed_at"))
        detail["reading_age_min"] = round((now - t) / 60) if t is not None else None
        detail["running"] = running
        detail["resets_local"] = local(detail.get("resets_at"))
        if verdict == "blocked":
            until = blocked_until(detail, now)
            detail["blocked_until"], detail["blocked_until_local"] = until, local(until)
    return {"provider": provider, "verdict": verdict, **detail}


def table(rows):
    head = ("provider", "verdict", "week%", "today%", "cap%", "reserve%", "running", "reading", "week resets", "next start")
    out = []
    for r in rows:
        if r["verdict"] == "unknown":
            note = "not gated" if r["provider"] in NOT_GATED else r.get("reason", "no reading")
            out.append((r["provider"], "unknown", "-", "-", "-", "-", "-", note, "-", "-"))
            continue
        age = r.get("reading_age_min")
        out.append((r["provider"], r["verdict"], f"{r['weekly_used']:g}",
                    *(f"{r[k]:g}" if k in r else "?" for k in ("today_used", "cap", "reserve")),
                    "?" if r.get("running") is None else str(r["running"]),
                    "?" if age is None else f"{age}m ago", r.get("resets_local", "-"),
                    f"{r['blocked_until_local']} ({r['reason']})" if r["verdict"] == "blocked" else "now"))
    widths = [max(len(str(x[i])) for x in [head] + out) for i in range(len(head))]
    lines = ["  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip() for row in [head] + out]
    lines.append("today% = week% now minus week% at the start of the local day, for the whole account "
                 "(sessions outside Orca count). cap% = (ceiling - week% at the start of today) / days left "
                 "until the weekly reset. reserve% = --reserve per running worker.")
    ordered = sorted(rows, key=lambda r: headroom(r)[1] if headroom(r)[1] is not None else -float("inf"),
                     reverse=True)
    order = []
    for row in ordered:
        fraction = headroom(row)[1]
        note = f"{fraction * 100:.1f}%" if fraction is not None else (
            "not gated" if row["provider"] in NOT_GATED else row.get("reason", "unknown"))
        if note == "no reading":
            note = "unknown"
        order.append(f"{row['provider']} {note}")
    lines.append("pick order now: " + ", ".join(order))
    return "\n".join(lines)


def headroom(row):
    """Remaining weekly percentage points and fraction of today's cap."""
    if "today_used" not in row or "cap" not in row:
        return None, None
    room = min(row["cap"] - row["today_used"] - row["reserve"],
               row["ceiling"] - row["weekly_used"] - row["reserve"])
    return room, room / row["cap"] if row["cap"] > 0 else 0.0


def role_chain(role):
    path = os.environ.get("USAGE_GATE_PRESETS", HOME + "/.orca/presets.json")
    with open(path) as f:
        presets = json.load(f)
    entry = presets.get("roles", {}).get(role, {})
    if "chain" in entry:
        return entry["chain"], entry.get("pin", False)
    # Unknown roles use workhorse models from this file, never hardcoded ids.
    tier = entry.get("tier", "workhorse")
    models = dict(presets.get("tiers", {}).get(tier, {}))
    for r in presets.get("roles", {}).values():
        if r.get("tier") == tier:
            for candidate in r.get("chain", []):
                models.setdefault(candidate["provider"], candidate)
    chain = []
    for provider in presets.get("default_chain", []):
        if isinstance(provider, dict):
            chain.append(provider)
        elif provider in models:
            chain.append({**models[provider], "provider": provider})
        else:
            raise ValueError(f"no {tier} model for {provider} in presets")
    return chain, entry.get("pin", False)


def family(entry):
    provider, model = entry["provider"], entry["model"]
    if provider == "claude" or (provider in NOT_GATED and model.startswith("claude-")):
        return "claude"
    if provider == "codex" or model.startswith("gpt-"):
        return "gpt"
    return None


def pick(role, avoid, cap, ceiling, per_worker):
    chain, pinned = role_chain(role)
    rows = {e["provider"]: None for e in chain}
    for provider in rows:
        rows[provider] = run(provider, cap, ceiling, per_worker=per_worker)
    gated = [r for p, r in rows.items() if p in READERS]
    fallback = all(r["verdict"] == "blocked" for r in gated)
    candidates, allowed = [], []
    for index, entry in enumerate(chain):
        row = rows[entry["provider"]]
        room, fraction = headroom(row)
        eligible = row["verdict"] == "allowed" if entry["provider"] in READERS else fallback
        excluded = avoid is not None and family(entry) == avoid
        candidate = {**entry, "verdict": row["verdict"], "headroom": room,
                     "headroom_fraction": fraction, "excluded_family": excluded,
                     "eligible": eligible and not excluded}
        candidates.append(candidate)
        if candidate["eligible"]:
            allowed.append((index, candidate))
    chosen = None
    if allowed:
        if (pinned or role in ("release-manager", "elon")) and allowed[0][0] == 0:
            chosen = allowed[0][1]
        else:
            chosen = max(allowed, key=lambda pair: pair[1]["headroom_fraction"]
                         if pair[1]["headroom_fraction"] is not None else -1)[1]
    resets = [r["blocked_until"] for r in rows.values() if r.get("blocked_until")]
    until = min(resets) if resets else None
    return {"role": role, "selected": chosen, "candidates": candidates,
            "blocked_until": until, "blocked_until_local": local(until)}


def candidate_reason(candidate):
    fraction = candidate["headroom_fraction"]
    room = candidate["headroom"]
    detail = "headroom unknown" if room is None else f"headroom {room:g}% ({fraction * 100:.1f}% of cap)"
    note = "excluded family" if candidate["excluded_family"] else candidate["verdict"]
    return f"{candidate['provider']} {candidate['model']}: {detail}, {note}"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "show", "pick"])
    ap.add_argument("--provider")
    ap.add_argument("--role")
    ap.add_argument("--avoid-family", choices=["claude", "gpt"])
    ap.add_argument("--cap", type=float, default=None,
                    help="fixed daily cap in weekly percent; default: remaining week / days left")
    ap.add_argument("--ceiling", type=float, default=95.0)
    ap.add_argument("--reserve", type=float, default=1.0,
                    help="weekly percent held back per worker already running on the provider")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "pick":
        if not a.role:
            ap.error("pick requires --role")
        try:
            result = pick(a.role, a.avoid_family, a.cap, a.ceiling, a.reserve)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"cannot read role presets: {exc}", file=sys.stderr)
            return 3
        if a.json:
            print(json.dumps(result))
        else:
            print("; ".join(candidate_reason(c) for c in result["candidates"]), file=sys.stderr)
            chosen = result["selected"]
            if chosen:
                flags = f"--agent {chosen['provider']} --model {chosen['model']}"
                if chosen.get("effort"):
                    flags += f" --effort {chosen['effort']}"
                print(flags)
            else:
                print(f"nothing allowed; earliest reset: {result['blocked_until_local']}", file=sys.stderr)
        return 0 if result["selected"] else 3
    names = [a.provider] if a.provider else list(READERS)
    if a.cmd == "show" and not a.provider:
        names += list(NOT_GATED)
    out = [run(n, a.cap, a.ceiling, per_worker=a.reserve) for n in names]
    if a.cmd == "show" and not a.json:
        print(table(out))
    else:
        print(json.dumps(out if len(out) > 1 else out[0]))
    if a.cmd == "show":
        return 0
    if a.provider:
        return {"allowed": 0, "blocked": 3, "unknown": 4}[out[0]["verdict"]]
    return 0 if any(o["verdict"] != "blocked" for o in out) else 3


if __name__ == "__main__":
    sys.exit(main())
