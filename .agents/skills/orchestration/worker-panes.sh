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
color=1; dir=vertical
for d in ${ids[@]+"${ids[@]}"}; do
  "$orca" terminal split --terminal "$base" --direction "$dir" --command "$here/worker-pane.sh $d $color" --json >/dev/null && echo "pane $d color $color"
  color=$(( color % 6 + 1 )); dir=horizontal
done
