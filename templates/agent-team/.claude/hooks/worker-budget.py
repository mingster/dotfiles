#!/usr/bin/env python3
"""Turn budget and post-worker_done lock for Orca workers in the agent team.

Applies only to an Orca worker: the session runs inside an Orca worktree
(~/orca/workspaces/) and its first message is the worker brief carrying a Dispatch
id (`--dispatch-id ctx_`). Orca puts that id in no environment variable, so Elon's
and the owner's sessions, which start without a brief, are never capped. Counts assistant turns in
the transcript (state kept in ~/.claude/state, outside every repo).

PostToolUse: past WARN turns, tells the worker to finish the slice and report.
PreToolUse: once a worker sends `orca orchestration send ... --type worker_done` for its
active `--dispatch-id ctx_<id>`, denies any subsequent non-read tool call until a newer
user message introduces a new `--dispatch-id ctx_<id2>`. Past STOP turns, denies every
tool except reading and the `orca` commands a worker needs to send worker_done or ask.
Exit 0 always; anything it cannot parse is let through.
"""
import json, os, re, sys

WARN, STOP = 120, 200
WORKSPACES = os.path.realpath(os.path.expanduser("~/orca/workspaces"))
STATE_DIR = os.path.expanduser("~/.claude/state/worker-budget")
DISPATCH_RE = re.compile(rb"--dispatch-id[=\s]+(ctx_[A-Za-z0-9_-]+)")
WORKER_DONE_RE = re.compile(rb"\borca(?:-dev)?\s+orchestration\s+send\b[^\n]*--type[=\s]+\"?worker_done\b")


def is_user_line(raw):
    return (b'"type": "user"' in raw or b'"type":"user"' in raw) and b'"isMeta":true' not in raw


def is_worker(transcript):
    with open(transcript, "rb") as f:
        for raw in f:
            if is_user_line(raw):
                return b"dispatched worker" in raw and b"--dispatch-id ctx_" in raw
    return False


def inspect_session(transcript, session):
    path = os.path.join(STATE_DIR, re.sub(r"[^A-Za-z0-9_-]", "", session)[:64] + ".json")
    try:
        st = json.load(open(path))
    except Exception:
        st = {}
    ids = 0
    last = ""
    active_ctx = ""
    done_in_transcript = False
    with open(transcript, "rb") as f:
        for raw in f:
            if is_user_line(raw):
                matches = DISPATCH_RE.findall(raw)
                if matches:
                    new_ctx = matches[-1].decode("utf-8", errors="replace")
                    if new_ctx != active_ctx:
                        active_ctx = new_ctx
                        done_in_transcript = False
                continue
            if b'"assistant"' in raw:
                m = re.search(rb'"id":\s*"(msg_[A-Za-z0-9_]+)"', raw)
                if m and m.group(1).decode() != last:
                    ids += 1
                    last = m.group(1).decode()
            if active_ctx and WORKER_DONE_RE.search(raw):
                matches = [c.decode("utf-8", errors="replace") for c in DISPATCH_RE.findall(raw)]
                if not matches or active_ctx in matches:
                    done_in_transcript = True
        size = f.tell()
    st["offset"] = size
    st["ids"] = ids
    st["last"] = last
    if st.get("done_ctx") and (st.get("done_ctx") != active_ctx or size < st.get("done_size", 0)):
        st.pop("done_ctx", None)
        st.pop("done_size", None)
    os.makedirs(STATE_DIR, exist_ok=True)
    json.dump(st, open(path, "w"))
    is_done = done_in_transcript or (bool(active_ctx) and st.get("done_ctx") == active_ctx)
    return ids, active_ctx, is_done, path, st, size


def main():
    data = json.load(sys.stdin)
    cwd = os.path.realpath(data.get("cwd") or os.getcwd())
    if not cwd.startswith(WORKSPACES + os.sep):
        return
    # Merges run in a lead-* worktree (the name lead-merge.sh checks); it is never capped.
    parts = cwd[len(WORKSPACES) + 1:].split(os.sep)
    if len(parts) > 1 and parts[1].startswith("lead-"):
        return
    transcript = data["transcript_path"]
    if not is_worker(transcript):
        return
    n, active_ctx, is_done, state_path, st, size = inspect_session(transcript, str(data.get("session_id", "unknown")))
    event = data.get("hook_event_name")
    tool = data.get("tool_name", "")
    cmd = (data.get("tool_input") or {}).get("command", "")

    if event == "PostToolUse":
        if tool == "Bash" and active_ctx and WORKER_DONE_RE.search(cmd.encode("utf-8", errors="replace")):
            matches = [c.decode("utf-8", errors="replace") for c in DISPATCH_RE.findall(cmd.encode("utf-8", errors="replace"))]
            if not matches or active_ctx in matches:
                st["done_ctx"] = active_ctx
                st["done_size"] = size
                json.dump(st, open(state_path, "w"))
        if n >= WARN:
            msg = (f"Worker budget: {n} turns (stop at {STOP}). Finish the current step, "
                   "push your branch and send worker_done now, or ask Elon with the preamble's ask command.")
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
        return

    if event == "PreToolUse":
        if is_done:
            if tool in ("Read", "Grep", "Glob"):
                return
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": f"worker_done was already sent for {active_ctx}; return to an idle prompt until a new --dispatch-id ctx_ arrives."}}))
            return
        if n >= STOP:
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
