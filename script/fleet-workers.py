#!/usr/bin/env python3
"""Print busy dispatched workers per machine, e.g. "host-a: 3 | host-b: 2 | host-c: 0".

A busy worker is a dispatch from `orca orchestration worker-list` that is live and still
in progress. The coordinator, automation sessions and finished workers whose terminal is
kept open are not dispatches in progress, so they are never counted. Each paired Orca
environment is asked for its own list. Machine names come from `hostname -s` and
`orca environment list`, never from this file.

Usage: fleet-workers.py [--cache FILE]   (--cache writes the line to FILE)
"""
import json
import os
import socket
import subprocess
import sys


def orca(*args):
    try:
        out = subprocess.run(["orca", *args, "--json"], capture_output=True, text=True, timeout=10)
        return json.loads(out.stdout).get("result") or {}
    except (subprocess.SubprocessError, ValueError, OSError):
        return {}


def workers(*env):
    """Live, in progress dispatches on one Orca server ('?' when it cannot be asked)."""
    result = orca("orchestration", "worker-list", "--limit", "100", *env)
    if "workers" not in result:
        return "?"
    # Without --environment the list also carries rows observed from paired servers.
    return sum(
        1
        for w in result["workers"]
        if w.get("host") == "local" and w.get("liveness") == "live" and w.get("outcome") == "in_progress"
    )


local = socket.gethostname().split(".")[0]
# An IP has no known ssh host key, so use the ssh alias for the label.
# The address to alias map is private: fleet-workers.local.json beside this script, gitignored.
overlay = os.path.join(os.path.dirname(os.path.realpath(__file__)), "fleet-workers.local.json")
ALIASES = {}
if os.path.exists(overlay):
    with open(overlay) as f:
        ALIASES = json.load(f)
names = {e["id"]: ALIASES.get(e["name"], e["name"]) for e in orca("environment", "list").get("environments", [])}
counts = {local: workers()}
counts.update({name: workers("--environment", eid) for eid, name in names.items()})

line = " | ".join(f"{n}: {c}" for n, c in counts.items())

if len(sys.argv) == 3 and sys.argv[1] == "--cache":
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.replace(tmp, sys.argv[2])
else:
    print(line)
