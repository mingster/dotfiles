#!/usr/bin/env python3
"""Print live coding agent workers per machine, e.g. "host-a: 3 | host-b: 2 | host-c: 0".

Counts agent CLI sessions with count-agents.sh, the same counter the fleet watcher uses,
on this machine and over ssh on each paired Orca environment. Coordinator sessions are
left out: one per coordinator worktree (names starting lead- or elon) that has a live
terminal. Machine names come from `hostname -s` and `orca environment list`, never from
this file.

Usage: fleet-workers.py [--cache FILE]   (--cache writes the line to FILE)
"""
import json
import os
import re
import socket
import subprocess
import sys

COUNT_AGENTS = os.environ.get("COUNT_AGENTS") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "count-agents.sh")


def orca(*args):
    try:
        out = subprocess.run(["orca", *args, "--json"], capture_output=True, text=True, timeout=5)
        return json.loads(out.stdout).get("result") or {}
    except (subprocess.SubprocessError, ValueError, OSError):
        return {}


WORKTREE = re.compile(r"/orca/workspaces/[^/]+/([^/]+)")
COORDINATORS = ("lead-", "elon")  # tech-lead worktrees are lead-<slug>; Elon's start with elon


def coordinators(*env):
    """Coordinator worktrees with a live terminal; each runs one agent session."""
    result = orca("terminal", "list", "--limit", "500", *env)
    names = set()
    for t in result.get("terminals", []):
        found = WORKTREE.search(t.get("worktreePath") or "")
        if found and found.group(1).startswith(COORDINATORS):
            names.add(found.group(1))
    return len(names)


def sessions(host=None):
    """Agent CLI sessions on this machine, or on host over ssh (None when unreachable)."""
    cmd = ["bash", COUNT_AGENTS]
    if host:
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "bash", "-s"]
    try:
        with open(COUNT_AGENTS) as script:
            out = subprocess.run(cmd, stdin=script if host else None, capture_output=True, text=True, timeout=15)
        # A remote login shell can print its own lines; the count is the last line that is only a number.
        return int(next(line for line in reversed(out.stdout.splitlines()) if line.strip().isdigit()))
    except (subprocess.SubprocessError, StopIteration, OSError):
        return None


def workers(host=None, *env):
    count = sessions(host)
    return "?" if count is None else max(count - coordinators(*env), 0)


local = socket.gethostname().split(".")[0]
names = {e["id"]: e["name"] for e in orca("environment", "list").get("environments", [])}
counts = {local: workers()}
counts.update({name: workers(name, "--environment", eid) for eid, name in names.items()})

line = " | ".join(f"{n}: {c}" for n, c in counts.items())

if len(sys.argv) == 3 and sys.argv[1] == "--cache":
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.replace(tmp, sys.argv[2])
else:
    print(line)
