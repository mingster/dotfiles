#!/usr/bin/env python3
"""PreToolUse Bash hook: enforce the usage gate on every Orca worker-start.

Wired from each agent team's .claude/settings.json. For every
`orca orchestration worker-start ... --agent <id>` in the command it runs
`usage-gate.py check --provider <id>` (claude and codex only) and denies the
command when the gate exits 3, with the gate's reason and reset time.

Passes with a warning on stderr: an agent the gate cannot read (cursor,
antigravity, ...), a worker-start without --agent, gate exit 4 (no reading) and
any gate error. Every other command passes untouched. Exit 0 always; a block is
a JSON permissionDecision of "deny".
"""
import json, os, re, shlex, subprocess, sys
from datetime import datetime, timedelta

GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-gate.py")
GATED = {"claude", "codex"}
PUNCT = set(";&|\n")


def agents(cmd):
    """Agent id per worker-start in cmd (None when it has no --agent)."""
    try:
        lex = shlex.shlex(cmd.replace("\\\n", " "), posix=True, punctuation_chars=";&|\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return [m.group(1) for m in re.finditer(r"worker-start\b.*?--agent[=\s]+['\"]?([\w.-]+)", cmd, re.S)] or [None]
    out = []
    for i, t in enumerate(toks):
        if t != "worker-start" or i == 0 or toks[i - 1] != "orchestration":
            continue
        agent = None
        for j in range(i + 1, len(toks)):
            a = toks[j]
            if (a and set(a) <= PUNCT) or a == "worker-start":
                break
            if a == "--agent" and j + 1 < len(toks):
                agent = toks[j + 1]
            elif a.startswith("--agent="):
                agent = a.split("=", 1)[1]
        out.append(agent)
    return out


def when(ts):
    return datetime.fromtimestamp(float(ts)).strftime("%a %d %b %H:%M") if ts else "unknown"


def reason(provider, d):
    resets = d.get("resets_at")
    if d.get("reason") == "daily cap":
        midnight = (datetime.now() + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        at = min(midnight, float(resets)) if resets else midnight
        why = f"daily cap ({d.get('today_used')}% used today, cap {d.get('cap')}% of the week)"
    else:
        at = resets
        why = f"weekly ceiling ({d.get('weekly_used')}% of the week used, ceiling {d.get('ceiling')}%)"
    return (f"Usage gate blocked {provider}: {why}. Resets {when(at)}. Use the next provider in the "
            "fallback order that passes the gate, or stop dispatching and report it.")


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "worker-start" not in cmd:
        return
    blocked = []
    for provider in dict.fromkeys(a.lower() if a else None for a in agents(cmd)):
        if provider not in GATED:
            print(f"usage-gate-hook: no usage reading for agent {provider or '(none given)'}; "
                  "worker-start allowed without the gate.", file=sys.stderr)
            continue
        try:
            r = subprocess.run([sys.executable, GATE, "check", "--provider", provider],
                               capture_output=True, text=True, timeout=30)
            detail = json.loads(r.stdout or "{}")
        except Exception as e:
            print(f"usage-gate-hook: gate failed for {provider} ({e}); worker-start allowed.", file=sys.stderr)
            continue
        if r.returncode == 3:
            blocked.append(reason(provider, detail))
        elif r.returncode != 0:
            print(f"usage-gate-hook: no usage reading for {provider} (gate exit {r.returncode}); "
                  "worker-start allowed, say so in your report.", file=sys.stderr)
    if blocked:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason": " ".join(blocked)}}))


try:
    main()
except Exception:
    pass
sys.exit(0)
