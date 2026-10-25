#!/usr/bin/env python3
"""Print live Orca workers per machine, e.g. "host-a: 3 | host-b: 2 | host-c: 0".

Counts dispatched workers of every run on this Orca, grouped by the machine the
worker runs on (this one, or a paired Orca environment). Machine names come from
`hostname -s` and `orca environment list`, never from this file.

Usage: fleet-workers.py [--cache FILE]   (--cache writes the line to FILE)
"""
import json
import os
import socket
import subprocess
import sys


def orca(*args):
    try:
        out = subprocess.run(["orca", *args, "--json"], capture_output=True, text=True, timeout=5)
        return json.loads(out.stdout).get("result") or {}
    except (subprocess.SubprocessError, ValueError, OSError):
        return {}


def env_id(node):
    """First environmentId anywhere in a worker-show result."""
    if isinstance(node, dict):
        if node.get("environmentId"):
            return node["environmentId"]
        node = list(node.values())
    if isinstance(node, list):
        for child in node:
            found = env_id(child)
            if found:
                return found
    return None


local = socket.gethostname().split(".")[0]
names = {e["id"]: e["name"] for e in orca("environment", "list").get("environments", [])}
counts = {local: 0, **{n: 0 for n in names.values()}}

for run in orca("orchestration", "run-list").get("runs", []):
    workers = orca("orchestration", "worker-list", "--run", run["id"], "--limit", "100").get("workers", [])
    for w in workers:
        if w.get("dispatchStatus") != "dispatched":
            continue
        shown = orca("orchestration", "worker-show", "--dispatch", w["dispatchId"])
        machine = names.get(env_id(shown), local)
        counts[machine] += 1

line = " | ".join(f"{n}: {c}" for n, c in counts.items())

if len(sys.argv) == 3 and sys.argv[1] == "--cache":
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.replace(tmp, sys.argv[2])
else:
    print(line)
