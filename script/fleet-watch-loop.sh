#!/usr/bin/env bash
# Run fleet-watch as one background loop, started from the coordinator terminal (#1204).
# Orca fences worker-start to the calling terminal (#1170), so a pass launched from here starts its own workers.
#   nohup bash ~/dotfiles/script/fleet-watch-loop.sh >/dev/null 2>&1 & disown
#   bash ~/dotfiles/script/fleet-watch-loop.sh --status     # exit 0 when a loop is running
#   bash ~/dotfiles/script/fleet-watch-loop.sh --stop
# Config and state default to FLEET_WATCH_CONFIG and FLEET_WATCH_STATE. FLEET_WATCH_INTERVAL is seconds (default 300).
# A second copy exits 0. The pid file lives in FLEET_WATCH_LOOP_DIR (default ~/.local/state/fleet-watch).
set -euo pipefail

usage() { echo "Usage: fleet-watch-loop.sh [--status | --stop]" >&2; }
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  "" | --status | --stop) ;;
  *) usage; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/dotfiles-fresh.sh
. "$here/lib/dotfiles-fresh.sh"
dir=${FLEET_WATCH_LOOP_DIR:-$HOME/.local/state/fleet-watch}
pidfile=$dir/loop.pid
python3=${PYTHON:-python3}

running_pid() {
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

case "${1:-}" in
  --status)
    if pid=$(running_pid); then echo "fleet-watch-loop: running (pid $pid)"; exit 0; fi
    echo "fleet-watch-loop: not running"; exit 1 ;;
  --stop)
    if pid=$(running_pid); then kill "$pid"; echo "fleet-watch-loop: stopped $pid"; fi
    exit 0 ;;
esac

config=${FLEET_WATCH_CONFIG:-}
state=${FLEET_WATCH_STATE:-}
[ -n "$config" ] && [ -n "$state" ] || { echo "fleet-watch-loop: set FLEET_WATCH_CONFIG and FLEET_WATCH_STATE" >&2; exit 2; }

mkdir -p "$dir"
# mkdir is the lock: only one copy wins, and a dead owner's lock is replaced.
lock=$dir/loop.lock
if ! mkdir "$lock" 2>/dev/null; then
  if [ ! -f "$pidfile" ] || running_pid >/dev/null; then echo "fleet-watch-loop: already running" >&2; exit 0; fi
  rm -rf "$lock"; mkdir "$lock" || { echo "fleet-watch-loop: already running" >&2; exit 0; }
fi
echo $$ >"$pidfile"
trap 'rm -rf "$lock" "$pidfile"' EXIT
trap 'exit 0' TERM INT

while :; do
  "$python3" "$here/fleet-watch.py" --config "$config" --state "$state" || echo "fleet-watch-loop: pass exited $?" >&2
  [ -z "${FLEET_WATCH_LOOP_ONCE:-}" ] || exit 0
  sleep "${FLEET_WATCH_INTERVAL:-300}" &
  wait $!
done
