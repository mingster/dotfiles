#!/usr/bin/env python3
"""Provider usage gate: only fresh real usage plus running worker reserve can block.

check --provider NAME exits 0 allowed, 3 weekly/cycle ceiling reached, 4 unknown.
show [--json] includes the exact source and reading age; pick --role ROLE retains
its existing flags and ranks providers by remaining weekly/cycle headroom.
Codex reads session rate_limits and refreshes via app-server account/rateLimits/read;
Claude reads statusline seven_day and refreshes via the authenticated OAuth usage
endpoint; Cursor reports unknown until its Composer 2.5 allowance is verifiable;
Antigravity queries local GetUserStatus, defaulting to the Gemini Flash pool.
Missing, stale (>5 minutes), expired, invalid or future readings trigger a refresh.
If the real source cannot supply a fresh reading, report unknown, never inferred
zero usage or a stale ceiling verdict. Unknown does not block worker starts.
Daily caps and owner cap overrides remain pacing hints only: at the hint, allow
with note "pacing: prefer a lighter model". --reserve (default 1) holds weekly
percentage points per running worker; --ceiling defaults to 95. Cursor uses its
provider billing cycle when verifiable; Antigravity uses separate Flash, Pro/Argon
and Claude provider model pools.
"""
import argparse, re, glob, json, math, os, subprocess, sys, time
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
STATE = os.environ.get("USAGE_GATE_STATE", HOME + "/.claude/state/usage-gate")
CODEX = os.environ.get("USAGE_GATE_CODEX_SESSIONS", HOME + "/.codex/sessions")
WEEK_MIN = 10080
TIE_POINTS = 2.0  # headroom points within which the preset provider keeps the pick
MAX_AGE = 5 * 60  # seconds; an older reading is no reading
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
    """The usage-summary totalPercentUsed is aggregate plan usage, not a verified
    Composer 2.5 allowance. Until a model-specific source is available, it cannot
    establish whether the only approved Cursor model has headroom.
    """
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
        try:
            row = con.execute("select value from ItemTable where key='cursorAuth/accessToken'").fetchone()
        finally:
            con.close()
        # New app credentials can be opaque. They cannot supply the user id required
        # for this dashboard cookie; never guess it or send an invented credential.
        if not row or len(row[0].split(".")) != 3:
            return None
        token = row[0]
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
            # The binary is language_server_macos in older builds, language_server since 2026-10.
            if not re.search(r"/language_server(?:_macos)?\s", line):
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
    model = model.lower().replace(" ", "-")
    if model.startswith(("claude-", "gpt-oss")):
        return "claude"
    if model.startswith("gemini-"):
        if "flash" in model.split("-"):
            return "gemini-flash"
        if set(model.split("-")) & {"argon", "pro"}:
            return "gemini-pro"
    return None


def antigravity_reading(fetch=None):
    """One reading per model pool, with banner-blocked pools forced to exhausted until their reset."""
    pools = antigravity_pools(fetch) or {}
    now = time.time()
    for pool, resets in read_banners(now).items():
        pools[pool] = {"pct": 100.0, "resets_at": resets, "observed_at": now, "source": "banner"}
    return pools or None


def antigravity_pools(fetch=None):
    """One reading per model pool. Duplicate model labels share the same quota."""
    try:
        payload = (fetch or antigravity_fetch)()
        configs = payload["userStatus"]["cascadeModelConfigData"]["clientModelConfigs"]
        pools = {}
        for config in configs:
            label = config.get("label", "")
            pool = antigravity_pool(label)
            if pool is None:
                continue
            quota = config["quotaInfo"]
            # An exhausted pool omits remainingFraction (protobuf drops zero values).
            remaining = float(quota.get("remainingFraction", 0))
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


BANNER_FILE = os.environ.get("USAGE_GATE_BANNER_FILE", HOME + "/.claude/state/antigravity-banner.json")
BANNER_RE = re.compile(r"quota reached.{0,200}?resets? in\s+(?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m)?",
                       re.I | re.S)


def parse_quota_banner(text, now):
    """Pool and reset time from an Antigravity 'quota reached ... Resets in 94h29m' screen, else None."""
    match = BANNER_RE.search(text or "")
    if not match or not any(match.groups()):
        return None
    days, hours, minutes = (int(g or 0) for g in match.groups())
    window = text[max(0, match.start() - 300):match.end()].lower()
    named = re.search(r"\b(?:claude|gpt-oss|gemini)[\w.-]*(?:\s+(?:[\d.]+|flash|argon|pro))*", window)
    pool = antigravity_pool(named.group()) if named else None
    if pool is None:
        return None
    return pool, now + days * 86400 + hours * 3600 + minutes * 60


def record_quota_banner(text, now=None, path=None):
    """Remember a banner so the pool stays blocked until its reset. Returns the pool or None."""
    now = time.time() if now is None else now
    parsed = parse_quota_banner(text, now)
    if not parsed:
        return None
    path = path or BANNER_FILE
    banners = read_banners(now, path)
    banners[parsed[0]] = parsed[1]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(banners, f)
    return parsed[0]


def read_banners(now, path=None):
    try:
        with open(path or BANNER_FILE) as f:
            data = json.load(f)
        return {pool: float(t) for pool, t in data.items() if pool in ("claude", "gemini-flash", "gemini-pro") and float(t) > now}
    except (OSError, ValueError, TypeError, AttributeError):
        return {}


def antigravity_models():
    """Model ids the Antigravity CLI lists, or None when it cannot say."""
    try:
        out = subprocess.run(["agy", "models"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    ids = {line.split()[0] for line in out.splitlines() if line.strip() and not line.startswith("Fetching")}
    return ids or None


READERS = {"codex": codex_reading, "claude": claude_reading, "cursor": cursor_reading,
           "antigravity": antigravity_reading}
DAY_START = {"codex": codex_day_start, "claude": claude_day_start}


def fresh(reading, now):
    """Accept only fresh, finite real provider readings within the current cycle."""
    try:
        t = epoch((reading or {}).get("observed_at"))
        pct = float(reading["pct"])
        resets = epoch(reading.get("resets_at"))
        if (t is not None and math.isfinite(t) and -5 <= now - t <= MAX_AGE
                and math.isfinite(pct) and 0 <= pct <= 100
                and (resets is None or resets > now)):
            return {**reading, "pct": pct, "resets_at": resets}
    except (TypeError, KeyError, ValueError):
        pass
    return None


def reading_source(provider, refresh=False):
    return {
        "codex": "codex app-server account/rateLimits/read" if refresh else CODEX + "/**/rollout-*.jsonl rate_limits",
        "claude": "https://api.anthropic.com/api/oauth/usage seven_day" if refresh else STATE + "/claude-rate-limits.json seven_day",
        "cursor": CURSOR_SUMMARY or CURSOR_URL,
        "antigravity": "local Antigravity LanguageServerService/GetUserStatus quotaInfo",
    }.get(provider, "no reader for " + provider)


def codex_refresh():
    """Read the authenticated account without starting a model turn or changing sessions."""
    import selectors
    process = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 5
    buffer = b""
    def send(message):
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()
    try:
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "usage_gate", "version": "1"}}})
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == 1:
                    if "error" in message:
                        return None
                    send({"method": "initialized"})
                    send({"id": 2, "method": "account/rateLimits/read"})
                elif message.get("id") == 2:
                    limits = message.get("result", {}).get("rateLimits", {})
                    for window in (limits.get("primary"), limits.get("secondary")):
                        if window and window.get("windowDurationMins") == WEEK_MIN:
                            return {"pct": float(window["usedPercent"]),
                                    "resets_at": window.get("resetsAt"), "observed_at": time.time()}
                    return None
        return None
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


def claude_refresh():
    """Use Claude's own OAuth credentials in memory; never log tokens or response bodies."""
    import urllib.request
    path = HOME + "/.claude/.credentials.json"
    if os.path.isfile(path):
        with open(path) as f:
            credentials = json.load(f)
    elif sys.platform == "darwin":
        result = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                capture_output=True, text=True, timeout=2, check=True)
        credentials = json.loads(result.stdout)
    else:
        return None
    token = credentials["claudeAiOauth"]["accessToken"]
    request = urllib.request.Request("https://api.anthropic.com/api/oauth/usage", headers={
        "Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"})
    with urllib.request.urlopen(request, timeout=5) as response:
        weekly = json.load(response)["seven_day"]
    return {"pct": float(weekly["utilization"]), "resets_at": epoch(weekly.get("resets_at")),
            "observed_at": time.time()}


def refresh_reading(provider):
    # Re-scan local provider output first: another session/statusline may have updated it.
    try:
        reading = READERS[provider]()
    except Exception:
        reading = None
    if fresh(reading, time.time()):
        return {**reading, "source": reading_source(provider)}
    if provider == "codex":
        return codex_refresh()
    if provider == "claude":
        return claude_refresh()
    return reading


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
    cap is advisory; None derives pacing from the day baseline and weekly reset."""
    if reading is None:
        return "unknown", {"reason": "no reading"}, state
    pct, resets = reading["pct"], reading.get("resets_at")
    if reading.get("stale") or (resets and float(resets) <= now):
        return "unknown", {"reason": "stale or expired reading"}, state
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
        detail["note"] = "pacing: prefer a lighter model"
    return "allowed", detail, st


def running_workers(provider):
    """Live running Dispatches, including retained/reused terminals, across every page."""
    try:
        count, cursor = 0, None
        while True:
            args = [ORCA, "orchestration", "worker-list", "--limit", "100", "--json"]
            if cursor:
                args += ["--cursor", cursor]
            response = subprocess.run(args, capture_output=True, text=True, timeout=5)
            result = json.loads(response.stdout)["result"]
            for worker in result["workers"]:
                projection = worker.get("projection") or {}
                # Older hosts may omit terminalState; their provider projection remains usable.
                if (worker.get("terminalState") not in ("released", "reclaimable")
                        and worker.get("dispatchStatus") not in ("completed", "failed", "cancelled", "abandoned")
                        and (projection.get("liveness") or {}).get("verdict") != "exited"
                        and (projection.get("provider") or {}).get("id") == provider):
                    count += 1
            page = result.get("page") or {}
            if not page.get("hasMore"):
                return count
            cursor = page["nextCursor"]
    except Exception:
        return None


def local(ts):
    return time.strftime("%a %d %b %H:%M %Z", time.localtime(float(ts))).strip() if ts else "unknown"


def next_midnight(now):
    return (datetime.fromtimestamp(now) + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0).timestamp()


def blocked_until(detail, now):
    """Only the provider's real reset ends a weekly/cycle ceiling block."""
    resets = detail.get("resets_at")
    return float(resets) if resets else None


def antigravity_result(pools, ceiling, now, model=None, pool=None, reserve=0.0, running=None):
    selected = pool or antigravity_pool(model or "gemini-3.8-flash")
    reading = pools.get(selected) if selected else None
    result = {"provider": "antigravity" + ("/" + pool if pool else ""),
              "verdict": "unknown", "reason": "no reading", "policy": "ceiling only",
              "source": reading_source("antigravity"), "reading_age_min": None}
    result["reading_age_min"] = ((now - epoch(reading["observed_at"])) / 60
                                  if reading and epoch(reading.get("observed_at")) is not None else None)
    if not fresh(reading, now):
        result["reason"] = "GetUserStatus returned no fresh valid pool quota"
        return result
    blocked = reading["pct"] + reserve >= ceiling
    result.update(verdict="blocked" if blocked else "allowed", weekly_used=reading["pct"],
                  ceiling=ceiling, reserve=reserve, running=running, resets_at=reading["resets_at"],
                  resets_local=local(reading["resets_at"]),
                  reading_age_min=round((now - epoch(reading["observed_at"])) / 60, 1))
    result.pop("reason")
    if blocked:
        result.update(reason="pool ceiling", blocked_until=reading["resets_at"],
                      blocked_until_local=local(reading["resets_at"]))
    return result


def run(provider, cap, ceiling, now=None, per_worker=1.0, model=None):
    live_clock = now is None
    now = time.time() if live_clock else now
    if provider == "antigravity":
        pools = READERS[provider]() or {}
        now = time.time() if live_clock else now
        running = running_workers(provider) if pools else None
        return antigravity_result(pools, ceiling, now, model=model,
                                  reserve=per_worker * (running or 0), running=running)
    today = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    midnight = local_midnight(now)
    path = f"{STATE}/{provider}.json"
    try:
        state = json.load(open(path))
    except (OSError, ValueError):
        state = None
    reader = READERS.get(provider)
    try:
        raw = reader() if reader else None
    except Exception:
        raw = None
    now = time.time() if live_clock else now
    previous = raw
    reading = fresh(raw, now)
    source = reading_source(provider)
    failure = "no fresh provider reading"
    if not reading and reader:
        try:
            raw = refresh_reading(provider)
            source = (raw or {}).get("source", reading_source(provider, refresh=True))
            now = time.time() if live_clock else now
            reading = fresh(raw, now)
            failure = "refresh returned no fresh valid usage reading"
        except Exception as exc:
            source = reading_source(provider, refresh=True)
            failure = "refresh failed: " + type(exc).__name__
    # Do not print exception text: provider responses can contain credentials.
    running = running_workers(provider) if reading else None
    reserve = round(per_worker * (running or 0), 1)
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
    detail["source"] = source
    t = epoch((raw or previous or {}).get("observed_at"))
    if not reading and previous:
        detail["last_reading_source"] = reading_source(provider)
    detail["reading_age_min"] = round((now - t) / 60, 1) if t is not None else None
    if not reading:
        detail["reason"] = ("no reliable Composer 2.5 allowance reading; read the Cursor dashboard"
                            if provider == "cursor" else failure)
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
    head = ("provider", "verdict", "week%", "today%", "cap%", "reserve%", "running", "reading", "source", "week resets", "next start")
    out = []
    for r in rows:
        if r["verdict"] == "unknown":
            note = "not gated" if r["provider"] in NOT_GATED else r.get("reason", "no reading")
            out.append((r["provider"], "unknown", "-", "-", "-", "-", "-", ("age unknown" if r.get("reading_age_min") is None else f"{r['reading_age_min']}m ago") + ": " + note, r.get("source", "unknown"), "-", "-"))
            continue
        age = r.get("reading_age_min")
        out.append((r["provider"], r["verdict"], f"{r['weekly_used']:g}",
                    *(f"{r[k]:g}" if k in r else "?" for k in ("today_used", "cap", "reserve")),
                    "?" if r.get("running") is None else str(r["running"]),
                    "?" if age is None else f"{age}m ago", r.get("source", "unknown"), r.get("resets_local", "-"),
                    f"{r['blocked_until_local']} ({r['reason']})" if r["verdict"] == "blocked" else r.get("note", "now")))
    widths = [max(len(str(x[i])) for x in [head] + out) for i in range(len(head))]
    lines = ["  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip() for row in [head] + out]
    lines.append("cap% is a pacing hint only; only fresh real usage + reserve% reaching the weekly/cycle ceiling blocks.")
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
    """Remaining real weekly/cycle headroom; daily pacing never ranks out a provider."""
    if row.get("verdict") == "unknown" or "weekly_used" not in row:
        return None, None
    room = row["ceiling"] - row["weekly_used"] - row.get("reserve", 0)
    return room, room / row["ceiling"] if row["ceiling"] > 0 else 0.0


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
    known = antigravity_models() if any(e["provider"] == "antigravity" for e in chain) else None
    gated = [r for (p, _), r in rows.items() if p in READERS]
    fallback = all(r["verdict"] == "blocked" for r in gated)
    candidates, allowed = [], []
    for index, entry in enumerate(chain):
        row = rows[(entry["provider"], entry["model"] if entry["provider"] == "antigravity" else None)]
        room, fraction = headroom(row)
        eligible = row["verdict"] == "allowed" if entry["provider"] in READERS else fallback
        excluded = avoid is not None and family(entry) == avoid
        if entry["provider"] == "antigravity" and known is not None and entry["model"] not in known:
            eligible, row = False, {**row, "verdict": "model not recognized"}
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
            best = max(allowed, key=lambda pair: pair[1]["headroom_fraction"]
                       if pair[1]["headroom_fraction"] is not None else -1)[1]
            first = allowed[0][1]
            # Near equal headroom keeps the role's preset provider so readings that wobble
            # by a point do not flip the pick; switch only when clearly lower (over 2 points).
            near = (first["headroom"] is None or best["headroom"] is None
                    or best["headroom"] - first["headroom"] <= TIE_POINTS)
            chosen = first if allowed[0][0] == 0 and near else best
    resets = [r["blocked_until"] for r in rows.values() if r.get("blocked_until")]
    until = min(resets) if resets else None
    return {"role": role, "selected": chosen, "candidates": candidates,
            "blocked_until": until, "blocked_until_local": local(until)}


def candidate_reason(candidate):
    fraction = candidate["headroom_fraction"]
    room = candidate["headroom"]
    detail = "headroom unknown" if room is None else f"headroom {room:g}% ({fraction * 100:.1f}% of ceiling)"
    note = "excluded family" if candidate["excluded_family"] else candidate["verdict"]
    return f"{candidate['provider']} {candidate['model']}: {detail}, {note}"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "show", "pick", "banner"])
    ap.add_argument("--provider")
    ap.add_argument("--model", help="Antigravity model id; omitted selects the worst pool")
    ap.add_argument("--role")
    ap.add_argument("--avoid-family", choices=["claude", "gpt"])
    ap.add_argument("--cap", type=float, default=None,
                    help="advisory daily pacing hint; never blocks")
    ap.add_argument("--ceiling", type=float, default=95.0)
    ap.add_argument("--reserve", type=float, default=1.0,
                    help="weekly percent held back per worker already running on the provider")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "banner":
        pool = record_quota_banner(sys.stdin.read())
        print(pool or "no quota banner found")
        return 0 if pool else 1
    if a.cmd == "pick":
        if not a.role:
            ap.error("pick requires --role")
        try:
            result = pick(a.role, a.avoid_family, a.cap, a.ceiling, a.reserve)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"cannot read role presets: {type(exc).__name__}", file=sys.stderr)
            return 4
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
        return 0 if result["selected"] else (3 if all(c["verdict"] == "blocked" for c in result["candidates"]) else 4)
    names = [a.provider] if a.provider else list(READERS)
    if a.cmd == "show" and not a.provider:
        names += list(NOT_GATED)
    out = []
    for name in names:
        if name == "antigravity" and a.cmd == "show":
            pools = READERS[name]() or {}
            running = running_workers(name) if pools else None
            out.extend(antigravity_result(pools, a.ceiling, time.time(), pool=pool,
                                         reserve=a.reserve * (running or 0), running=running)
                       for pool in ("claude", "gemini-flash", "gemini-pro"))
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
