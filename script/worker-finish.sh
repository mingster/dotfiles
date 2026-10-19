#!/usr/bin/env bash
# One finish path for a worker: release its dispatch, close its pane, remove its worktree.
# Usage: worker-finish.sh --worktree <path> [--dispatch <id>]...   DRY_RUN=1 only prints.
# Callers decide whether the worktree may go (clean, or its diff saved first); this removes it.
set -euo pipefail
dry=${DRY_RUN:-0}
orca=${ORCA_CLI_COMMAND:-orca}
wt="" dispatches=()
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt=${2:-}; shift 2 ;;
    --dispatch) dispatches+=("${2:-}"); shift 2 ;;
    *) echo "worker-finish: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$wt" ] || { echo "usage: worker-finish.sh --worktree <path> [--dispatch <id>]..." >&2; exit 2; }
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
real() { if [ -d "$1" ]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
wt=$(real "$wt")

if [ ${#dispatches[@]} -eq 0 ] && command -v "$orca" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] && [ "$(real "$path")" = "$wt" ] && dispatches+=("$id")
  done < <("$orca" orchestration worker-list --json 2>/dev/null \
    | jq -r '.result.workers[]? | select(.dispatchStatus != "released") | [.dispatchId, ((.worktreeId // "") | split("::")[1] // "")] | @tsv' 2>/dev/null || true)
fi
if command -v "$orca" >/dev/null 2>&1; then
  for id in ${dispatches[@]+"${dispatches[@]}"}; do
    run "$orca" orchestration worker-release --dispatch "$id" >/dev/null 2>&1 || echo "worker-finish: release of $id failed" >&2
  done
fi
pane_close=${WORKER_PANE_CLOSE:-$HOME/.claude/skills/orca-team/worker-pane-close.sh}
if [ -f "$pane_close" ]; then
  run bash "$pane_close" ${dispatches[@]+"${dispatches[@]}"} >/dev/null 2>&1 || echo "worker-finish: pane close failed" >&2
fi
if [ -d "$wt" ]; then
  run git worktree remove --force -- "$wt"
  run git worktree prune
fi
echo "Finished worker worktree $wt"
