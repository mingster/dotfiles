#!/usr/bin/env python3
"""Check that the fleet is as busy as Orca says it is.

Orca reports a worker as live and in progress when its agent ended the turn and sits idle,
when the agent process is gone but the terminal stays open, or when the host is asleep.
This prints one line per fleet host (reachable, load, memory, workers reported active,
workers really active) and lists every worker that is reported active but is not.

A worker is really active when its terminal has a live agent process and either its screen
changed inside the window (default 10 minutes) or it shows a running tool. Anything else is
"reported active, actually idle" or "actually gone". An unreachable host is named, never
counted as 0 or full. The checker only reports; the coordinator decides what to stop.

Hosts come from the same place fleet-workers.py uses: this machine plus
`orca environment list`, with the private fleet-workers.local.json alias map. Load and
memory come from the fleet load sensor worker-placement.py uses (FLEET_LOAD_SCRIPT, else
~/.claude/state/fleet-load.sh). Nothing here names a host.

Usage: check-fleet-status.py [--window-minutes N] [--json]
Exit 0 when report and reality match, 1 on any mismatch or unreachable host, 2 on bad usage.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time

DEFAULT_WINDOW_MINUTES = 10
USAGE = "Usage: check-fleet-status.py [--window-minutes N] [--json]"
HELP = (USAGE + "\nChecks every fleet host: each worker Orca reports as live and in progress must be "
        "really active (a live agent with a recent screen change or a running tool). Exits 1 on any "
        "mismatch or unreachable host.")
RUNNING_TOOL = re.compile(r"esc to interrupt|Running…|Running\.\.\.|ctrl\+c to interrupt", re.IGNORECASE)
LOAD = re.compile(r"\bload=(?P<l>[0-9.]+)")
CORES = re.compile(r"\bcores=(?P<c>[0-9]+)")
MEMFREE = re.compile(r"\bmemfree=(?P<m>[0-9.]+)")


def run(cmd, timeout=15):
    """Return stdout, or None when the command fails. Tests replace this."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.SubprocessError, OSError):
        return None
    return p.stdout if p.returncode == 0 else None


def orca(*args):
    out = run(["orca", *args, "--json"])
    if out is None:
        return None
    try:
        return json.loads(out).get("result") or {}
    except ValueError:
        return None


def fleet_hosts():
    """[(label, environment args)] for this machine and every paired Orca environment."""
    overlay = os.path.join(os.path.dirname(os.path.realpath(__file__)), "fleet-workers.local.json")
    aliases = {}
    if os.path.exists(overlay):
        with open(overlay) as f:
            aliases = json.load(f)
    hosts = [(socket.gethostname().split(".")[0], [])]
    for e in (orca("environment", "list") or {}).get("environments", []):
        hosts.append((aliases.get(e["name"], e["name"]), ["--environment", e["id"]]))
    return hosts


def sensor_rows():
    """{host: (cores, load, memfree_gb or None) or None when unreachable}, {} without a sensor."""
    path = os.path.expanduser(
        os.environ.get("FLEET_LOAD_SCRIPT") or os.environ.get("WORKER_PLACEMENT_LOAD_SCRIPT") or "~/.claude/state/fleet-load.sh"
    )
    out = run(["bash", path], timeout=60) if os.path.isfile(path) else None
    rows = {}
    for line in (out or "").splitlines():
        parts = line.split()
        if not parts:
            continue
        if "unreachable" in line.lower():
            rows[parts[0]] = None
            continue
        c, l, m = CORES.search(line), LOAD.search(line), MEMFREE.search(line)
        if c and l:
            rows[parts[0]] = (int(c["c"]), float(l["l"]), float(m["m"]) if m else None)
    return rows


def local_free_percent():
    """System wide free memory percent on macOS ('memory_pressure'), None elsewhere."""
    m = re.search(r"free percentage:\s*([0-9]+)%", run(["memory_pressure", "-Q"]) or "")
    return int(m[1]) if m else None


def judge(worker, terminal, now_ms, window_ms):
    """None when really active, else (kind, why)."""
    if terminal is None:
        return "gone", "terminal not found"
    if not terminal.get("agentIdentity") or terminal.get("connected") is False:
        return "gone", "no live agent process"
    if RUNNING_TOOL.search(terminal.get("preview") or ""):
        return None
    last = terminal.get("lastOutputAt")
    if isinstance(last, (int, float)) and now_ms - last <= window_ms:
        return None
    idle = "no screen change" if not isinstance(last, (int, float)) else f"screen unchanged {int((now_ms - last) / 60000)} min"
    return "idle", idle


def check_host(label, env, sensor, now_ms, window_ms, local=False):
    host = {"host": label, "reachable": True, "load": None, "cores": None, "memfree": None, "free_pct": None, "reported": 0, "real": 0, "mismatches": []}
    if label in sensor:
        row = sensor[label]
        if row is None:
            host["reachable"] = False
        else:
            host["cores"], host["load"], host["memfree"] = row
    if local and host["memfree"] is None:
        host["free_pct"] = local_free_percent()
    listed = orca("orchestration", "worker-list", "--limit", "100", *env)
    if listed is None or "workers" not in listed:
        host["reachable"] = False
        return host
    for w in listed["workers"]:
        if w.get("host") != "local" or w.get("liveness") != "live" or w.get("outcome") != "in_progress":
            continue
        host["reported"] += 1
        shown = orca("terminal", "show", "--terminal", w.get("terminal", ""), *env)
        terminal = (shown or {}).get("terminal")
        verdict = judge(w, terminal, now_ms, window_ms)
        if verdict is None:
            host["real"] += 1
            continue
        kind, why = verdict
        host["mismatches"].append({
            "kind": kind,
            "why": why,
            "dispatch": w.get("dispatchId"),
            "title": (terminal or {}).get("title") or w.get("workspace", "").rsplit("/", 1)[-1],
        })
    return host


def host_line(h):
    if not h["reachable"]:
        return f"{h['host']}: UNREACHABLE (not counted as 0 or full) reported=? real=?"
    load = "n/a" if h["load"] is None else f"{h['load']:.2f}/{h['cores']}c"
    mem = "n/a"
    if h["memfree"] is not None:
        mem = f"{h['memfree']:.1f}GB free"
    elif h["free_pct"] is not None:
        mem = f"{h['free_pct']}% free"
    return f"{h['host']}: reachable load={load} mem={mem} reported={h['reported']} real={h['real']}"


def main(argv):
    window = DEFAULT_WINDOW_MINUTES
    as_json = False
    args = list(argv)
    if any(a in ("-h", "--help") for a in args):
        print(HELP)
        return 0
    while args:
        a = args.pop(0)
        if a == "--json":
            as_json = True
        elif a == "--window-minutes" and args and args[0].isdigit():
            window = int(args.pop(0))
        else:
            print(USAGE, file=sys.stderr)
            return 2
    now_ms = time.time() * 1000
    sensor = sensor_rows()
    hosts = [check_host(label, env, sensor, now_ms, window * 60000, local=not env) for label, env in fleet_hosts()]
    if as_json:
        print(json.dumps(hosts, indent=2))
    else:
        for h in hosts:
            print(host_line(h))
            for m in h["mismatches"]:
                state = "reported active, actually idle" if m["kind"] == "idle" else "reported active, actually gone"
                print(f"  {state}: {m['dispatch']} {m['title']} ({m['why']})")
    bad = any(not h["reachable"] or h["mismatches"] for h in hosts)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
