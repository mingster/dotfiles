#!/usr/bin/env bash
# elon-tick.sh --run <run_id>: one read only coordinator tick (#1790).
# Runs the Wake loop checks and every check in docs/agents/elon-mistakes.md, then prints a numbered
# ACTION list or `OK nothing to do`. Exit 0 nothing to do, 1 actions printed, 2 usage or config error.
# It starts, releases, labels and edits nothing. Inputs are listed at the top of script/elon-tick.py.
set -u
exec python3 "$(cd "$(dirname "$0")" && pwd -P)/elon-tick.py" "$@"
