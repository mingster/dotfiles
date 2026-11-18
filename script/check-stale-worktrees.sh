#!/usr/bin/env bash
# Usage: check-stale-worktrees.sh <repo-path>
# Flags worktrees whose work is merged or abandoned (#1188). Read only: removes nothing.
# Prints "<path> <reason> <dirty-count>" per stale worktree; exit 1 if any, else 0.
# Never flags the main worktree, `_checks` / `_checks-*`, or a path listed (relative to $HOME,
# one per line) in the repo's optional `.agents/reusable-worktrees`.
set -uo pipefail
[ $# -eq 1 ] || { echo "Usage: $0 <repo-path>" >&2; exit 2; }
repo=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { echo "check-stale-worktrees: not a git repo: $1" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || gh_missing=1

reusable=()
if [ -f "$repo/.agents/reusable-worktrees" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && reusable+=("$HOME/${line#/}")
  done < "$repo/.agents/reusable-worktrees"
fi
is_reusable() {
  local p=$1 base r
  base=$(basename "$p")
  case "$base" in _checks|_checks-*) return 0 ;; esac
  for r in ${reusable[@]+"${reusable[@]}"}; do [ "$p" = "$r" ] && return 0; done
  return 1
}

# Branch PR state: prints MERGED, CLOSED, OPEN or nothing (no PR / gh unavailable).
pr_state() {
  [ -z "${gh_missing:-}" ] || return 0
  (cd "$repo" && gh pr list --head "$1" --state all --json state --jq '[.[].state] | if index("OPEN") then "OPEN" elif index("MERGED") then "MERGED" elif index("CLOSED") then "CLOSED" else "" end' 2>/dev/null) || true
}

# Dirty count: changed files, ignoring ignored files (porcelain hides them) and lock files.
dirty_count() {
  git -C "$1" status --porcelain 2>/dev/null | awk '{ f = substr($0, 4); if (f !~ /(^|\/)[^\/]*\.lock$/ && f !~ /(^|\/)(package-lock\.json|bun\.lockb?|composer\.lock)$/) n++ } END { print n + 0 }'
}

default_ref=
for r in refs/remotes/origin/main refs/remotes/origin/master; do
  git -C "$repo" rev-parse --verify -q "$r" >/dev/null && { default_ref=$r; break; }
done

found=0
emit() { printf '%s %s %s\n' "$1" "$2" "$3"; found=1; }

flush() {
  [ -n "${wt:-}" ] || return 0
  local path=$wt head=$whead branch=$wbranch detached=$wdetached prunable=$wprunable
  wt=
  if [ -z "${main_seen:-}" ]; then main_seen=1; return 0; fi # the first entry is the main worktree
  is_reusable "$path" && return 0
  if [ -n "$prunable" ] || [ ! -d "$path" ]; then emit "$path" "missing-directory" 0; return 0; fi
  local dirty; dirty=$(dirty_count "$path")
  if [ -n "$branch" ]; then
    local state; state=$(pr_state "$branch")
    case "$state" in
      MERGED) emit "$path" "pr-merged" "$dirty" ;;
      CLOSED) emit "$path" "pr-closed" "$dirty" ;;
      OPEN) ;;
      *)
        # No PR: stale only when the branch was merged into main and is gone from origin.
        if [ -n "$default_ref" ] && ! git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null \
           && git -C "$repo" merge-base --is-ancestor "$head" "$default_ref" 2>/dev/null \
           && [ "$head" != "$(git -C "$repo" rev-parse "$default_ref")" ]; then
          emit "$path" "branch-merged-and-gone" "$dirty"
        fi ;;
    esac
    return 0
  fi
  [ -n "$detached" ] || return 0
  [ "$dirty" -eq 0 ] || { reachable_or_merged "$head" && emit "$path" "detached-merged" "$dirty"; return 0; }
  if reachable_or_merged "$head"; then emit "$path" "detached-merged" 0; fi
}
reachable_or_merged() {
  local head=$1 s
  if [ -n "$default_ref" ] && git -C "$repo" merge-base --is-ancestor "$head" "$default_ref" 2>/dev/null; then return 0; fi
  [ -z "${gh_missing:-}" ] || return 1
  s=$(cd "$repo" && gh pr list --search "$head" --state merged --json headRefOid --jq "[.[] | select(.headRefOid == \"$head\")] | length" 2>/dev/null) || return 1
  [ "${s:-0}" -gt 0 ]
}

wt= whead= wbranch= wdetached= wprunable=
while IFS= read -r line; do
  case "$line" in
    "worktree "*) flush; wt=${line#worktree }; whead= wbranch= wdetached= wprunable= ;;
    "HEAD "*) whead=${line#HEAD } ;;
    "branch "*) wbranch=${line#branch refs/heads/} ;;
    detached) wdetached=1 ;;
    prunable*) wprunable=1 ;;
  esac
done < <(git -C "$repo" worktree list --porcelain; echo)
flush
[ "$found" -eq 0 ]
