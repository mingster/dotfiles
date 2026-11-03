#!/usr/bin/env bash
# worker-start-check.sh <dispatch_id> [seconds]
# Run after every `orca orchestration worker-start`. Exit 0 when the Dispatch is running or settled,
# exit 1 when it failed or was not accepted within the wait (default 120 seconds). Prints the state.
set -u
dispatch=${1:-}; wait=${2:-120}
[ -n "$dispatch" ] || { echo "usage: worker-start-check.sh <dispatch_id> [seconds]" >&2; exit 2; }
command -v jq >/dev/null || { echo "worker-start-check requires jq" >&2; exit 2; }
end=$((SECONDS + wait))
while :; do
  out=$(orca orchestration worker-show --dispatch "$dispatch" --json 2>&1)
  state=$(jq -r '.result.state // .result.worker.state // .result.dispatch.state // empty' <<<"$out" 2>/dev/null)
  case "$state" in
    running|ready|accepted|succeeded|completed) echo "ok $dispatch $state"; exit 0 ;;
    failed|stopped|abandoned|rejected) echo "FAILED $dispatch $state"; exit 1 ;;
  esac
  [ "$SECONDS" -ge "$end" ] && { echo "FAILED $dispatch not accepted in ${wait}s (state: ${state:-unknown})"; exit 1; }
  sleep 5
done
