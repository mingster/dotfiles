#!/usr/bin/env python3
"""Daily usage gate for the agent team: stop dispatching when a provider has used
its daily share of the weekly limit, so the week never runs out.

  usage-gate.py check [--provider claude|codex|<other>] [--cap 12] [--ceiling 95]
  usage-gate.py show

Reads the provider's own weekly percentage, never an estimate:
  codex   latest token_count event in ~/.codex/sessions whose weekly window is
          under rate_limits.primary or rate_limits.secondary
  claude  ~/.claude/state/usage-gate/claude-rate-limits.json, written by
          statusline.sh from Claude Code's statusline input (rate_limits.seven_day)

Per provider it keeps the weekly percentage seen at the start of the local day
and blocks when (now - start) >= cap, or when the week is >= ceiling used.
A reading older than MAX_AGE (6 hours), or of unknown age, counts as no reading:
an idle provider's last number says nothing about today. So does any provider
without a reader (cursor, antigravity, ...).
Exit codes: 0 allowed, 3 blocked, 4 unknown (no reading; treated as allowed by
callers, reported so the owner can see the gap).
"""
import argparse, glob, json, os, sys, time
from datetime import datetime

HOME = os.path.expanduser("~")
STATE = os.environ.get("USAGE_GATE_STATE", HOME + "/.claude/state/usage-gate")
CODEX = os.environ.get("USAGE_GATE_CODEX_SESSIONS", HOME + "/.codex/sessions")
WEEK_MIN = 10080
MAX_AGE = 6 * 3600  # seconds; an older reading is no reading


def codex_reading(root=None):
    files = sorted(glob.glob((root or CODEX) + "/**/rollout-*.jsonl", recursive=True))
    for path in reversed(files[-8:]):
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
            except (ValueError, KeyError, AttributeError):
                continue
            for p in windows:
                if p.get("window_minutes") == WEEK_MIN and "used_percent" in p:
                    return {"pct": float(p["used_percent"]), "resets_at": p.get("resets_at"),
                            "observed_at": d.get("timestamp")}
    return None


def claude_reading(path=None):
    try:
        d = json.load(open(path or STATE + "/claude-rate-limits.json"))
        w = d["seven_day"]
        return {"pct": float(w["used_percentage"]), "resets_at": w.get("resets_at"),
                "observed_at": d.get("_written_at")}
    except (OSError, ValueError, KeyError, TypeError):
        return None


READERS = {"codex": codex_reading, "claude": claude_reading}


def fresh(reading, now):
    """The reading, or None when it is older than MAX_AGE or its age is unknown.
    observed_at is epoch seconds (claude) or an ISO timestamp (codex)."""
    at = (reading or {}).get("observed_at")
    try:
        t = float(at)
    except (TypeError, ValueError):
        try:
            t = datetime.fromisoformat(str(at).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return reading if now - t <= MAX_AGE else None


def decide(reading, state, today, now, cap, ceiling):
    """Return (verdict, detail, new_state). verdict: allowed|blocked|unknown."""
    if reading is None:
        return "unknown", {"reason": "no reading"}, state
    pct, resets = reading["pct"], reading.get("resets_at")
    if resets and float(resets) < now:      # the week rolled over since this reading
        pct, resets = 0.0, None
    st = dict(state or {})
    old = st.get("resets_at")
    # codex resets_at jitters by a few seconds between events; only a jump of an hour is a new week
    moved = (old is None) != (resets is None) or (old is not None and abs(float(resets) - float(old)) >= 3600)
    rolled = moved or pct < st.get("baseline", 0)
    if st.get("date") != today or "baseline" not in st or rolled:
        st = {"date": today, "baseline": 0.0 if rolled and st.get("date") == today else pct,
              "resets_at": resets}
    spent = round(pct - st["baseline"], 1)
    detail = {"weekly_used": pct, "today_used": spent, "cap": cap, "ceiling": ceiling,
              "resets_at": resets}
    if pct >= ceiling:
        detail["reason"] = "weekly ceiling"
        return "blocked", detail, st
    if spent >= cap:
        detail["reason"] = "daily cap"
        return "blocked", detail, st
    return "allowed", detail, st


def run(provider, cap, ceiling, now=None):
    now = now or time.time()
    today = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    path = f"{STATE}/{provider}.json"
    try:
        state = json.load(open(path))
    except (OSError, ValueError):
        state = None
    reader = READERS.get(provider)
    reading = fresh(reader(), now) if reader else None
    verdict, detail, new = decide(reading, state, today, now, cap, ceiling)
    if new is not state and new:
        os.makedirs(STATE, exist_ok=True)
        json.dump(new, open(path, "w"))
    return {"provider": provider, "verdict": verdict, **detail}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "show"])
    ap.add_argument("--provider")
    ap.add_argument("--cap", type=float, default=12.0)
    ap.add_argument("--ceiling", type=float, default=95.0)
    a = ap.parse_args(argv)
    names = [a.provider] if a.provider else list(READERS)
    out = [run(n, a.cap, a.ceiling) for n in names]
    print(json.dumps(out if len(out) > 1 else out[0]))
    if a.cmd == "show":
        return 0
    if a.provider:
        return {"allowed": 0, "blocked": 3, "unknown": 4}[out[0]["verdict"]]
    return 0 if any(o["verdict"] != "blocked" for o in out) else 3


if __name__ == "__main__":
    sys.exit(main())
