#!/usr/bin/env python3
"""Turn budget for Orca workers in the agent team.

Applies only when the session runs inside an Orca worktree (~/orca/workspaces/),
so Elon's and the owner's sessions are never capped. Counts assistant turns in
the transcript (state kept in ~/.claude/state, outside every repo).

PostToolUse: past WARN turns, tells the worker to finish the slice and report.
PreToolUse: past STOP turns, denies every tool except reading and the `orca`
commands a worker needs to send worker_done or ask.
Exit 0 always; anything it cannot parse is let through.
"""
import json, os, re, sys

WARN, STOP = 120, 200
WORKSPACES = os.path.realpath(os.path.expanduser("~/orca/workspaces"))
STATE_DIR = os.path.expanduser("~/.claude/state/worker-budget")


def turns(transcript, session):
    path = os.path.join(STATE_DIR, re.sub(r"[^A-Za-z0-9_-]", "", session)[:64] + ".json")
    try:
        st = json.load(open(path))
    except Exception:
        st = {"offset": 0, "ids": 0, "last": ""}
    with open(transcript, "rb") as f:
        f.seek(st["offset"])
        for raw in f:
            if b'"assistant"' not in raw:
                continue
            m = re.search(rb'"id":\s*"(msg_[A-Za-z0-9]+)"', raw)
            if m and m.group(1).decode() != st["last"]:
                st["ids"] += 1
                st["last"] = m.group(1).decode()
        st["offset"] = f.tell()
    os.makedirs(STATE_DIR, exist_ok=True)
    json.dump(st, open(path, "w"))
    return st["ids"]


def main():
    data = json.load(sys.stdin)
    cwd = os.path.realpath(data.get("cwd") or os.getcwd())
    if not cwd.startswith(WORKSPACES + os.sep):
        return
    n = turns(data["transcript_path"], str(data.get("session_id", "unknown")))
    event = data.get("hook_event_name")
    if event == "PostToolUse" and n >= WARN:
        msg = (f"Worker budget: {n} turns (stop at {STOP}). Finish the current step, "
               "push your branch and send worker_done now, or ask Elon with the preamble's ask command.")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
    elif event == "PreToolUse" and n >= STOP:
        tool = data.get("tool_name", "")
        cmd = (data.get("tool_input") or {}).get("command", "")
        if tool in ("Read", "Grep", "Glob") or re.match(r"^\s*(orca|orca-dev|git (status|diff|log|push))\b", cmd):
            return
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": f"Worker budget spent ({n} turns). Push, then send worker_done "
            "(--outcome failed if unfinished) with what is left, so Elon can re-dispatch it fresh."}}))


try:
    main()
except Exception:
    pass
sys.exit(0)
