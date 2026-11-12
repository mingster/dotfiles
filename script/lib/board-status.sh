#!/usr/bin/env bash
# Set the Orca board status of a worktree. Sourced by worker-startup.sh, start-cursor-worker.sh, ship.sh.
# board_status_set <selector> <todo|in-progress|in-review|completed> [environment]
# A failed call warns and returns 0: the board is a view, and it never blocks a start or a merge.
board_status_set() {
  local selector=$1 status=$2 environment=${3:-} args
  args=(worktree set --worktree "$selector" --workspace-status "$status")
  [ -z "$environment" ] || args+=(--environment "$environment")
  "${ORCA_CLI_COMMAND:-orca}" "${args[@]}" >/dev/null 2>&1 \
    || echo "board-status: could not set $status on $selector" >&2
  return 0
}
