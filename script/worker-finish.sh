#!/usr/bin/env bash
# One finish path for a worker: release its dispatch, close its pane, remove its worktree.
# Usage: worker-finish.sh --worktree <path> [--dispatch <id>]... [--skip-head-checks "<reason>"]   DRY_RUN=1 only prints.
# Head-checks run first and a failure refuses everything. A head already in origin/main, or a merged PR, skips them (post-merge cleanup must not block). Callers decide whether the worktree may go (clean, or its diff saved first); this removes it.
set -euo pipefail
dry=${DRY_RUN:-0}
orca=${ORCA_CLI_COMMAND:-orca}
wt="" dispatches=() skip="" skip_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt=${2:-}; shift 2 ;;
    --dispatch) dispatches+=("${2:-}"); shift 2 ;;
    --skip-head-checks) skip_set=1; skip=${2:-}; [ $# -ge 2 ] && shift; shift ;;
    *) echo "worker-finish: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$wt" ] || { echo "usage: worker-finish.sh --worktree <path> [--dispatch <id>]..." >&2; exit 2; }
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
real() { if [ -d "$1" ]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
wt=$(real "$wt")
# Prints why the worktree head is already merged; fails when it is not.
merged() {
  git -C "$wt" fetch -q origin main 2>/dev/null || true
  if git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then echo "HEAD is already in origin/main"; return 0; fi
  [ "$(cd "$wt" && gh pr view --json state -q .state 2>/dev/null)" = MERGED ] && echo "its PR is already merged"
}

if [ "$skip_set" = 1 ]; then
  [ -n "$skip" ] || { echo "worker-finish: --skip-head-checks needs a reason" >&2; exit 2; }
  echo "worker-finish: skipping head-checks: $skip"
else
  checks=${HEAD_CHECKS:-$HOME/dotfiles/script/head-checks.sh}
  if why=$(merged); then
    echo "worker-finish: skipping head-checks, $why"
  elif [ "$dry" = 1 ]; then
    echo "[dry-run] $checks --repo $wt --ref HEAD --base origin/main"
  elif ! "$checks" --repo "$wt" --ref HEAD --base origin/main; then
    echo "worker-finish: head-checks failed, refusing worker_done" >&2
    exit 1
  fi
fi

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
