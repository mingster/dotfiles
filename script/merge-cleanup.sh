#!/usr/bin/env bash
# Cleanup after lead-merge.sh reads MERGED. Run from a checkout of the repo.
# Usage: merge-cleanup.sh --branch <pr head> [--head-sha <merged sha>] [--branch ...]    DRY_RUN=1 only prints.
# Acts by ownership, never by branch name:
# 1. Each merged PR head branch (remote and local). Kept when it has commits outside origin/main,
#    unless its tip is the merged sha.
# 2. Every worktree whose Orca dispatches are all released, whose terminals have all ended (the
#    released workers' panes are closed first), that is clean, and whose commits are all in origin/main.
#    Its branch goes with it.
# A worktree is also kept when it is the current one, named lead-* or rm-*, or when removing it fails.
# A branch is kept when any worktree still has it checked out. Never touches main, master, staging,
# production, the current branch or origin/ refs. Never releases a dispatch. Unsaved changes are kept and listed.
# Every external call (git fetch and push, orca, the pane close helper) is bounded by
# MERGE_CLEANUP_CALL_TIMEOUT_SECONDS (default 60); a call that times out is reported as kept.
# --issue and --pr are accepted and ignored: the caller no longer needs numbers here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dry=${DRY_RUN:-0}
orca=${ORCA_CLI_COMMAND:-orca}
pane_close=${WORKER_PANE_CLOSE:-$HOME/.claude/skills/orca-team/worker-pane-close.sh}
call_timeout=${MERGE_CLEANUP_CALL_TIMEOUT_SECONDS:-60}
branches=() shas=()
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) branches+=("${2:-}"); shas+=(""); shift 2 ;;
    --head-sha)
      [ ${#branches[@]} -gt 0 ] || { echo "merge-cleanup: --head-sha needs a --branch before it" >&2; exit 2; }
      shas[${#shas[@]}-1]=${2:-}; shift 2 ;;
    --issue|--pr) case "${2:-}" in ''|*[!0-9]*) echo "merge-cleanup: $1 must be a number" >&2; exit 2 ;; esac; shift 2 ;;
    *) echo "merge-cleanup: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ ${#branches[@]} -gt 0 ] || { echo "usage: merge-cleanup.sh --branch <name> [--head-sha <sha>] [--branch ...]" >&2; exit 2; }

top=$(cd -P "$(git rev-parse --show-toplevel)" && pwd)
current=$(git symbolic-ref --quiet --short HEAD || true)
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
# Runs a command for at most $call_timeout seconds, in its own process group; exit 124 on timeout.
# Stock macOS has no timeout command.
bounded() {
  python3 - "$call_timeout" "$@" <<'PY'
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True, stdin=subprocess.DEVNULL)
try:
    sys.exit(p.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    sys.exit(124)
PY
}
real() { if [ -d "$1" ]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
# True for main/master/staging/production/HEAD and the current branch, as a bare name, refs/heads/<name>,
# any origin/ ref, or any name whose last path component is one of those (feature/main).
is_protected() {
  local n=${1#refs/heads/} last
  case "$n" in origin/*|refs/*) return 0 ;; esac
  last=${n##*/}
  for n in "$n" "$last"; do
    case "$n" in main|master|staging|production|HEAD) return 0 ;; esac
    [ -z "$current" ] || [ "$n" != "$current" ] || return 0
  done
  return 1
}
keep_protected() { is_protected "$1" || return 1; echo "protected: kept $1"; }

if [ "$dry" = 1 ]; then
  echo "[dry-run] no fetch; using already-fetched refs"
else
  bounded git fetch -q origin >/dev/null 2>&1 || echo "merge-cleanup: fetch failed or timed out; using existing refs" >&2
fi

# Orca inventory, read once: status, worktree path, pane handle and dispatch id of every worker ("-" when empty).
inventory="" inventory_ok=0
if command -v "$orca" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  && raw=$(bounded "$orca" orchestration worker-list --json 2>/dev/null) \
  && inventory=$(jq -r '.result.workers[]? | [(.dispatchStatus // "-"), ((.worktreeId // "") | split("::")[1] // "-"), ((.agentTerminalHandle // "") | if . == "" then "-" else . end), (.dispatchId // "-")] | @tsv' <<<"$raw" 2>/dev/null); then
  inventory_ok=1
fi
# Sets owner_state (none, unreleased or released) and released_ids for a worktree path.
owner_of() {
  local status path handle id seen=0 unreleased=0
  released_ids=()
  while IFS=$'\t' read -r status path handle id; do
    [ "$path" != - ] && [ "$(real "$path")" = "$1" ] || continue
    seen=1
    if [ "$status" = released ]; then released_ids+=("$id"); else unreleased=1; fi
  done <<<"$inventory"
  if [ $seen = 0 ]; then owner_state=none; elif [ $unreleased = 1 ]; then owner_state=unreleased; else owner_state=released; fi
}
wt_of() { git worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'; }
# True when the commit $1 is in origin/main, or equals the merged sha $2.
settled() {
  git merge-base --is-ancestor "$1" origin/main 2>/dev/null && return 0
  [ -n "${2:-}" ] && [ "$(git rev-parse --verify -q "$1^{commit}")" = "$2" ]
}

# Removes the worktree at $1 when it is owned, released, idle, clean and merged. $2 is its label, $3 the merged sha.
# Returns non-zero, after printing why, when it stays.
free_worktree() {
  local wt=$1 label=$2 sha=${3:-} rc
  wt=$(real "$wt")
  if [ "$wt" = "$top" ]; then echo "Kept worktree $wt (current)"; return 1; fi
  case "${wt##*/}" in
    lead-*) echo "protected: kept worktree $wt (lead worktree)"; return 1 ;;
    rm-*) echo "protected: kept worktree $wt (rm worktree)"; return 1 ;;
  esac
  if [ $inventory_ok = 0 ]; then echo "Kept worktree $wt ($label, Orca inventory unavailable)"; return 1; fi
  owner_of "$wt"
  case "$owner_state" in
    none) echo "Kept worktree $wt ($label, no Orca dispatch owns it)"; return 1 ;;
    unreleased) echo "Kept worktree $wt ($label, its dispatch is not released)"; return 1 ;;
  esac
  if ! settled "$(git -C "$wt" rev-parse HEAD)" "$sha"; then
    echo "Kept worktree $wt ($label has commits not in origin/main)"; return 1
  fi
  # Checked before panes close, so a kept worktree keeps the scrollback that explains it.
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=all)" ]; then
    echo "Kept worktree $wt (dirty, $label has unsaved changes)"; return 1
  fi
  if [ -f "$pane_close" ]; then
    if [ "$dry" = 1 ]; then echo "[dry-run] close panes of ${released_ids[*]}"
    else
      rc=0; bounded bash "$pane_close" "${released_ids[@]}" >/dev/null 2>&1 || rc=$?
      if [ $rc = 124 ]; then echo "Kept worktree $wt ($label, closing its panes timed out)"; return 1; fi
    fi
  fi
  rc=0; bounded python3 "$here/worktree-idle.py" "$wt" >/dev/null 2>&1 || rc=$?
  if [ $rc != 0 ]; then
    if [ $rc = 124 ]; then echo "Kept worktree $wt ($label, terminal check timed out)"
    else echo "protected: kept worktree $wt (live terminal or unknown inventory)"; fi
    return 1
  fi
  echo "Remove worktree $wt"
  if [ "$dry" != 1 ]; then
    rc=0; bounded git worktree remove -- "$wt" >/dev/null 2>&1 || rc=$?
    if [ $rc != 0 ]; then echo "Kept worktree $wt ($label, removal failed)"; return 1; fi
    git worktree prune
  fi
}

# Removes one branch, its worktree first. $2 is the merged sha when this is a merged PR head.
drop_branch() {
  local b=$1 sha=${2:-} wt tip rc
  keep_protected "$b" && return 0
  if git show-ref --verify --quiet "refs/heads/$b"; then tip=refs/heads/$b
  elif git show-ref --verify --quiet "refs/remotes/origin/$b"; then tip=refs/remotes/origin/$b
  else return 0; fi
  wt=$(wt_of "$b")
  if [ -n "$wt" ]; then
    free_worktree "$wt" "branch $b" "$sha" || { echo "Kept $b (checked out)"; return 0; }
    if [ "$dry" != 1 ] && [ -n "$(wt_of "$b")" ]; then echo "Kept $b (still checked out)"; return 0; fi
  fi
  if ! settled "$tip" "$sha"; then echo "Kept $b (commits not in origin/main)"; return 0; fi
  if git show-ref --verify --quiet "refs/heads/$b"; then
    echo "Delete local $b"; run git branch -D -- "$b" >/dev/null
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/$b" && ! settled "refs/remotes/origin/$b" "$sha"; then
    echo "Kept remote $b (commits not in origin/main)"
  elif git show-ref --verify --quiet "refs/remotes/origin/$b"; then
    echo "Delete remote $b"
    if [ "$dry" = 1 ]; then echo "[dry-run] git push -q origin --delete $b"
    else
      rc=0; bounded git push -q origin --delete "$b" >/dev/null 2>&1 || rc=$?
      if [ $rc = 124 ]; then echo "Kept remote $b (delete timed out)"; elif [ $rc != 0 ]; then echo "merge-cleanup: remote delete of $b failed" >&2; fi
    fi
  fi
}

handled=" "
for i in "${!branches[@]}"; do
  handled="$handled${branches[$i]} "
  drop_branch "${branches[$i]}" "${shas[$i]}"
done

# Worktrees the dispatch inventory proves finished, on whatever branch they are.
while IFS=$'\t' read -r wt b; do
  [ -n "$wt" ] || continue
  [ "$(real "$wt")" != "$top" ] || continue
  case "$handled" in *" $b "*) [ -z "$b" ] || continue ;; esac
  if [ -n "$b" ]; then drop_branch "$b"; else free_worktree "$wt" "detached head" || true; fi
done < <(git worktree list --porcelain | awk '/^worktree /{if(p!="")print p "\t" b; p=substr($0,10); b=""} /^branch refs\/heads\//{b=substr($0,19)} END{if(p!="")print p "\t" b}')
