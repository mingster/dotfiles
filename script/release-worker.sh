#!/usr/bin/env bash
# Release a worker by hand: worker-stop, worker-release on its host and here, then close its terminal on the
# host that holds it, and confirm the terminal is gone (#1947, #1958).
# Usage: release-worker.sh [--live] <dispatch, task or terminal id fragment>
# One match only; the coordinator's terminal and other live workers' terminals are never closed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
live=()
if [ "${1:-}" = "--live" ]; then live=(--live); shift; fi
[ $# -eq 1 ] || { echo "Usage: $0 [--live] <dispatch-or-terminal-fragment>" >&2; exit 2; }
exec python3 "$here/fleet-watch.py" --release-worker "$1" ${live[@]+"${live[@]}"}
