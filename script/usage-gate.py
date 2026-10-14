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
  cursor  https://cursor.com/api/usage-summary, called with the session the Cursor app
          already holds (read in memory, never printed or stored). Cursor bills a
          monthly cycle, not a week, so the cycle is mapped onto the same formula, see
          cursor_parse

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
of unknown age, it is no reading. So is any provider without a reader, and
cursor or Antigravity when usage cannot be fetched. Antigravity reads quota per
model pool from its local language server and uses ceiling only gating.
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
NOT_GATED = ()
CURSOR_URL = "https://cursor.com/api/usage-summary"
CURSOR_SUMMARY = os.environ.get("USAGE_GATE_CURSOR_SUMMARY")  # a summary JSON file instead of the network (tests)


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


def cursor_parse(summary, now):
    """Map Cursor's billing cycle onto the weekly formula. Cursor has no weekly window: it
    bills one cycle (about a month) with a plan allowance. So pct is the plan's
    totalPercentUsed (the dashboard's "used N% of included total usage"), resets_at is
    billingCycleEnd, and began_at is billingCycleStart. The cap is then what is left of the
    cycle under the ceiling at the start of today divided by the days left until the cycle
    ends, exactly as for a week. On-demand spend is not part of the plan percentage."""
    try:
        plan = summary["individualUsage"]["plan"]
        ends = epoch(summary["billingCycleEnd"])
        began = epoch(summary["billingCycleStart"])
        if not plan.get("enabled", True) or ends is None:
            return None
        return {"pct": float(plan["totalPercentUsed"]), "resets_at": ends, "began_at": began,
                "observed_at": now}
    except (KeyError, TypeError, ValueError, AttributeError):
        return None


def cursor_reading(path=None):
    """Read-only. The access token comes from the Cursor app's own state database, is turned
    into the dashboard session cookie in memory, and is never printed or written anywhere."""
    path = path or CURSOR_SUMMARY
    try:
        if path:
            return cursor_parse(json.load(open(path)), time.time())
        import base64, sqlite3, urllib.parse, urllib.request
        db = (HOME + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
              if sys.platform == "darwin" else HOME + "/.config/Cursor/User/globalStorage/state.vscdb")
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        token = con.execute("select value from ItemTable where key='cursorAuth/accessToken'").fetchone()[0]
        con.close()
        user = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==="))["sub"].split("|")[-1]
        cookie = "WorkosCursorSessionToken=" + urllib.parse.quote(f"{user}::{token}", safe="")
        with urllib.request.urlopen(urllib.request.Request(CURSOR_URL, headers={"Cookie": cookie}), timeout=8) as r:
            return cursor_parse(json.load(r), time.time())
    except Exception:
        return None


def antigravity_fetch():
    """Read local quota without persisting or displaying the server's CSRF token."""
    import re, ssl, urllib.request
    deadline = time.monotonic() + 7
    try:
        processes = subprocess.run(["ps", "-axo", "pid,command"], capture_output=True,
                                   text=True, timeout=2).stdout
        for line in processes.splitlines():
            if "language_server_macos" not in line:
                continue
            token = re.search(r"--csrf_token(?:=|\s+)(\S+)", line)
            if not token or not line.split()[0].isdigit():
                continue
            ports = subprocess.run(["lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p",
                                    line.split()[0]], capture_output=True, text=True, timeout=2).stdout
            for port in sorted(set(re.findall(r":(\d+) \(LISTEN\)", ports))):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                request = urllib.request.Request(
                    f"https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus",
                    data=json.dumps({"metadata": {"ideName": "antigravity",
                                    "extensionName": "antigravity", "locale": "en"}}).encode(),
                    headers={"Content-Type": "application/json", "Connect-Protocol-Version": "1",
                             "X-Codeium-Csrf-Token": token.group(1)})
                try:
                    # The local server uses a self-signed certificate. Never use a proxy.
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
                    with opener.open(request, timeout=min(2, remaining)) as response:
                        payload = json.load(response)
                    if isinstance(payload, dict) and "userStatus" in payload:
                        return payload
                except Exception:
                    continue
    except Exception:
        pass
    return None


def antigravity_pool(model):
    if model.startswith(("claude-", "gpt-oss")):
        return "claude"
    if model.startswith("gemini-"):
        return "gemini"
    return None


def antigravity_reading(fetch=None):
    """One reading per model pool. Duplicate model labels share the same quota."""
    try:
        payload = (fetch or antigravity_fetch)()
        configs = payload["userStatus"]["cascadeModelConfigData"]["clientModelConfigs"]
        pools = {}
        for config in configs:
            label = config.get("label", "")
            pool = "claude" if label.startswith(("Claude", "GPT-OSS")) else (
                "gemini" if label.startswith("Gemini") else None)
            if pool is None:
                continue
            quota = config["quotaInfo"]
            remaining = float(quota["remainingFraction"])
            resets = epoch(quota["resetTime"])
            if not 0 <= remaining <= 1 or resets is None:
                continue
            reading = {"pct": round(100 * (1 - remaining), 10), "resets_at": resets,
                       "observed_at": time.time()}
            if pool not in pools or reading["pct"] > pools[pool]["pct"]:
                pools[pool] = reading
        return pools or None
    except (KeyError, TypeError, ValueError, AttributeError, OSError):
        return None


READERS = {"codex": codex_reading, "claude": claude_reading, "cursor": cursor_reading,
           "antigravity": antigravity_reading}
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
    seven days, or the cycle start for cursor, is after midnight) started from 0, whatever
    older logs say."""
    resets = reading.get("resets_at")
    began = reading.get("began_at") or (float(resets) - WEEK_MIN * 60 if resets else None)
    if resets and began is not None and float(began) >= midnight:
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


def antigravity_result(pools, ceiling, now, model=None, pool=None):
    selected = pool or (antigravity_pool(model) if model else None)
    reading = pools.get(selected) if selected else (max(pools.values(), key=lambda r: r["pct"])
                                                   if pools and not model else None)
    result = {"provider": "antigravity" + ("/" + pool if pool else ""),
              "verdict": "unknown", "reason": "no reading", "policy": "ceiling only"}
    if not reading or reading["resets_at"] <= now:
        return result
    blocked = reading["pct"] >= ceiling
    result.update(verdict="blocked" if blocked else "allowed", weekly_used=reading["pct"],
                  ceiling=ceiling, resets_at=reading["resets_at"],
                  resets_local=local(reading["resets_at"]), reading_age_min=0)
    result.pop("reason")
    if blocked:
        result.update(reason="pool ceiling", blocked_until=reading["resets_at"],
                      blocked_until_local=local(reading["resets_at"]))
    return result


def run(provider, cap, ceiling, now=None, per_worker=1.0, model=None):
    now = now or time.time()
    if provider == "antigravity":
        return antigravity_result(READERS[provider]() or {}, ceiling, now, model=model)
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
        # Owner approved cap: STATE/<provider>.cap-override.json {"date": "YYYY-MM-DD", "cap": N}
        # for one day, or {"until": <epoch>, "cap": N} for a window (owner 2026-10-13).
        try:
            o = json.load(open(f"{STATE}/{provider}.cap-override.json"))
            if o.get("date") == today or ("until" in o and now < float(o["until"])):
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
                 "until the weekly reset. reserve% = --reserve per running worker. Antigravity reads per model pool and uses only the ceiling.")
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
    if row.get("policy") == "ceiling only" and "weekly_used" in row:
        room = row["ceiling"] - row["weekly_used"]
        return room, room / row["ceiling"] if row["ceiling"] > 0 else 0.0
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
    if provider == "claude" or (provider in ("antigravity", "cursor") and model.startswith("claude-")):
        return "claude"
    if provider == "codex" or model.startswith("gpt-"):
        return "gpt"
    return None


def pick(role, avoid, cap, ceiling, per_worker):
    chain, pinned = role_chain(role)
    rows = {}
    for entry in chain:
        key = (entry["provider"], entry["model"] if entry["provider"] == "antigravity" else None)
        if key not in rows:
            rows[key] = run(entry["provider"], cap, ceiling, per_worker=per_worker, model=key[1])
    gated = [r for (p, _), r in rows.items() if p in READERS]
    fallback = all(r["verdict"] == "blocked" for r in gated)
    candidates, allowed = [], []
    for index, entry in enumerate(chain):
        row = rows[(entry["provider"], entry["model"] if entry["provider"] == "antigravity" else None)]
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
    ap.add_argument("--model", help="Antigravity model id; omitted selects the worst pool")
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
    out = []
    for name in names:
        if name == "antigravity" and a.cmd == "show":
            pools = READERS[name]() or {}
            out.extend(antigravity_result(pools, a.ceiling, time.time(), pool=pool)
                       for pool in ("claude", "gemini"))
        else:
            out.append(run(name, a.cap, a.ceiling, per_worker=a.reserve, model=a.model))
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
