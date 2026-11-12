#!/usr/bin/env bash
# One time backfill of the Orca board status from each worktree's pull request.
# Usage: orca-board-backfill.sh [--dry-run | --apply] [--environment ENV]
# A branch with a merged or closed PR becomes completed, a branch with an open PR becomes in-review, any other
# worktree is left alone. The main worktree and detached worktrees are never touched. Dry run is the default.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/board-status.sh
. "$here/lib/board-status.sh"
orca=${ORCA_CLI_COMMAND:-orca}
apply=0 environment=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0; shift ;;
    --apply) apply=1; shift ;;
    --environment) [ $# -ge 2 ] || { echo "orca-board-backfill: --environment needs a value" >&2; exit 2; }; environment=$2; shift 2 ;;
    *) echo "Usage: orca-board-backfill.sh [--dry-run | --apply] [--environment ENV]" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
list_args=(worktree list --json)
[ -z "$environment" ] || list_args+=(--environment "$environment")
"$orca" "${list_args[@]}" > "$tmp/worktrees" || { echo "orca-board-backfill: orca worktree list failed" >&2; exit 1; }
jq -e '.ok != false and (.result.worktrees | type == "array") and (.result.truncated != true)' "$tmp/worktrees" >/dev/null \
  || { echo "orca-board-backfill: worktree list is unreadable or truncated" >&2; exit 1; }

completed=0 in_review=0 unchanged=0
# One gh call per GitHub project: branch name and PR state, open first.
while IFS= read -r project; do
  [ -n "$project" ] || continue
  gh pr list --repo "${project#github:}" --state all --limit 1000 --json headRefName,state > "$tmp/prs" \
    || { echo "orca-board-backfill: gh pr list failed for ${project#github:}" >&2; exit 1; }
  while IFS=$'\t' read -r path branch status; do
    target=$(jq -r --arg b "$branch" '[.[] | select(.headRefName == $b) | .state] as $s
      | if ($s | index("OPEN")) then "in-review" elif ($s | length) > 0 then "completed" else "" end' "$tmp/prs")
    if [ -z "$target" ] || [ "$target" = "$status" ]; then
      unchanged=$((unchanged + 1))
      continue
    fi
    printf '%s %s -> %s (%s)\n' "$([ "$apply" -eq 1 ] && echo set || echo '[dry-run] would set')" "$path" "$target" "$branch"
    [ "$apply" -eq 0 ] || board_status_set "path:$path" "$target" "$environment"
    if [ "$target" = completed ]; then completed=$((completed + 1)); else in_review=$((in_review + 1)); fi
  done < <(jq -r --arg p "$project" '.result.worktrees[]
    | select(.projectId == $p and (.isMainWorktree // false) == false and ((.branch // "") != ""))
    | [.path, (.branch | sub("^refs/heads/"; "")), (.workspaceStatus // "")] | @tsv' "$tmp/worktrees")
done < <(jq -r '[.result.worktrees[] | select((.projectId // "") | startswith("github:")) | .projectId] | unique[]' "$tmp/worktrees")
# Worktrees with no GitHub project or no branch cannot be matched to a PR.
other=$(jq '[.result.worktrees[] | select((.isMainWorktree // false) == false and ((((.projectId // "") | startswith("github:")) and ((.branch // "") != "")) | not))] | length' "$tmp/worktrees")
unchanged=$((unchanged + other))
printf '%s: completed=%s in-review=%s unchanged=%s\n' "$([ "$apply" -eq 1 ] && echo applied || echo dry-run)" "$completed" "$in_review" "$unchanged"
