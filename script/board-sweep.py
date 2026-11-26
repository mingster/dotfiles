#!/usr/bin/env python3
"""Hourly board sweep: board-done --fleet --apply, then board-clean --fleet --apply.

The catch-all for cards no lifecycle event moved. Each step has its own time limit, so a slow
board-done (one slow host) cannot take board-clean's time. board-clean gets BOARD_CLEAN_BUDGET_S
under its limit, stops itself there, and resumes next run with the cards it has not looked at.
--dry-run lists what both steps would do and changes nothing.
The limits are BOARD_SWEEP_DONE_TIMEOUT and BOARD_SWEEP_CLEAN_TIMEOUT (seconds).
"""
import os
import signal
import subprocess
import sys
from pathlib import Path

STEPS = (("board-done", "BOARD_SWEEP_DONE_TIMEOUT", 240), ("board-clean", "BOARD_SWEEP_CLEAN_TIMEOUT", 300))


def run_step(name: str, mode: str, limit: float, env: dict) -> int:
    script = Path(__file__).resolve().parent / (name + ".py")
    # Its own process group, so a timeout also stops the orca and gh calls the step started.
    proc = subprocess.Popen([sys.executable, "-u", str(script), "--fleet", mode], env=env, start_new_session=True)
    try:
        return proc.wait(timeout=limit)
    except BaseException as exc:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        if not isinstance(exc, subprocess.TimeoutExpired):
            raise
        return 124


def main(argv: list) -> int:
    if argv not in ([], ["--dry-run"]):
        print("Usage: board-sweep.py [--dry-run]", file=sys.stderr)
        return 2
    mode = argv[0] if argv else "--apply"
    # The automation wrapper stops a run with TERM; exit through run_step so the step does not outlive it.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    failed = 0
    for name, variable, default in STEPS:
        limit = float(os.environ.get(variable) or default)
        env = dict(os.environ)
        if name == "board-clean":
            env["BOARD_CLEAN_BUDGET_S"] = str(max(limit - 10, 1))
        code = run_step(name, mode, limit, env)
        if code:
            print("board-sweep: %s %s" % (name, "timed out" if code == 124 else "exit %s" % code), flush=True)
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
