#!/usr/bin/env bash
# Mark completed the Orca tasks of a repo whose issue or PR is already closed or merged.
# Usage: task-sweep.sh --run RUN_ID [--repo OWNER/REPO] [--apply]   (default: dry run; repo from DOTFILES_REPO or the origin remote)
# worker-release settles the worker but leaves its task blocked or failed, so the board keeps showing dead work.
# A blocked or failed task counts only when the brief's Refs line names this repo ("Refs OWNER/REPO#N", or a bare "Refs #N",
# which the dispatch scripts read as the host repo; with no Refs line, a title that starts "#N|") and N is closed on GitHub (an issue, or a merged or closed PR).
# One line per swept task on stdout. A failed orca or gh call skips that task and the script still exits 0.
set -uo pipefail
apply=0 repo=${DOTFILES_REPO:-} run=''
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --run) run=${2:?--run needs a Run id}; shift 2 ;;
    --repo) repo=${2:?--repo needs OWNER/REPO}; shift 2 ;;
    *) echo "Usage: $0 --run RUN_ID [--repo OWNER/REPO] [--apply]" >&2; exit 2 ;;
  esac
done
[ -n "$run" ] || { echo "Usage: $0 --run RUN_ID [--repo OWNER/REPO] [--apply]" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "$repo" ]; then
  url=$(git -C "$here/.." remote get-url origin 2>/dev/null || true)
  repo=$(printf '%s' "$url" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
fi
[ -n "$repo" ] || { echo "task-sweep: no repo (pass --repo)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 || { echo "task-sweep: jq and gh are required" >&2; exit 0; }
orca=${ORCA_CLI_COMMAND:-orca}
listed=$("$orca" orchestration task-list --run "$run" --full --json 2>/dev/null) \
  || { echo "task-sweep: could not list tasks of $run; skipped" >&2; exit 0; }
rows=$(printf '%s' "$listed" | jq -r --arg repo "$repo" '
  .result.tasks[]? | select(.status == "blocked" or .status == "failed")
  | ((.spec // "" | capture("(?m)^Refs (?<r>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#(?<n>[0-9]+)"))
      // (.task_title // "" | capture("^#(?<n>[0-9]+)\\|") | .r = null) // empty) as $ref
  | select($ref.r == null or $ref.r == $repo)
  | "\(.id)\t\($ref.n)\t\(.status)\t\(.task_title // .display_name // "")"' 2>/dev/null) || rows=
n=0 unread=0
while IFS=$'\t' read -r id num status title; do
  [ -n "$id" ] || continue
  state=$(gh api "repos/$repo/issues/$num" --jq .state 2>/dev/null) || { unread=$((unread + 1)); continue; }
  [ "$state" = closed ] || continue
  n=$((n + 1))
  echo "$id $status -> completed ($repo#$num closed) $title"
  [ "$apply" -eq 1 ] || continue
  "$orca" orchestration task-update --run "$run" --id "$id" --status completed \
    --result "swept: $repo#$num is closed" >/dev/null 2>&1 \
    || echo "task-sweep: could not update $id" >&2
done <<<"$rows"
[ "$unread" -eq 0 ] || echo "task-sweep: $unread task(s) kept: their issue number is not in $repo" >&2
echo "task-sweep: $n stale task(s) of $repo$([ "$apply" -eq 1 ] || echo '; dry run, pass --apply to write')"
exit 0
