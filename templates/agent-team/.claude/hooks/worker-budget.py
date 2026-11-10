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
DISPATCH_RE = re.compile(r"--dispatch-id[=\s]+(ctx_[A-Za-z0-9_-]+)")
WORKER_DONE_RE = re.compile(r"(?:^|[\r\n]|&&|\|\||;)\s*orca(?:-dev)?\s+orchestration\s+send\b[^\n]*--type(?:=|\s+)['\"]?worker_done\b")


def user_message_text(obj):
    if not isinstance(obj, dict) or obj.get("type") != "user" or obj.get("isMeta") or obj.get("toolUseResult"):
        return None
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return None
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        parts = [b["text"] for b in content if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
        return "\n".join(parts) if parts else None
    return None


def tool_results_from_line(obj):
    if not isinstance(obj, dict):
        return []
    if obj.get("type") == "tool_result":
        return [obj]
    if obj.get("type") == "user":
        msg = obj.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, list):
            return [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
    return []


def is_worker_done_cmd(cmd, active_ctx):
    if not active_ctx or not isinstance(cmd, str) or not WORKER_DONE_RE.search(cmd):
        return False
    matches = DISPATCH_RE.findall(cmd)
    return not matches or active_ctx in matches


def tool_result_succeeded(res):
    if res is None:
        return False
    if isinstance(res, dict):
        if res.get("is_error") is True or res.get("isError") is True:
            return False
        if res.get("exit_code") not in (None, 0) or res.get("returncode") not in (None, 0):
            return False
        if "ok" in res and isinstance(res["ok"], bool):
            if not res["ok"] or res.get("error"):
                return False
            return "worker_identity_changed" not in json.dumps(res).lower()
        if res.get("error"):
            return False
        c = res.get("content")
        if isinstance(c, dict):
            return tool_result_succeeded(c)
        parts = []
        if isinstance(c, str):
            parts.append(c)
        elif isinstance(c, list):
            for item in c:
                if isinstance(item, dict) and isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item, str):
                    parts.append(item)
        for k in ("stdout", "stderr", "output"):
            v = res.get(k)
            if isinstance(v, str) and v:
                parts.append(v)
        text = "\n".join(parts).strip()
    elif isinstance(res, str):
        text = res.strip()
    else:
        return False
    if not text or "worker_identity_changed" in text.lower():
        return False
    try:
        d = json.loads(text)
        if isinstance(d, dict):
            return d.get("ok") is True and not d.get("error") and not d.get("is_error")
    except Exception:
        pass
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("{") and s.endswith("}"):
            try:
                d = json.loads(s)
                if isinstance(d, dict) and "ok" in d:
                    return d.get("ok") is True and not d.get("error") and not d.get("is_error")
            except Exception:
                pass
    if re.search(r'"ok"\s*:\s*false\b|\bok\s*[:=]\s*false\b|\b(error|failed|fatal|exception|rejected|denied)\b', text, re.I):
        return False
    return bool(re.search(r'"ok"\s*:\s*true\b|\bok\s*[:=]?\s*true\b|\bmessageId=msg_[A-Za-z0-9_-]+|\blifecycle=completed\b', text, re.I))


def is_worker(transcript):
    with open(transcript, "rb") as f:
        for raw in f:
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            utext = user_message_text(obj)
            if utext is not None:
                return "dispatched worker" in utext and "--dispatch-id ctx_" in utext
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
    pending_wd_ids = set()
    last_tool_was_wd = False
    with open(transcript, "rb") as f:
        for raw in f:
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            utext = user_message_text(obj)
            if utext is not None:
                matches = DISPATCH_RE.findall(utext)
                if matches:
                    new_ctx = matches[-1]
                    if new_ctx != active_ctx:
                        active_ctx = new_ctx
                        done_in_transcript = False
                        pending_wd_ids.clear()
                        last_tool_was_wd = False
                continue
            trs = tool_results_from_line(obj)
            if trs:
                if not obj.get("is_error"):
                    for tr in trs:
                        tid = tr.get("tool_use_id") or tr.get("id") or ""
                        if tid:
                            was_wd = tid in pending_wd_ids
                            pending_wd_ids.discard(tid)
                        else:
                            was_wd = last_tool_was_wd
                        last_tool_was_wd = False
                        if was_wd and tool_result_succeeded(tr):
                            done_in_transcript = True
                else:
                    pending_wd_ids.clear()
                    last_tool_was_wd = False
                continue
            if obj.get("type") == "assistant":
                msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                mid = msg.get("id")
                if isinstance(mid, str) and mid.startswith("msg_") and mid != last:
                    ids += 1
                    last = mid
                content = msg.get("content")
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tid = block.get("id") or ""
                            is_wd = False
                            if block.get("name") == "Bash":
                                inp = block.get("input")
                                bcmd = inp.get("command") if isinstance(inp, dict) else ""
                                is_wd = is_worker_done_cmd(bcmd, active_ctx)
                            if tid:
                                if is_wd:
                                    pending_wd_ids.add(tid)
                                else:
                                    pending_wd_ids.discard(tid)
                            last_tool_was_wd = is_wd
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
    # Merge workers run in a lead-* worktree; they are never capped.
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
        if tool == "Bash" and is_worker_done_cmd(cmd, active_ctx) and tool_result_succeeded(data.get("tool_response")):
            st["done_ctx"] = active_ctx
            st["done_size"] = size
            json.dump(st, open(state_path, "w"))
        if n >= WARN:
            msg = (f"Worker budget: {n} turns (stop at {STOP}). Finish the current step, "
                   "push your branch and send worker_done now, or ask Elon with the preamble's ask command.")
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))
        return

    if event == "PreToolUse":
        if tool == "Bash" and is_worker_done_cmd(cmd, active_ctx):
            return
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
