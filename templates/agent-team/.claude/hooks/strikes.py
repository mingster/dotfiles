#!/usr/bin/env python3
"""Circuit breaker for test and build retry loops (AGENTS.md, Token budget).

Registered as both PostToolUse and PreToolUse on Bash.

PostToolUse: when a test or build command fails, count it against that command
in this session; when it passes, reset the count.
PreToolUse: after 3 failures in a row of the same command in this session, deny
the 4th run and tell the agent to stop and report.

Counted commands: `bun test`, `bun run test*`, `playwright test`, `bun run build`.
The key is the command with `cd ... &&`, `2>&1` and trailing pipes removed, so
`bun test a.test.ts | tail -40` and `bun test a.test.ts` count together.

State lives in `.claude/state/strikes-<session>.json` (git ignored). The owner
resets a session by deleting that file. Anything unexpected exits 0 and lets
the command through: this is a seatbelt, not a gate.
"""
import json
import os
import re
import sys

LIMIT = 3

COUNTED = re.compile(
    r"(^|\s)(bun\s+test\b|bun\s+run\s+test[\w:-]*|(bunx|npx)\s+playwright\s+test\b|bun\s+run\s+build\b)"
)
FAILED = re.compile(
    r"\b[1-9]\d*\s+fail\b"            # bun test summary
    r"|\b[1-9]\d*\s+failed\b"         # playwright summary
    r"|exited with code [1-9]"        # bun run <script> failing
    r"|Failed to compile"
    r"|Build error occurred"
)
PASSED = re.compile(r"\b0\s+fail\b|\b\d+\s+passed\b|Compiled successfully")


def key_of(command):
    cmd = command.strip()
    cmd = re.sub(r"^(cd\s+\S+\s*&&\s*)+", "", cmd)
    cmd = cmd.split("|")[0]
    cmd = re.sub(r"\s*2>&1\s*", " ", cmd)
    return " ".join(cmd.split())


def state_path(data):
    root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or "."
    session = re.sub(r"[^A-Za-z0-9_-]", "", str(data.get("session_id", "unknown")))[:64]
    return os.path.join(root, ".claude", "state", f"strikes-{session}.json")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def save(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(state, f)


def output_text(resp):
    if isinstance(resp, str):
        return resp
    if isinstance(resp, dict):
        return "\n".join(str(resp.get(k, "")) for k in ("stdout", "stderr", "output", "error"))
    return str(resp or "")


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    command = (data.get("tool_input") or {}).get("command", "")
    if not COUNTED.search(command):
        return
    key = key_of(command)
    path = state_path(data)
    state = load(path)
    event = data.get("hook_event_name")

    if event == "PreToolUse":
        if state.get(key, 0) >= LIMIT:
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"Circuit breaker: `{key}` failed {LIMIT} times in a row in this session. "
                        "Stop editing immediately (Three-Strike Hard Stop). Record the error log and attempted fixes "
                        "in `active_run.md` (or `progress.md`) under `[Blockers]`. Await human input without blind retries."
                    ),
                }
            }))
        return

    if event == "PostToolUse":
        text = output_text(data.get("tool_response"))
        if FAILED.search(text):
            state[key] = state.get(key, 0) + 1
            save(path, state)
            note = f"Strike {state[key]} of {LIMIT} for `{key}`."
            if state[key] >= LIMIT:
                note += " Hard Stop: command blocked for session. Write error log and attempted solutions to `active_run.md` under `[Blockers]` and report to owner."
            elif state[key] >= 2:
                note += (" Two strikes: stop editing code. Check the mock.module fake against the real module "
                         "and the local Postgres before one last run; the next failure blocks this command.")
            print(json.dumps({
                "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note}
            }))

        elif PASSED.search(text) and key in state:
            del state[key]
            save(path, state)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
