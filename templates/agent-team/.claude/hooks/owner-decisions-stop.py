#!/usr/bin/env python3
"""Stop hook, coordinator only: do not ask the owner what the owner already decided (#1283).

When the last assistant reply asks something ("?") and names issues (#N or owner/repo#N), run
`script/owner-decisions.sh <repo> <N>` for each. If one has an "Owner decision" comment, block the
reply: "already answered on #N, apply it". Dispatched workers (their first message is the Orca task
preamble) and a second pass after a block (stop_hook_active) are left alone. Anything unexpected,
including a script or gh failure, exits 0: this is a seatbelt, not a gate.

Test overrides: OWNER_DECISIONS_SCRIPT, OWNER_DECISIONS_REPO (bare #N only).
"""
import json
import os
import re
import subprocess
import sys

MAX_ISSUES = 5
REF = re.compile(r"(?<![\w/])([\w.-]+/[\w.-]+)?#(\d+)")


def text_of(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(p.get("text") or "" for p in content if isinstance(p, dict) and p.get("type") == "text")


def is_real_user(rec, msg):
    """A user record that is neither meta nor a tool result."""
    if rec.get("isMeta") or rec.get("toolUseResult"):
        return False
    content = msg.get("content")
    return not (isinstance(content, list)
                and any(isinstance(p, dict) and p.get("type") == "tool_result" for p in content))


def read_transcript(path):
    """First real user message, and the assistant text of the current turn (since the last real user)."""
    first_user, turn = "", []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                    msg = rec.get("message") or {}
                    role = msg.get("role") or rec.get("type")
                    if role == "user" and is_real_user(rec, msg):
                        first_user = first_user or text_of(msg.get("content"))
                        turn = []
                    elif role == "assistant":
                        t = text_of(msg.get("content"))
                        if t.strip():
                            turn.append(t)
                except (ValueError, AttributeError):
                    continue
    except OSError:
        pass
    return first_user, "\n".join(turn)


def current_repo(payload):
    repo = os.environ.get("OWNER_DECISIONS_REPO")
    if repo:
        return repo
    return subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                          capture_output=True, text=True, timeout=30,
                          cwd=payload.get("cwd") or None).stdout.strip()


def main():
    payload = json.load(sys.stdin)
    if payload.get("stop_hook_active"):
        return
    first_user, reply = read_transcript(payload.get("transcript_path") or "")
    reply = payload.get("last_assistant_message") or reply
    if "dispatched worker" in first_user or not re.search(r"[?？]", reply):
        return
    refs = REF.findall(reply)
    script = os.environ.get("OWNER_DECISIONS_SCRIPT") or os.path.expanduser("~/dotfiles/script/owner-decisions.sh")
    if not refs or not os.path.isfile(script):
        return
    repo = current_repo(payload) if any(not r for r, _ in refs) else ""
    pairs = list(dict.fromkeys((r or repo, n) for r, n in refs))[:MAX_ISSUES]
    answered = []
    for r_repo, n in pairs:
        if not r_repo:
            continue
        r = subprocess.run(["bash", script, r_repo, n], capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            answered.append((n, r.stdout.strip()))
    if answered:
        nums = ", ".join(f"#{n}" for n, _ in answered)
        detail = "\n".join(d for _, d in answered)
        print(json.dumps({"decision": "block",
                          "reason": f"already answered on {nums}, apply it. Do not ask the owner again.\n{detail}"}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
