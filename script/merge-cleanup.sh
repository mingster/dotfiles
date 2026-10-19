#!/usr/bin/env bash
# Cleanup after lead-merge.sh reads MERGED. Run from a checkout of the repo.
# Usage: merge-cleanup.sh --branch <pr head> [--issue N]    DRY_RUN=1 only prints.
# 1. Remove the PR head: remote branch, its worktree (kept when dirty), local branch.
# 2. With an issue: remove clean worktrees and branches whose name has N as a whole number
#    and that are in origin/main or belong to a released worker. Dirty worktrees get their
#    `git diff HEAD` plus untracked files saved to $MERGE_CLEANUP_REF_DIR/<branch>.patch
#    (and <branch>.untracked.txt listing them) first; if saving fails the worktree is kept.
#    DRY_RUN=1 does no fetch, prune, delete or write.
# 3. Prune recovery/* branches whose last commit is older than 7 days.
# Never touches main, master, staging, production or the current branch.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dry=${DRY_RUN:-0}
orca=${ORCA_CLI_COMMAND:-orca}
ref_dir=${MERGE_CLEANUP_REF_DIR:-$HOME/orca/workspaces/_ref}
branch="" issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) branch=${2:-}; shift 2 ;;
    --issue) issue=${2:-}; shift 2 ;;
    *) echo "merge-cleanup: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$branch" ] || { echo "usage: merge-cleanup.sh --branch <name> [--issue N]" >&2; exit 2; }
case "$issue" in *[!0-9]*) echo "merge-cleanup: --issue must be a number" >&2; exit 2 ;; esac

top=$(cd -P "$(git rev-parse --show-toplevel)" && pwd)
current=$(git symbolic-ref --quiet --short HEAD || true)
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
protected() {
  case "$1" in main|master|staging|production|HEAD|origin/*) return 0 ;; esac
  [ "$1" != "$current" ] || return 0
  return 1
}
if [ "$dry" = 1 ]; then
  echo "[dry-run] no fetch; using already-fetched refs"
else
  git fetch -q origin >/dev/null 2>&1 || echo "merge-cleanup: fetch failed; using existing refs" >&2
fi

# Worktree path of each branch, and released worktree paths.
wt_of() { git worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'; }
released=""
if command -v "$orca" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  released=$("$orca" orchestration worker-list --json 2>/dev/null \
    | jq -r '.result.workers[]? | select(.dispatchStatus == "released") | (.worktreeId // "") | split("::")[1] // empty' 2>/dev/null || true)
fi
is_released() {
  local p
  [ -n "$released" ] || return 1
  while IFS= read -r p; do
    [ -d "$p" ] && [ "$(cd -P "$p" && pwd)" = "$1" ] && return 0
  done <<<"$released"
  return 1
}
in_main() {
  local r=refs/heads/$1
  git show-ref --verify --quiet "$r" || r=refs/remotes/origin/$1
  git merge-base --is-ancestor "$r" origin/main 2>/dev/null
}

# Remove one branch fully. $2 = "force" when the worktree may be dirty (diff saved first).
drop() {
  local b=$1 mode=${2:-clean} wt dirty
  protected "$b" && { echo "Kept $b (protected or current)"; return 0; }
  wt=$(wt_of "$b")
  if [ -n "$wt" ]; then
    wt=$(cd -P "$wt" && pwd)
    if [ "$wt" = "$top" ]; then echo "Kept worktree $wt (current)"; return 0; fi
    dirty=$(git -C "$wt" status --porcelain --untracked-files=all)
    if [ -n "$dirty" ]; then
      if [ "$mode" != force ]; then
        echo "Kept worktree $wt (dirty, branch $b)"; return 0
      fi
      mkdir_patch "$b" "$wt" || { echo "merge-cleanup: could not save $b; worktree $wt kept" >&2; return 0; }
    fi
    DRY_RUN=$dry bash "$here/worker-finish.sh" --worktree "$wt"
  fi
  if git show-ref --verify --quiet "refs/heads/$b"; then
    echo "Delete local $b"; run git branch -D -- "$b" >/dev/null
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
    echo "Delete remote $b"; run git push -q origin --delete "$b" || echo "merge-cleanup: remote delete of $b failed" >&2
  fi
}
# Saves tracked changes, untracked files under 1 MB (as new-file hunks) and a list of all
# untracked files. Returns non-zero when anything could not be written.
mkdir_patch() {
  local base="$ref_dir/${1//\//-}" f
  echo "Save diff of $1 to $base.patch"
  [ "$dry" = 1 ] && return 0
  mkdir -p "$ref_dir" || return 1
  git -C "$2" diff HEAD > "$base.patch" || return 1
  : > "$base.untracked.txt" || return 1
  while IFS= read -r -d '' f; do
    printf '%s\n' "$f" >> "$base.untracked.txt" || return 1
    if [ "$(wc -c < "$2/$f")" -lt 1048576 ]; then
      (cd "$2" && git diff --no-index -- /dev/null "$f" >> "$base.patch" || [ $? -eq 1 ]) || return 1
    else
      printf '%s\n' "$f (over 1 MB, not in patch)" >> "$base.untracked.txt" || return 1
    fi
  done < <(git -C "$2" ls-files -o --exclude-standard -z)
  [ -s "$base.untracked.txt" ] || rm -f "$base.untracked.txt"
  return 0
}

drop "$branch"

if [ -n "$issue" ]; then
  re="(^|[^0-9])${issue}([^0-9]|\$)"
  while IFS= read -r b; do
    [[ "$b" =~ $re ]] || continue
    protected "$b" && continue
    [ "$b" != "$branch" ] || continue
    wt=$(wt_of "$b"); wt_real=""
    [ -z "$wt" ] || wt_real=$(cd -P "$wt" && pwd)
    if in_main "$b" || { [ -n "$wt_real" ] && is_released "$wt_real"; }; then
      drop "$b" force
    else
      echo "Kept $b (not in main and worker not released)"
    fi
  done < <({ git for-each-ref --format='%(refname:strip=2)' refs/heads
             git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin; } | sort -u)
fi

cutoff=$(( $(date +%s) - 7*86400 ))
while read -r ref ts; do
  b=${ref#refs/heads/}; b=${b#refs/remotes/origin/}
  [ "$ts" -lt "$cutoff" ] || continue
  if git show-ref --verify --quiet "refs/heads/$b"; then
    if [ -n "$(wt_of "$b")" ]; then echo "Kept $b (checked out)"; continue; fi
    echo "Delete local $b (older than 7 days)"; run git branch -D -- "$b" >/dev/null
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
    echo "Delete remote $b (older than 7 days)"; run git push -q origin --delete "$b" || true
  fi
done < <(git for-each-ref --format='%(refname) %(committerdate:unix)' 'refs/heads/recovery/*' 'refs/remotes/origin/recovery/*')
