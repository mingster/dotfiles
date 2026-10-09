#!/usr/bin/env python3
"""PreToolUse Bash hook: enforce the usage gate on every Orca worker-start.

Wired from each agent team's .claude/settings.json. For every
`orca orchestration worker-start ... --agent <id>` in the command it runs
`usage-gate.py check --provider <id>` (claude and codex only) and denies the
command when the gate exits 3, with the gate's reason and reset time.
Known roles from the task title must also match `pick --role`. The Codex launcher
is checked the same way. A command scoped USAGE_GATE_OVERRIDE reason bypasses
routing enforcement and is logged, but never bypasses the daily or weekly gate.

Passes with a warning on stderr: an agent the gate cannot read (cursor,
antigravity, ...), a worker-start without --agent, gate exit 4 (no reading) and
any gate error. Every other command passes untouched. Exit 0 always; a block is
a JSON permissionDecision of "deny".
"""
import json, os, re, shlex, subprocess, sys
from datetime import datetime, timezone

GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-gate.py")
GATED = {"claude", "codex"}
PUNCT = set(";&|\n()<>")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?=\n|$)", re.S)
VAR = re.compile(r"^\$\{?(\w+)\}?$")


def starts(cmd):
    """Worker starts with provider, title role and command scoped override.

    A `$VAR` agent resolves from a `VAR=x` or `for VAR in x y` in the same command."""
    cmd = HEREDOC.sub("<<", cmd.replace("\\\n", " "))   # heredoc bodies are text, not commands
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars="".join(PUNCT))
        lex.whitespace, lex.commenters, lex.whitespace_split = " \t\r", "", True
        toks = list(lex)
    except ValueError:
        return [{"provider": m.group(1), "role": None, "override": None}
                for m in re.finditer(r"worker-start\b.*?--agent[=\s]+['\"]?([\w.-]+)", cmd, re.S)]
    stop = lambda t: (t and set(t) <= PUNCT) or t == "worker-start"
    env = {}
    for i, t in enumerate(toks):
        if re.match(r"^\w+=", t):
            env[t.split("=", 1)[0]] = [t.split("=", 1)[1]]
        elif t == "for" and toks[i + 2:i + 3] == ["in"]:
            words = toks[i + 3:]
            env[toks[i + 1]] = words[:next((n for n, w in enumerate(words) if stop(w) or w == "do"), len(words))]
    out = []
    for i, t in enumerate(toks):
        launcher = os.path.basename(t) == "start-codex-worker.sh"
        if not launcher and (t != "worker-start" or i == 0 or toks[i - 1] != "orchestration"):
            continue
        end = next((j for j in range(i + 1, len(toks)) if stop(toks[j])), len(toks))
        flags = toks[i + 1:end]
        def option(name):
            for j, word in enumerate(flags):
                if word == name and j + 1 < len(flags):
                    return flags[j + 1]
                if word.startswith(name + "="):
                    return word.split("=", 1)[1]
            return None
        agent = "codex" if launcher else option("--agent")
        title = option("--title" if launcher else "--task-title") or ""
        role_match = re.match(r"^([a-z][a-z0-9-]*)\s+-\s+\S", title)
        role = role_match.group(1) if role_match else None
        # Overrides are environment prefixes of this simple command only. A spec,
        # an echo argument, or an earlier command cannot grant the override.
        begin = i
        while begin > 0 and not stop(toks[begin - 1]):
            begin -= 1
        prefix = toks[begin:i]
        while prefix and prefix[0] in ("do", "then", "env"):
            prefix = prefix[1:]
        if launcher:
            words = [word for word in prefix if not re.match(r"^\w+=", word)]
            if any(os.path.basename(word) not in ("bash", "sh", "exec", "command") for word in words):
                continue
        override = None
        for word in prefix:
            if not re.match(r"^\w+=", word):
                break
            if word.startswith("USAGE_GATE_OVERRIDE="):
                override = word.split("=", 1)[1].strip() or None
        m = VAR.match(agent or "")
        providers = env.get(m.group(1), [agent]) if m else [agent]
        out += [{"provider": provider.lower() if provider else None, "role": role,
                 "override": override} for provider in providers]
    return out


def agents(cmd):
    return [start["provider"] for start in starts(cmd)]


def routing(start):
    role, provider = start["role"], start["provider"]
    try:
        if start["override"]:
            state = os.environ.get("USAGE_GATE_STATE", os.path.expanduser("~/.claude/state/usage-gate"))
            os.makedirs(state, exist_ok=True)
            with open(state + "/overrides.log", "a") as f:
                f.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), "role": role,
                                   "provider": provider, "reason": start["override"]}) + "\n")
        path = os.environ.get("USAGE_GATE_PRESETS", os.path.expanduser("~/.orca/presets.json"))
        with open(path) as f:
            roles = json.load(f).get("roles", {})
        if role not in roles:
            print("usage-gate-hook: no known role prefix; provider pick not enforced.", file=sys.stderr)
            return None
        if start["override"]:
            return None
        result = subprocess.run([sys.executable, GATE, "pick", "--role", role, "--json"],
                                capture_output=True, text=True, timeout=15)
        if result.returncode not in (0, 3):
            raise ValueError(f"pick exit {result.returncode}")
        picked = json.loads(result.stdout)
        chosen = picked.get("selected")
        if chosen and chosen["provider"] == provider:
            return None
        def room(p):
            c = next((c for c in picked.get("candidates", []) if c["provider"] == p), {})
            value, fraction = c.get("headroom"), c.get("headroom_fraction")
            return "unknown" if value is None else f"{value:g}% ({fraction * 100:.1f}% of cap)"
        recommended = chosen["provider"] if chosen else "no provider"
        return (f"Usage gate pick recommends {recommended} for {role}; "
                f"{provider} headroom {room(provider)}, {recommended} headroom {room(recommended)}. "
                "Use the pick flags, or prefix a deliberate override with USAGE_GATE_OVERRIDE='<reason>'.")
    except Exception as exc:
        print(f"usage-gate-hook: pick failed ({exc}); worker-start allowed without routing enforcement.",
              file=sys.stderr)
        return None


def reason(provider, d):
    reserve = f", incl. {d['reserve']:g}% held for {d['running']} running worker(s)" if d.get("reserve") else ""
    if d.get("reason") == "daily cap":
        why = f"daily cap ({d.get('today_used')}% used today, cap {d.get('cap')}% of the week{reserve})"
    else:
        why = f"weekly ceiling ({d.get('weekly_used')}% of the week used, ceiling {d.get('ceiling')}%{reserve})"
    return (f"Usage gate blocked {provider}: {why}. Resets {d.get('blocked_until_local', 'unknown')} (local time). "
            "Use the next provider in the fallback order that passes the gate, or stop dispatching and report it.")


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "worker-start" not in cmd and "start-codex-worker.sh" not in cmd:
        return
    blocked = []
    commands = starts(cmd)
    for start in commands:
        if start["provider"] in GATED:
            denial = routing(start)
            if denial:
                blocked.append(denial)
    for provider in dict.fromkeys(start["provider"] for start in commands):
        if provider not in GATED:
            print(f"usage-gate-hook: no usage reading for agent {provider or '(none given)'}; "
                  "worker-start allowed without the gate.", file=sys.stderr)
            continue
        try:
            r = subprocess.run([sys.executable, GATE, "check", "--provider", provider],
                               capture_output=True, text=True, timeout=10)
            detail = json.loads(r.stdout or "{}")
        except Exception as e:
            print(f"usage-gate-hook: gate failed for {provider} ({e}); worker-start allowed.", file=sys.stderr)
            continue
        if r.returncode == 3:
            try:
                blocked.append(reason(provider, detail))
            except Exception:
                blocked.append(f"Usage gate blocked {provider}: {detail.get('reason', 'see usage-gate.py show')}.")
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
