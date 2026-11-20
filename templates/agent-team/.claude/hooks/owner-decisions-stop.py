#!/usr/bin/env python3
"""Stop hook, coordinator only: do not ask the owner what the owner already decided (#1283).

When the last assistant reply asks something ("?") and names issues (#N), run
`script/owner-decisions.sh <repo> <N>` for each. If one has an "Owner decision" comment, block the
reply: "already answered on #N, apply it". Dispatched workers (their first message is the Orca task
preamble) and a second pass after a block (stop_hook_active) are left alone. Anything unexpected,
including a script or gh failure, exits 0: this is a seatbelt, not a gate.

Test overrides: OWNER_DECISIONS_SCRIPT, OWNER_DECISIONS_REPO.
"""
import json
import os
import re
import subprocess
import sys

MAX_ISSUES = 5


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")


def read_transcript(path):
    first_user, last_assistant = "", ""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                msg = rec.get("message") or {}
                role = msg.get("role") or rec.get("type")
                if role == "user" and not first_user:
                    first_user = text_of(msg.get("content", ""))
                elif role == "assistant":
                    t = text_of(msg.get("content", ""))
                    if t.strip():
                        last_assistant = t
    except OSError:
        pass
    return first_user, last_assistant


def main():
    payload = json.load(sys.stdin)
    if payload.get("stop_hook_active"):
        return
    first_user, reply = read_transcript(payload.get("transcript_path") or "")
    reply = payload.get("last_assistant_message") or reply
    if "dispatched worker" in first_user or not re.search(r"[?？]", reply):
        return
    issues = list(dict.fromkeys(re.findall(r"#(\d+)", reply)))[:MAX_ISSUES]
    if not issues:
        return
    script = os.environ.get("OWNER_DECISIONS_SCRIPT") or os.path.expanduser("~/dotfiles/script/owner-decisions.sh")
    repo = os.environ.get("OWNER_DECISIONS_REPO")
    if not repo:
        repo = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                              capture_output=True, text=True, timeout=30).stdout.strip()
    if not repo or not os.path.isfile(script):
        return
    answered = []
    for n in issues:
        r = subprocess.run(["bash", script, repo, n], capture_output=True, text=True, timeout=60)
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
