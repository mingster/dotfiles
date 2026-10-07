#!/usr/bin/env bash
# Open one role-colored worker-pane.sh split per active worker of a run, beside the given terminal.
# Usage: worker-panes.sh <run_id> <coordinator_terminal_handle> [dispatch_id ...]
set -u
run="$1"; base="$2"; shift 2; orca="${ORCA_CLI_COMMAND:-orca}"
here="$(cd "$(dirname "$0")" && pwd)"
ids=(); [ $# -gt 0 ] && ids=("$@")
if [ ${#ids[@]} -eq 0 ]; then
  while IFS= read -r x; do ids+=("$x"); done < <("$orca" orchestration worker-list --run "$run" --limit 100 --json 2>/dev/null | python3 -c '
import sys,json
r=json.load(sys.stdin)["result"]
for w in r.get("workers", []):
  if w.get("dispatchStatus") in ("dispatched", "running", "pending"): print(w["dispatchId"])')
fi
state="${ORCA_PANE_STATE_DIR:-$HOME/.cache/orca-worker-panes}"; mkdir -p "$state"
# Layout: coordinator on the left, one right column of worker panes. The first pane splits the coordinator
# to the right (vertical); later panes split the newest live worker pane below it (horizontal).
# Live worker panes come from the state files, minus handles that orca terminal list no longer shows.
target="$base"; dir=vertical
live=$("$orca" terminal list --json 2>/dev/null | python3 -c '
import sys,json
try: print("\n".join(x.get("handle","") for x in json.load(sys.stdin)["result"]["terminals"]))
except Exception: pass')
if [ -n "$live" ]; then
  for f in $(ls -t "$state" 2>/dev/null); do
    [ -f "$state/$f" ] || continue
    h=$(head -n 1 "$state/$f")
    if [ -n "$h" ] && [ "$h" != "$base" ] && printf '%s\n' "$live" | grep -qxF "$h"; then target="$h"; dir=horizontal; break; fi
  done
fi
for d in ${ids[@]+"${ids[@]}"}; do
  if rec=$("$orca" terminal split --terminal "$target" --direction "$dir" --command "$here/worker-pane.sh $d" --json); then
    # Record the pane handle so the coordinator can close it (worker-pane-close.sh).
    h=$(printf '%s' "$rec" | python3 -c '
import sys,json
def find(o):
  if isinstance(o,dict):
    v=o.get("handle")
    if isinstance(v,str) and v: return v
    for x in o.values():
      r=find(x)
      if r: return r
  elif isinstance(o,list):
    for x in o:
      r=find(x)
      if r: return r
try: print(find(json.load(sys.stdin)) or "")
except Exception: print("")')
    [ -n "$h" ] && { printf '%s\n' "$h" > "$state/$d"; target="$h"; dir=horizontal; }
    echo "pane $d"
  fi
done
