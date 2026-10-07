#!/usr/bin/env bash
# Open one colored worker-pane.sh split per active worker of a run, beside the given terminal.
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
# Next color and split direction continue from the panes already in the coordinator's tab.
n=0
if tab=$("$orca" terminal list --json 2>/dev/null | python3 -c '
import sys,json
t=json.load(sys.stdin)["result"]["terminals"]
b=[x for x in t if x.get("handle")==sys.argv[1]]
tab=b[0].get("tabId") if b else None
print(tab or "")
print(sum(1 for x in t if tab and x.get("tabId")==tab))' "$base"); then
  n=$(echo "$tab" | sed -n 2p); n=${n:-0}
fi
[ "$n" -gt 1 ] 2>/dev/null && dir=horizontal || dir=vertical
color=$(( (n > 1 ? n - 1 : 0) % 6 + 1 ))
for d in ${ids[@]+"${ids[@]}"}; do
  "$orca" terminal split --terminal "$base" --direction "$dir" --command "$here/worker-pane.sh $d $color" --json >/dev/null && echo "pane $d color $color"
  color=$(( color % 6 + 1 )); dir=horizontal
done
