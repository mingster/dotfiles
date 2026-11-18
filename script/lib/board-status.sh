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

# board_display_name_set <selector> <name> [environment]
# Show the worker title on the board card instead of the worktree --name. Warns and returns 0 on failure.
board_display_name_set() {
  local selector=$1 name=$2 environment=${3:-} args
  args=(worktree set --worktree "$selector" --display-name "$name")
  [ -z "$environment" ] || args+=(--environment "$environment")
  "${ORCA_CLI_COMMAND:-orca}" "${args[@]}" >/dev/null 2>&1 \
    || echo "board-status: could not set the display name on $selector" >&2
  return 0
}

# board_status_complete_issue <environment> <head-branch> <id>...
# Mark completed every worktree of a shipped PR's issue: the one on the PR branch, plus builder, verify and
# rework worktrees named <role>-<id> with an optional -2..-n copy suffix (<id> is the issue or PR number).
# Selects by path from `worktree list`: the branch: selector failed on every ship. Warns and returns 0 on failure.
board_status_complete_issue() {
  local environment=$1 branch=$2 pattern="" id listed path orca=${ORCA_CLI_COMMAND:-orca} args
  shift 2
  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] && pattern+="${pattern:+|}$id"
  done
  args=(worktree list --json)
  [ -z "$environment" ] || args=(worktree list --environment "$environment" --json)
  listed=$("$orca" "${args[@]}" 2>/dev/null) || { echo "board-status: could not list worktrees to complete" >&2; return 0; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    board_status_set "path:$path" completed "$environment"
  done < <(printf '%s' "$listed" | jq -r --arg b "$branch" --arg p "$pattern" '
    .result.worktrees[]?
    | select(((.branch // "") | sub("^refs/heads/"; "")) == $b
        or ($p != "" and ((.path // "") | split("/") | last | test("^(issue|builder|verify|rework)-(" + $p + ")(-[0-9]+)?$"))))
    | .path // empty' 2>/dev/null)
  return 0
}
