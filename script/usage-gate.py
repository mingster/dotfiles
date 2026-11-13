#!/usr/bin/env python3
"""Provider usage gate: only real usage readings plus a running worker reserve can block.

Ceilings, reserve weights and the missing reading rule live in usage-gate.config.json
(USAGE_GATE_CONFIG overrides the path); check, pick and fleet-watch all read that one file.
check --provider NAME exits 0 allowed, 3 ceiling reached (or daily cap, automatic starts only),
4 unknown. A missing reading falls back to the last good one when it is under 2 hours old and at
least 10 points under the ceiling (allowed with a note); otherwise it is unknown and blocks.
Antigravity with no reading is allowed in check and pick alike (owner 2026-11-12, 2026-11-13);
the worker stops at its first quota or sign-in error.
--auto marks an automatic start (fleet-watch issue scan and babysit pass it). Only an
automatic start is blocked by the daily cap; manual and coordinator starts never are, they
get the note "pacing: prefer a lighter model".
show [--json] includes the exact source and reading age; pick --role ROLE retains
its existing flags. fullstack-dev and light-tier roles take the first allowed of
Cursor grok-4.7-xhigh, then that role's Claude entry, then Antigravity. Strong
roles never select Cursor. Every other role ranks by headroom per day left until the
provider's reset, so quota about to reset is spent first.
Claude reads statusline seven_day and refreshes via the authenticated OAuth usage
endpoint; Cursor reads included usage from GetCurrentPeriodUsage, which names
every model that percent covers, and falls back to the usage-summary meter only
when that reading is missing; Antigravity queries local GetUserStatus,
defaulting to the Gemini Flash pool.
Missing, stale (>15 minutes), expired, invalid or future readings trigger a refresh.
If the real source cannot supply a fresh reading, never infer zero usage or a stale
ceiling verdict. The reserve holds weekly percentage points per running worker (strong
models 2, others 1; --reserve N sets a flat value); --ceiling N overrides every
provider's configured ceiling. Cursor uses its provider billing cycle when verifiable;
Antigravity uses separate Flash, Pro/Argon and Claude provider model pools.
"""
import argparse, re, json, math, os, shutil, subprocess, sys, tempfile, time
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
STATE = os.environ.get("USAGE_GATE_STATE", HOME + "/.claude/state/usage-gate")
WEEK_MIN = 10080
TIE_POINTS = 2.0  # headroom points per day within which the preset provider keeps the pick
MAX_AGE = 15 * 60  # seconds; an older reading is no reading
STATE_VERSION = 2  # a state file written before the day baseline rules below is recomputed
MIN_DAYS = 0.25  # floor on days left, so a reset minutes away does not rank infinitely high
ORCA = os.environ.get("USAGE_GATE_ORCA", "orca")
NOT_GATED = ()
CONFIG = os.environ.get("USAGE_GATE_CONFIG", os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-gate.config.json"))
LAUNCHES = os.environ.get("WORKER_STARTUP_STATE", HOME + "/.local/state/worker-startup") + "/launches"
CURSOR_URL = "https://cursor.com/api/usage-summary"
CURSOR_PERIOD_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
CURSOR_SUMMARY = os.environ.get("USAGE_GATE_CURSOR_SUMMARY")  # a summary JSON file instead of the network (tests)
CURSOR_BUILD_MODEL = "grok-4.7-xhigh"
CURSOR_URGENT_MODEL = "grok-4.7-xhigh-fast"
CURSOR_REVIEW_MODEL = "grok-4.7-high"
CURSOR_MODELS = (CURSOR_BUILD_MODEL, CURSOR_URGENT_MODEL, CURSOR_REVIEW_MODEL)
STRONG_NO_CURSOR = ("elon", "architect-pm", "secops-finops", "qa-sdet")


def load_config():
    """The committed gate config. fleet-watch reads the notice settings from the same file."""
    with open(CONFIG) as f:
        return json.load(f)


def ceiling_for(provider):
    config = load_config()
    return float(config["ceilings"].get(provider, config["default_ceiling"]))


def epoch(at):
    """Epoch seconds from epoch seconds (claude) or an ISO timestamp; None if unreadable."""
    try:
        return float(at)
    except (TypeError, ValueError):
        try:
            return datetime.fromisoformat(str(at).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None


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


def _usage_epoch(at):
    """Epoch seconds from an ISO timestamp, epoch seconds, or unix milliseconds."""
    value = epoch(at)
    if value is not None and value > 10_000_000_000:
        return value / 1000.0
    return value


def _percent_used(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number) or not 0 <= number <= 100:
        return None
    return number


def cursor_parse(summary, now):
    """Included-usage percent for every model named in autoBucketModels.

    GetCurrentPeriodUsage puts that percent on planUsage and lists the models it
    covers, including Composer and the Grok models a worker can start. The
    usage-summary meter individualUsage.plan.autoPercentUsed is a different number:
    on a weekly included plan it stays 0 while those models run, so it never
    overrides a period reading. Without autoBucketModels, fall back to that
    usage-summary percent. A model absent from autoBucketModels is not measured.
    Missing usage stays unknown, never an inferred zero.
    """
    if not isinstance(summary, dict):
        return None
    reset = _usage_epoch(summary.get("billingCycleEnd"))
    began = _usage_epoch(summary.get("billingCycleStart"))
    models = summary.get("autoBucketModels")
    plan_usage = summary.get("planUsage") if isinstance(summary.get("planUsage"), dict) else None
    if isinstance(models, list) and plan_usage and summary.get("enabled") is not False:
        names = [model for model in models if isinstance(model, str) and model]
        pct = _percent_used(plan_usage.get("autoPercentUsed"))
        if pct is None:
            pct = _percent_used(plan_usage.get("totalPercentUsed"))
        if names and pct is not None and reset is not None:
            reading = {"pct": pct, "resets_at": reset, "observed_at": now, "models": names}
            if began is not None:
                reading["began_at"] = began
            return fresh(reading, now)
        if names:
            return None
    try:
        plan = summary["individualUsage"]["plan"]
        pct = _percent_used(plan.get("autoPercentUsed"))
        if plan.get("enabled") is False or pct is None or reset is None:
            return None
        return fresh({"pct": pct, "resets_at": reset, "observed_at": now}, now)
    except (KeyError, TypeError, AttributeError):
        return None


def cursor_tokens():
    """Read desktop state and installed cursor-agent credential stores without writes.

    The CLI uses macOS keychain service cursor-access-token/account cursor-user;
    its file store uses .cursor/auth.json on macOS or XDG_CONFIG_HOME/cursor/auth.json
    on Linux (default ~/.config), with the accessToken key. Never log these values.
    """
    import sqlite3
    db = (HOME + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
          if sys.platform == "darwin" else HOME + "/.config/Cursor/User/globalStorage/state.vscdb")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute("select value from ItemTable where key='cursorAuth/accessToken'").fetchone()
        finally:
            con.close()
        if row:
            yield row[0]
    except (OSError, sqlite3.Error):
        pass
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["security", "find-generic-password", "-a", "cursor-user",
                                     "-s", "cursor-access-token", "-w"], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, timeout=3)
            if result.returncode == 0:
                yield result.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
    auth = (HOME + "/.cursor/auth.json" if sys.platform == "darwin" else
            os.path.join(os.environ.get("XDG_CONFIG_HOME") or HOME + "/.config", "cursor/auth.json"))
    try:
        with open(auth) as f:
            yield json.load(f).get("accessToken")
    except (OSError, ValueError, AttributeError):
        pass


def cursor_reading(path=None):
    """Read-only; tokens and the dashboard cookie stay in memory, never in logs or argv."""
    path = path or CURSOR_SUMMARY
    try:
        if path:
            return cursor_parse(json.load(open(path)), time.time())
        import base64, urllib.error, urllib.parse, urllib.request
        now = time.time()
        for token in cursor_tokens():
            # Opaque desktop tokens cannot supply the dashboard user id. Try the CLI
            # store instead; never guess a user id or send an invented credential.
            try:
                if not isinstance(token, str) or len(token.split(".")) != 3:
                    continue
                user = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==="))["sub"].split("|")[-1]
                if not user:
                    continue
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            # Included usage names every covered model. A 401/403 is a dead token;
            # try the next store before the usage-summary meter, which can read 0
            # while those models are running.
            try:
                request = urllib.request.Request(
                    CURSOR_PERIOD_URL, data=b"{}", method="POST",
                    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                             "Connect-Protocol-Version": "1"})
                with urllib.request.urlopen(request, timeout=8) as response:
                    reading = cursor_parse(json.load(response), now)
                if reading:
                    reading["source"] = CURSOR_PERIOD_URL
                    return reading
            except urllib.error.HTTPError as error:
                if error.code in (401, 403):
                    continue
            except (OSError, ValueError, TypeError):
                pass
            cookie = "WorkosCursorSessionToken=" + urllib.parse.quote(f"{user}::{token}", safe="")
            try:
                with urllib.request.urlopen(urllib.request.Request(
                        CURSOR_URL, headers={"Cookie": cookie}), timeout=8) as response:
                    reading = cursor_parse(json.load(response), now)
                if reading:
                    reading["source"] = CURSOR_URL
                    return reading
            except urllib.error.HTTPError as error:
                if error.code in (401, 403):
                    continue
                raise
    except Exception:
        return None


def _tool_bin(name, fallback):
    """Resolve a tool that a minimal automation PATH does not include."""
    found = shutil.which(name)
    if found:
        return found
    if fallback and os.access(fallback, os.X_OK):
        return fallback
    return name


def antigravity_fetch():
    """Read local quota without persisting or displaying the server's CSRF token."""
    import re, ssl, urllib.request
    deadline = time.monotonic() + 7
    lsof = _tool_bin("lsof", "/usr/sbin/lsof")
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
            ports = subprocess.run([lsof, "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p",
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


# Always the wrapper: it unsets the SSH variables so agy reads the keychain, not the empty file store.
AGY_WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "agy")


def antigravity_models():
    """Model ids the Antigravity CLI lists, or None when it cannot say."""
    try:
        out = subprocess.run([AGY_WRAPPER, "models"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    ids = {line.split()[0] for line in out.splitlines() if line.strip() and not line.startswith("Fetching")}
    return ids or None


READERS = {"claude": claude_reading, "cursor": cursor_reading, "antigravity": antigravity_reading}
DAY_START = {"claude": claude_day_start}


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
        "claude": "https://api.anthropic.com/api/oauth/usage seven_day" if refresh else STATE + "/claude-rate-limits.json seven_day",
        "cursor": CURSOR_SUMMARY or CURSOR_PERIOD_URL,
        "antigravity": "local Antigravity LanguageServerService/GetUserStatus quotaInfo",
    }.get(provider, "no reader for " + provider)


def claude_credentials():
    path = HOME + "/.claude/.credentials.json"
    credentials = None
    if os.path.isfile(path):
        with open(path) as f:
            credentials = json.load(f)
    expires_at = credentials["claudeAiOauth"].get("expiresAt") if credentials else None
    if sys.platform == "darwin" and (credentials is None or (expires_at and expires_at / 1000 < time.time())):
        result = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                capture_output=True, text=True, timeout=2, check=True)
        credentials = json.loads(result.stdout)
    return credentials


def claude_refresh():
    """Use Claude's own OAuth credentials in memory; never log tokens or response bodies."""
    import urllib.request
    credentials = claude_credentials()
    if credentials is None:
        return None
    # The access token lasts hours and renews only when Claude runs. An idle host (no
    # keychain to fall back on) holds an expired one, and the usage call answers 401.
    expires_at = credentials["claudeAiOauth"].get("expiresAt")
    if expires_at and expires_at / 1000 < time.time():
        renew_claude_token()
        credentials = claude_credentials()
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
    if provider == "claude":
        return claude_refresh()
    return reading


def renew_claude_token():
    """The token renews only when Claude runs, so one minimal prompt keeps an idle host readable."""
    expires_at = (claude_credentials() or {}).get("claudeAiOauth", {}).get("expiresAt")
    if expires_at and expires_at / 1000 - time.time() < 3600:
        subprocess.run(["claude", "-p", "ok", "--model", "haiku"], capture_output=True, timeout=120)


def publish(hosts):
    """Copy the Claude reading, numbers only, to hosts that cannot read it themselves."""
    try:
        renew_claude_token()
        reading = fresh(refresh_reading("claude"), time.time())
    except Exception as error:
        print(f"publish: no reading: {type(error).__name__}", file=sys.stderr)
        return 4
    if not reading:
        print("publish: no fresh reading", file=sys.stderr)
        return 4
    body = {"_written_at": int(reading["observed_at"]),
            "seven_day": {"used_percentage": reading["pct"], "resets_at": reading["resets_at"]}}
    code = 0
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump(body, f)
        f.flush()
        for host in hosts:
            if subprocess.run(["scp", "-q", "-o", "ConnectTimeout=10", f.name,
                               host + ":.claude/state/usage-gate/claude-rate-limits.json"],
                              capture_output=True, timeout=30).returncode:
                print(f"publish: copy to {host} failed", file=sys.stderr)
                code = 1
    return code


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


def decide(reading, state, today, now, cap, ceiling, reserve=0.0, day_start=None, auto=False):
    """Return (verdict, detail, new_state). verdict: allowed|blocked|unknown.
    reserve is weekly percent held back for workers already running.
    cap is the daily pacing line; None derives it from the day baseline and weekly reset.
    Past the cap an automatic start (auto) is blocked until midnight; any other start gets a note."""
    if reading is None:
        return "unknown", {"reason": "no reading"}, state
    pct, resets = reading["pct"], reading.get("resets_at")
    if reading.get("stale") or (resets and float(resets) <= now):
        return "unknown", {"reason": "stale or expired reading"}, state
    st = dict(state or {})
    old = st.get("resets_at")
    # resets_at can jitter by a few seconds between events; only a jump of an hour is a new week
    moved = (old is None) != (resets is None) or (old is not None and abs(float(resets) - float(old)) >= 3600)
    rolled = moved or pct < st.get("baseline", 0)
    # A cycle that began before today and "rolled" mid day is a moved reset, not a fresh cycle,
    # so it is not a zero baseline (Cursor read "100% today" from such a fake zero).
    began = reading.get("began_at")
    zero_on_roll = began is None or float(began) >= local_midnight(now)
    if st.get("date") != today or "baseline" not in st or st.get("v") != STATE_VERSION or rolled:
        st = {"v": STATE_VERSION, "date": today,
              "baseline": 0.0 if rolled and st.get("date") == today and zero_on_roll
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
        if auto:
            detail["reason"] = "daily cap"
            return "blocked", detail, st
        detail["note"] = "pacing: prefer a lighter model"
    return "allowed", detail, st


def orca_pages(*command):
    """Yield the result of every page of an orca list command, following nextCursor.

    Current Orca puts nextCursor at the top level and omits it on the last page; older Orca nested it under page
    with hasMore. A page that cannot prove it is the last, or a repeated cursor, raises.
    """
    cursor, seen = None, set()
    while True:
        args = [ORCA, "orchestration", *command, "--limit", "100", "--json"]
        if cursor:
            args += ["--cursor", cursor]
        response = subprocess.run(args, capture_output=True, text=True, timeout=5)
        receipt = json.loads(response.stdout)
        if receipt.get("ok") is False:
            raise RuntimeError("orca refused the list")
        result = receipt["result"]
        yield result
        if "page" in result:
            if result["page"]["hasMore"] is not True:
                if result["page"]["hasMore"] is not False:
                    raise ValueError("bad page")
                return
            cursor = result["page"]["nextCursor"]
        elif result.get("nextCursor") is not None:
            cursor = result["nextCursor"]
        else:
            return
        if not isinstance(cursor, str) or not cursor or cursor in seen:
            raise ValueError("bad cursor")
        seen.add(cursor)


FINAL_STATES = ("completed", "failed", "cancelled", "abandoned", "succeeded")


def live_workers(provider):
    """Live worker rows on provider in every Run and on every page; None when any Run or page cannot be read.

    worker-list without --run shows only the caller's Run. Today's rows carry agent, liveness, state and
    terminalState at the top level; older Orca nested provider and liveness under projection.
    """
    try:
        run_ids = [run["id"] for page in orca_pages("run-list") for run in page["runs"]]
        live = []
        for run_id in run_ids:
            for result in orca_pages("worker-list", "--run", run_id):
                for worker in result["workers"]:
                    projection = worker.get("projection") or {}
                    agent = worker.get("agent") or (projection.get("provider") or {}).get("id")
                    liveness = worker.get("liveness") or (projection.get("liveness") or {}).get("verdict")
                    if (agent == provider and liveness != "exited"
                            and worker.get("terminalState") not in ("released", "reclaimable")
                            and worker.get("dispatchStatus") not in FINAL_STATES
                            and worker.get("state") not in FINAL_STATES):
                        live.append(worker)
        return live
    except Exception:
        return None


def running_workers(provider):
    workers = live_workers(provider)
    return None if workers is None else len(workers)


def worker_weight(worker):
    """Reserve points for one running worker: strong models hold more than the rest."""
    config = load_config()
    model = ((worker.get("projection") or {}).get("provider") or {}).get("model") or worker.get("model")
    dispatch = worker.get("dispatchId")
    if not model and isinstance(dispatch, str) and re.fullmatch(r"[A-Za-z0-9_-]+", dispatch):
        try:
            with open(f"{LAUNCHES}/{dispatch}.json") as f:
                model = json.load(f).get("model")
        except (OSError, ValueError, AttributeError):
            pass
    strong = isinstance(model, str) and any(tag in model.lower() for tag in config["strong_models"])
    return float(config["reserve_points"]["strong" if strong else "other"])


def running_reserve(provider, per_worker=None):
    """(running workers, reserve points) for a provider. per_worker, when given, is a flat weight."""
    if per_worker is not None:
        running = running_workers(provider)
        return running, per_worker * (running or 0)
    workers = live_workers(provider)
    if workers is None:
        return None, 0.0
    return len(workers), sum(worker_weight(w) for w in workers)


def local(ts):
    return time.strftime("%a %d %b %H:%M %Z", time.localtime(float(ts))).strip() if ts else "unknown"


def next_midnight(now):
    return (datetime.fromtimestamp(now) + timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0).timestamp()


def blocked_until(detail, now):
    """The provider's real reset ends a weekly/cycle ceiling block; midnight ends a daily cap block."""
    if detail.get("reason") == "daily cap":
        return next_midnight(now)
    resets = detail.get("resets_at")
    return float(resets) if resets else None


def save_last_good(provider, reading):
    """Keep the newest fresh reading (numbers only) so a later outage can fall back on it."""
    path = f"{STATE}/{provider}.last-good.json"
    keep = {k: reading.get(k) for k in ("pct", "resets_at", "observed_at", "began_at")}
    try:
        with open(path) as f:
            if json.load(f).get("observed_at") == keep["observed_at"]:
                return
    except (OSError, ValueError, AttributeError):
        pass
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(path, "w") as f:
            json.dump(keep, f)
    except OSError:
        pass


def last_good(provider, now, ceiling):
    """(reading, age minutes, usable). usable: under the config age limit and the margin under the ceiling."""
    try:
        with open(f"{STATE}/{provider}.last-good.json") as f:
            old = json.load(f)
        t, pct = epoch(old["observed_at"]), float(old["pct"])
        resets = epoch(old.get("resets_at"))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None, None, False
    if t is None or not math.isfinite(pct) or not 0 <= now - t:
        return None, None, False
    config = load_config()
    age = round((now - t) / 60, 1)
    usable = (now - t < config["last_good_max_age_min"] * 60 and (resets is None or resets > now)
              and ceiling - pct >= config["last_good_margin_points"])
    return {**old, "pct": pct, "resets_at": resets}, age, usable


def antigravity_result(pools, ceiling, now, model=None, pool=None, reserve=0.0, running=None):
    selected = pool or antigravity_pool(model or "gemini-3.8-flash")
    reading = pools.get(selected) if selected else None
    result = {"provider": "antigravity" + ("/" + pool if pool else ""),
              "verdict": "unknown", "reason": "no reading", "policy": "ceiling only",
              "source": reading_source("antigravity"), "reading_age_min": None}
    result["reading_age_min"] = ((now - epoch(reading["observed_at"])) / 60
                                  if reading and epoch(reading.get("observed_at")) is not None else None)
    if not fresh(reading, now):
        # Owner 2026-11-12 and 2026-11-13: no reading starts anyway, in check and pick alike.
        result.update(verdict="allowed", blind=True, reason="GetUserStatus returned no fresh valid pool quota",
                      note="no quota reading: starting anyway, stop at the first quota or sign-in error")
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


def run(provider, cap, ceiling, now=None, per_worker=None, model=None, auto=False):
    live_clock = now is None
    now = time.time() if live_clock else now
    if ceiling is None:
        ceiling = ceiling_for(provider)
    if provider == "antigravity":
        pools = READERS[provider]() or {}
        now = time.time() if live_clock else now
        running, points = running_reserve(provider, per_worker) if pools else (None, 0.0)
        return antigravity_result(pools, ceiling, now, model=model, reserve=points, running=running)
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
    source = (raw or {}).get("source") or reading_source(provider)
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
    carried, carried_age, carried_ok = (None, None, False)
    if reading:
        save_last_good(provider, reading)
    elif reader:
        carried, carried_age, carried_ok = last_good(provider, now, ceiling)
    basis = reading or (carried if carried_ok else None)
    running, points = running_reserve(provider, per_worker) if basis else (None, 0.0)
    reserve = round(points, 1)
    day_start = None
    if reading and ((state or {}).get("date") != today or (state or {}).get("v") != STATE_VERSION):
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
    verdict, detail, new = decide(basis, state, today, now, cap, ceiling, reserve, day_start, auto)
    if new is not state and new:
        os.makedirs(STATE, exist_ok=True)
        json.dump(new, open(path, "w"))
    detail["source"] = source
    t = epoch((raw or previous or {}).get("observed_at"))
    if not reading and previous:
        detail["last_reading_source"] = reading_source(provider)
    detail["reading_age_min"] = round((now - t) / 60, 1) if t is not None else None
    if not basis:
        detail["reason"] = ("no reliable Cursor included-usage reading; read the Cursor dashboard"
                            if provider == "cursor" else failure)
        if carried:
            detail["last_good_pct"] = carried["pct"]
            detail["headroom"] = round(max(ceiling - carried["pct"], 0.0), 1)
            detail["reason"] += (f"; last good reading {carried_age:g}m old, "
                                 f"{ceiling - carried['pct']:g} points under the ceiling")
    if not reading and carried_ok:
        stale = f"no fresh reading: using the last good one from {carried_age:g}m ago"
        detail["note"] = "; ".join(filter(None, (stale, detail.get("note"))))
        detail["carried"] = True
    if basis:
        t = epoch(basis.get("observed_at"))
        detail["reading_age_min"] = (round((now - t) / 60, 1) if carried_ok else round((now - t) / 60)) if t is not None else None
        detail["running"] = running
        detail["headroom"] = round(max(ceiling - basis["pct"] - reserve, 0.0), 1)
        detail["resets_local"] = local(detail.get("resets_at"))
        if verdict == "blocked":
            until = blocked_until(detail, now)
            detail["blocked_until"], detail["blocked_until_local"] = until, local(until)
    result = {"provider": provider, "verdict": verdict, **detail}
    measured = (reading or {}).get("models")
    unmeasured = (provider == "cursor" and model and result["verdict"] == "allowed"
                  and (model not in CURSOR_MODELS or (measured is not None and model not in measured)))
    if unmeasured:
        result = {"provider": "cursor", "verdict": "unknown",
                  "reason": ("Cursor included usage does not measure model "
                             + model + "; read the Cursor dashboard"),
                  "source": result.get("source"), "reading_age_min": result.get("reading_age_min")}
    return result


def table(rows):
    head = ("provider", "verdict", "week%", "today%", "cap%", "reserve%", "running", "reading", "source", "week resets", "next start")
    out = []
    for r in rows:
        name = "cursor included" if r["provider"] == "cursor" else r["provider"]
        if r["verdict"] == "unknown" or r.get("blind"):
            note = "not gated" if r["provider"] in NOT_GATED else r.get("reason", "no reading")
            out.append((name, "allowed (no reading)" if r.get("blind") else "unknown", "-", "-", "-", "-", "-", ("age unknown" if r.get("reading_age_min") is None else f"{r['reading_age_min']}m ago") + ": " + note, r.get("source", "unknown"), "-", "-"))
            continue
        age = r.get("reading_age_min")
        out.append((name, r["verdict"], f"{r['weekly_used']:g}",
                    *(f"{r[k]:g}" if k in r else "?" for k in ("today_used", "cap", "reserve")),
                    "?" if r.get("running") is None else str(r["running"]),
                    "?" if age is None else f"{age}m ago", r.get("source", "unknown"), r.get("resets_local", "-"),
                    f"{r['blocked_until_local']} ({r['reason']})" if r["verdict"] == "blocked" else r.get("note", "now")))
    widths = [max(len(str(x[i])) for x in [head] + out) for i in range(len(head))]
    lines = ["  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip() for row in [head] + out]
    lines.append("cap% blocks automatic starts only (fleet-watch); other starts get a pacing note. "
                 "The ceiling plus reserve% blocks every start.")
    now = time.time()
    ordered = sorted(rows, key=lambda r: pace(r, now) if pace(r, now) is not None else -float("inf"),
                     reverse=True)
    order = []
    for row in ordered:
        score = pace(row, now)
        note = f"{score:.1f} pts/day" if score is not None else (
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
    room = max(row["ceiling"] - row["weekly_used"] - row.get("reserve", 0), 0.0)
    return room, room / row["ceiling"] if row["ceiling"] > 0 else 0.0


def pace(row, now):
    """Headroom points per day left until the provider's reset: quota about to reset is spent first."""
    room = headroom(row)[0]
    if room is None:
        return None
    resets = row.get("resets_at")
    days = max((float(resets) - now) / 86400, MIN_DAYS) if resets else 7.0
    return room / days


def link_presets():
    """Keep ~/.orca/presets.json a link to dotfiles, so a worker start never reads a drifted copy."""
    src, dest = HOME + "/dotfiles/.orca/presets.json", HOME + "/.orca/presets.json"
    if "USAGE_GATE_PRESETS" in os.environ or not os.path.exists(src):
        return
    if os.path.islink(dest) and os.readlink(dest) == src:
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest):
        shutil.copy2(dest, dest + ".bak-" + datetime.now().strftime("%Y%m%d%H%M%S"))
    tmp = dest + ".tmp-" + str(os.getpid())
    os.symlink(src, tmp)
    os.replace(tmp, dest)


def project_presets_path(cwd=None):
    env_path = os.environ.get("USAGE_GATE_PROJECT_PRESETS")
    if env_path is not None:
        return env_path if env_path and os.path.isfile(env_path) else None
    try:
        cur = os.path.abspath(cwd or os.getcwd())
    except OSError:
        return None
    while True:
        candidate = os.path.join(cur, ".orca", "presets.project.json")
        if os.path.isfile(candidate):
            return candidate
        if os.path.exists(os.path.join(cur, ".git")):
            return None
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def _merge_role_entry(base_entry, override_entry):
    if not isinstance(override_entry, dict):
        return override_entry
    base = dict(base_entry) if isinstance(base_entry, dict) else {}
    merged = {**base, **override_entry}
    if "chain" not in override_entry and "provider" in override_entry and "model" in override_entry:
        pin_item = {k: override_entry[k] for k in ("provider", "model", "effort") if k in override_entry}
        existing_chain = [c for c in base.get("chain", []) if isinstance(c, dict) and c != pin_item]
        merged["chain"] = [pin_item] + existing_chain
        merged.setdefault("pin", True)
    return merged


def load_presets(cwd=None):
    path = os.environ.get("USAGE_GATE_PRESETS", HOME + "/.orca/presets.json")
    with open(path) as f:
        presets = json.load(f)
    proj_path = project_presets_path(cwd=cwd)
    if proj_path:
        with open(proj_path) as f:
            proj = json.load(f)
        if isinstance(proj, dict):
            merged_roles = dict(presets.get("roles", {}))
            proj_roles = proj.get("roles") if isinstance(proj.get("roles"), dict) else {
                k: v for k, v in proj.items() if isinstance(v, dict) and k not in ("tiers",)
            }
            for rname, rval in proj_roles.items():
                merged_roles[rname] = _merge_role_entry(merged_roles.get(rname), rval)
            presets = {**presets, **{k: v for k, v in proj.items() if k != "roles"}, "roles": merged_roles}
    return presets


def role_chain(role):
    presets = load_presets()
    roles = presets.get("roles", {})
    if role == "reviewer" and "reviewer" not in roles:
        role = "qa-sdet"
    entry = roles.get(role, {})
    if "chain" in entry:
        return entry["chain"], entry.get("pin", False)
    # Unknown roles use workhorse models from this file, never hardcoded ids.
    tier = entry.get("tier", "workhorse")
    models = {p: [m] for p, m in presets.get("tiers", {}).get(tier, {}).items()}
    seen = set()
    for r in presets.get("roles", {}).values():
        if r.get("tier") == tier:
            for candidate in r.get("chain", []):
                key = (candidate["provider"], family(candidate))
                if key not in seen:
                    seen.add(key)
                    models.setdefault(candidate["provider"], []).append(candidate)
    chain = []
    for provider in presets.get("default_chain", []):
        if isinstance(provider, dict):
            chain.append(provider)
        elif provider in models:
            chain.extend({**m, "provider": provider} for m in models[provider])
        else:
            raise ValueError(f"no {tier} model for {provider} in presets")
    return chain, entry.get("pin", False)


def is_builder_role(role):
    """Implementation and light units start on Cursor when that provider is allowed."""
    if role == "fullstack-dev":
        return True
    presets = load_presets()
    roles = presets.get("roles", {})
    lookup = "qa-sdet" if role == "reviewer" and "reviewer" not in roles else role
    entry = roles.get(lookup, {})
    return isinstance(entry, dict) and entry.get("tier") == "light"


def order_builder_chain(chain):
    """Cursor grok-4.7-xhigh, then Claude, then Antigravity, whatever the preset text says."""
    cursor = [entry for entry in chain
              if entry.get("provider") == "cursor" and entry.get("model") == CURSOR_BUILD_MODEL]
    if not cursor:
        cursor = [{"provider": "cursor", "model": CURSOR_BUILD_MODEL}]
    claude = [entry for entry in chain if entry.get("provider") == "claude"]
    antigravity = [entry for entry in chain if entry.get("provider") == "antigravity"]
    return [*cursor[:1], *claude, *antigravity]


def family(entry):
    provider, model = entry["provider"], entry["model"]
    if provider == "claude" or (provider in ("antigravity", "cursor") and model.startswith("claude-")):
        return "claude"
    if model.startswith("gpt-"):
        return "gpt"
    if provider == "cursor" and model.startswith("composer"):
        return "composer"
    if provider == "cursor" and model.startswith("grok"):
        return "grok"
    if provider in ("antigravity", "cursor") and model.startswith("gemini-"):
        return "gemini"
    return None


def _gated_model(entry):
    """Antigravity and Cursor readings are per model; other providers share one pool."""
    if entry["provider"] in ("antigravity", "cursor"):
        return entry["model"]
    return None


def pick(role, avoid, cap, ceiling, per_worker, avoid_provider=None, auto=False):
    chain, pinned = role_chain(role)
    builder = is_builder_role(role)
    if builder:
        chain = order_builder_chain(chain)
    rows = {}
    for entry in chain:
        key = (entry["provider"], _gated_model(entry))
        if key not in rows:
            rows[key] = run(entry["provider"], cap, ceiling, per_worker=per_worker, model=key[1], auto=auto)
    known = antigravity_models() if any(e["provider"] == "antigravity" for e in chain) else None
    gated = [r for (p, _), r in rows.items() if p in READERS]
    fallback = all(r["verdict"] == "blocked" for r in gated)
    candidates, allowed = [], []
    now = time.time()
    for index, entry in enumerate(chain):
        row = rows[(entry["provider"], _gated_model(entry))]
        room, fraction = headroom(row)
        eligible = row["verdict"] == "allowed" if entry["provider"] in READERS else fallback
        excluded = avoid is not None and family(entry) == avoid
        if avoid == "grok" and family(entry) != "claude":
            excluded = True  # Claude always reviews Grok authored work (owner 2026-11-09)
        excluded_provider = entry["provider"] == avoid_provider
        if entry["provider"] == "cursor" and entry["model"] not in CURSOR_MODELS:
            eligible, row = False, {**row, "verdict": "cursor runs only grok-4.7-xhigh, grok-4.7-xhigh-fast and grok-4.7-high"}
        if role in STRONG_NO_CURSOR and entry["provider"] == "cursor":
            eligible, row = False, {**row, "verdict": "strong roles never run on Cursor"}
        if entry["provider"] == "antigravity" and known is not None and entry["model"] not in known:
            eligible, row = False, {**row, "verdict": "model not recognized"}
        candidate = {**entry, "verdict": row["verdict"], "headroom": room,
                     "headroom_fraction": fraction, "headroom_per_day": pace(row, now),
                     "reason": row.get("reason"), "reading_age_min": row.get("reading_age_min"),
                     "last_headroom": row.get("headroom"), "excluded_family": excluded,
                     "excluded_provider": excluded_provider,
                     "eligible": eligible and not excluded and not excluded_provider}
        candidates.append(candidate)
        if candidate["eligible"]:
            allowed.append((index, candidate))
    chosen = None
    if allowed:
        if builder:
            chosen = allowed[0][1]
        elif (pinned or role in ("release-manager", "elon")) and allowed[0][0] == 0:
            chosen = allowed[0][1]
        else:
            best = max(allowed, key=lambda pair: pair[1]["headroom_per_day"]
                       if pair[1]["headroom_per_day"] is not None else -1)[1]
            first = allowed[0][1]
            # Near equal pace keeps the role's preset provider so readings that wobble
            # by a point do not flip the pick; switch only when clearly lower (over 2 points a day).
            near = (first["headroom_per_day"] is None or best["headroom_per_day"] is None
                    or best["headroom_per_day"] - first["headroom_per_day"] <= TIE_POINTS)
            chosen = first if allowed[0][0] == 0 and near else best
    resets = [r["blocked_until"] for r in rows.values() if r.get("blocked_until")]
    until = min(resets) if resets else None
    return {"role": role, "selected": chosen, "candidates": candidates,
            "blocked_until": until, "blocked_until_local": local(until)}


def candidate_reason(candidate):
    fraction = candidate["headroom_fraction"]
    room = candidate["headroom"]
    detail = "headroom unknown" if room is None else f"headroom {room:g}% ({fraction * 100:.1f}% of ceiling, {candidate['headroom_per_day']:.1f} pts/day)"
    note = ("excluded provider" if candidate["excluded_provider"] else
            "excluded family" if candidate["excluded_family"] else candidate["verdict"])
    return f"{candidate['provider']} {candidate['model']}: {detail}, {note}"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "show", "pick", "banner", "publish", "link"])
    ap.add_argument("--host", action="append", default=[])
    ap.add_argument("--provider")
    ap.add_argument("--model", help="Antigravity model id (pool), or Cursor model checked against included usage")
    ap.add_argument("--role")
    ap.add_argument("--avoid-family", choices=["claude", "gpt", "gemini", "composer", "grok"])
    ap.add_argument("--avoid-provider", choices=["claude", "cursor", "antigravity"])
    ap.add_argument("--cap", type=float, default=None,
                    help="daily pacing line; blocks automatic starts (--auto) only")
    ap.add_argument("--auto", action="store_true",
                    help="an automatic start (fleet-watch): the daily cap blocks it")
    ap.add_argument("--ceiling", type=float, default=None,
                    help="override every provider's ceiling from usage-gate.config.json")
    ap.add_argument("--reserve", type=float, default=None,
                    help="flat weekly percent held back per running worker; default is the config weights")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd in ("check", "pick", "link"):
        link_presets()
    if a.cmd == "link":
        return 0
    if a.cmd == "publish":
        return publish(a.host)
    if a.cmd == "banner":
        pool = record_quota_banner(sys.stdin.read())
        print(pool or "no quota banner found")
        return 0 if pool else 1
    if a.cmd == "pick":
        if not a.role:
            ap.error("pick requires --role")
        try:
            result = pick(a.role, a.avoid_family, a.cap, a.ceiling, a.reserve, a.avoid_provider, a.auto)
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
            running, points = running_reserve(name, a.reserve) if pools else (None, 0.0)
            out.extend(antigravity_result(pools, a.ceiling or ceiling_for(name), time.time(), pool=pool,
                                         reserve=points, running=running)
                       for pool in ("claude", "gemini-flash", "gemini-pro"))
        else:
            out.append(run(name, a.cap, a.ceiling, per_worker=a.reserve, model=a.model, auto=a.auto))
    if a.cmd == "show" and not a.json:
        print(table(out))
    else:
        print(json.dumps(out if len(out) > 1 else out[0]))
    if a.cmd == "show":
        return 0
    if a.provider:
        return {"allowed": 0, "blocked": 3, "unknown": 4}[out[0]["verdict"]]
    if any(o["verdict"] == "allowed" for o in out):
        return 0
    return 3 if out and all(o["verdict"] == "blocked" for o in out) else 4


if __name__ == "__main__":
    sys.exit(main())
