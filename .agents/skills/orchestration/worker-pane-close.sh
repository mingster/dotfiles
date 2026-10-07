#!/usr/bin/env bash
# Close the worker panes that worker-panes.sh recorded. The coordinator runs this after worker-release.
# Usage: worker-pane-close.sh <dispatch_id> [...]   close those panes
#        worker-pane-close.sh                       close every recorded pane whose dispatch has ended
# Missing or already-closed panes are not errors. State: $ORCA_PANE_STATE_DIR (default ~/.cache/orca-worker-panes/<dispatch_id>).
set -u
orca="${ORCA_CLI_COMMAND:-orca}"
state="${ORCA_PANE_STATE_DIR:-$HOME/.cache/orca-worker-panes}"
close_one() {
  local f="$state/$1" h
  [ -f "$f" ] || return 0
  h=$(head -n 1 "$f")
  [ -n "$h" ] && "$orca" terminal close --terminal "$h" >/dev/null 2>&1
  rm -f "$f"; echo "closed $1"
}
if [ $# -gt 0 ]; then
  for d in "$@"; do close_one "$d"; done
  exit 0
fi
for f in "$state"/*; do
  [ -f "$f" ] || continue
  d=$(basename "$f")
  status=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null | python3 -c '
import sys,json
try: print(json.load(sys.stdin)["result"]["dispatch"]["status"])
except Exception: print("")')
  case "$status" in ""|dispatched|running|pending) ;; *) close_one "$d";; esac
done
exit 0
