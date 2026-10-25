#!/usr/bin/env python3
"""Print live Orca workers per machine, e.g. "host-a: 3 | host-b: 2 | host-c: 0".

Counts live terminals in workspace worktrees (~/orca/workspaces/<project>/<name>) on
this machine and on each paired Orca environment, minus coordinator terminals (worktree
names starting lead- or elon). Orca marks a running worker completed early, so run
status is not used. Machine names come from
`hostname -s` and `orca environment list`, never from this file.

Usage: fleet-workers.py [--cache FILE]   (--cache writes the line to FILE)
"""
import json
import os
import re
import socket
import subprocess
import sys


def orca(*args):
    try:
        out = subprocess.run(["orca", *args, "--json"], capture_output=True, text=True, timeout=5)
        return json.loads(out.stdout).get("result") or {}
    except (subprocess.SubprocessError, ValueError, OSError):
        return {}


WORKTREE = re.compile(r"/orca/workspaces/[^/]+/([^/]+)")
COORDINATORS = ("lead-", "elon")  # tech-lead worktrees are lead-<slug>; Elon's start with elon


def is_worker(terminal):
    """A terminal in a workspace worktree that is not a coordinator's."""
    found = WORKTREE.search(terminal.get("worktreePath") or "")
    return bool(found) and not found.group(1).startswith(COORDINATORS)


def live_workers(*env):
    result = orca("terminal", "list", "--limit", "500", *env)
    return sum(1 for t in result.get("terminals", []) if is_worker(t))


local = socket.gethostname().split(".")[0]
names = {e["id"]: e["name"] for e in orca("environment", "list").get("environments", [])}
counts = {local: live_workers()}
counts.update({name: live_workers("--environment", eid) for eid, name in names.items()})

line = " | ".join(f"{n}: {c}" for n, c in counts.items())

if len(sys.argv) == 3 and sys.argv[1] == "--cache":
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.replace(tmp, sys.argv[2])
else:
    print(line)
