#!/usr/bin/env bash
# Preview finished work cleanup; --apply performs the proposed changes.
set -euo pipefail
apply=0
repo=.
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0 ;;
    --apply) apply=1 ;;
    --repo) [ $# -ge 2 ] || { echo 'Missing --repo path' >&2; exit 2; }; repo=$2; shift ;;
    -h|--help) echo 'Usage: wrap-up.sh [--dry-run|--apply] [--repo <path>]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo 'wrap-up requires jq' >&2; exit 1; }
repo=$(git -C "$repo" rev-parse --show-toplevel)
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ "$apply" -eq 1 ]; then
  git fetch --prune origin
else
  echo 'Dry run: fetch preview only; eligibility uses existing origin/main.'
  git fetch --dry-run --prune origin
fi
git rev-parse --verify origin/main >/dev/null
# One PR lookup for all local and remote branches. An open PR wins over an older closed PR.
if ! gh pr list --state all --limit 1000 --json headRefName,headRefOid,state > "$tmp/prs"; then
  echo 'Warning: PR lookup unavailable; using ancestry only.' >&2
  echo '[]' > "$tmp/prs"
fi
jq -e 'type == "array"' "$tmp/prs" >/dev/null
jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | select(any(.[]; .state == "MERGED" or .state == "CLOSED")) | .[0].headRefName' "$tmp/prs" > "$tmp/closed"
jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | .[] | select(.state == "MERGED" or .state == "CLOSED") | .headRefOid // empty' "$tmp/prs" > "$tmp/closed-heads"
: > "$tmp/active"
orca=${ORCA_CLI_COMMAND:-orca}
if command -v "$orca" >/dev/null 2>&1; then
  if "$orca" terminal list --json > "$tmp/terminals" && jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$tmp/terminals" >/dev/null; then
    # Unknown ownership is retained too: a live terminal can belong to another Run.
    : > "$tmp/worker-pages"
    cursor=''
    while :; do
      args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
      if ! "$orca" orchestration worker-list ${args[@]+"${args[@]}"} --json > "$tmp/workers"; then
        echo 'Warning: dispatch discovery failed; retaining all worktrees.' >&2
        echo '*' >> "$tmp/active"; break
      fi
      if ! jq -e '.ok != false and (.result.workers | type == "array")' "$tmp/workers" >/dev/null; then
        echo '*' >> "$tmp/active"; break
      fi
      cat "$tmp/workers" >> "$tmp/worker-pages"
      while IFS= read -r dispatch; do
        if "$orca" orchestration worker-show --dispatch "$dispatch" --json > "$tmp/show"; then
          jq -r 'select(.result.dispatch.status as $s | ["completed","failed","cancelled","released"] | index($s) | not) | .result | (.terminal.cwd // .terminal.worktreePath // empty), ((.worker.worktreeId // "") | split("::")[1] // empty)' "$tmp/show" >> "$tmp/active"
        else
          echo '*' >> "$tmp/active"
        fi
      done < <(jq -r '.result.workers[]? | select(.dispatchStatus as $s | ["completed","failed","cancelled","released"] | index($s) | not) | .dispatchId // empty' "$tmp/workers")
      cursor=$(jq -r 'if .result.page.hasMore then .result.page.nextCursor // empty else empty end' "$tmp/workers")
      [ -n "$cursor" ] || break
    done
    # Discard terminals positively owned only by settled dispatches. Unknown owners stay safe.
    jq -s '[.[].result.workers[]] | group_by(.agentTerminalHandle) | map(select(all(.[]; .dispatchStatus as $s | ["completed","failed","cancelled","released"] | index($s))) | .[0].agentTerminalHandle) | map(select(. != null))' "$tmp/worker-pages" > "$tmp/ended-handles"
    jq -r --slurpfile ended "$tmp/ended-handles" '.result.terminals[] | select(.handle as $h | $ended[0] | index($h) | not) | .cwd // .worktreePath // empty' "$tmp/terminals" >> "$tmp/active"
  else
    echo 'Warning: Orca terminal inventory incomplete; retaining all worktrees.' >&2
    echo '*' >> "$tmp/active"
  fi
else
  echo 'Warning: Orca unavailable; skipping active dispatch check.' >&2
fi
# Git canonicalizes paths; Orca can report the symlink spelling (for example /var on macOS).
while IFS= read -r active_path; do
  if [ "$active_path" = '*' ]; then echo '*'
  elif [ -d "$active_path" ]; then (cd "$active_path" && pwd -P)
  else printf '%s\n' "$active_path"
  fi
done < "$tmp/active" > "$tmp/active-normalized"
mv "$tmp/active-normalized" "$tmp/active"
protected() {
  case "$1" in main|master|staging|production|web2/*|*/staging|*/production|HEAD|lead-queue|*/lead-queue) return 0 ;; esac
  return 1
}
eligible() {
  if git merge-base --is-ancestor "$1" origin/main; then reason=ancestor; return 0; fi
  if [ -n "$2" ] && grep -Fxq -- "$2" "$tmp/closed"; then reason='closed PR'; return 0; fi
  return 1
}
active_worktree() {
  local active_path
  while IFS= read -r active_path; do
    case "$active_path" in
      '*'|"$1"|"$1"/*) return 0 ;;
    esac
  done < "$tmp/active"
  return 1
}
removed=0; local_deleted=0; remote_deleted=0; kept=0
keep() { printf 'Kept %s (%s)\n' "$1" "$2"; kept=$((kept+1)); }
: > "$tmp/kept-branches"
git worktree list --porcelain -z > "$tmp/worktrees"
main_checkout=''
path=''; branch=''; head=''; locked=0
# A settled dispatch is not a dead session: the lead and correction-pass workers keep working after their first
# worker_done (2026-10-26: a lead's clean detached worktree was removed mid-edit). Keep a worktree whose git
# HEAD or index, or any file outside node_modules, .next and .git, changed in the last WRAP_UP_RECENT_MIN minutes.
recent_worktree() {
  local min=${WRAP_UP_RECENT_MIN:-30} gd
  [ "$min" -gt 0 ] || return 1
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  [ -n "$(find "$gd/HEAD" "$gd/index" -mmin -"$min" 2>/dev/null)" ] && return 0
  [ -n "$(find "$1" \( -name node_modules -o -name .next -o -name .git \) -prune -o -type f -mmin -"$min" -print -quit 2>/dev/null)" ]
}
process_worktree() {
  local why=''
  if [ -z "$main_checkout" ]; then main_checkout=$path; why='main checkout'
  elif [ -z "$branch" ] && case "${path##*/}" in _*) true ;; *) false ;; esac; then why='script-owned _ worktree'
  elif protected "$branch"; then why='protected'
  elif [ "${path##*/}" = lead-queue ]; then why='lead-queue lane'
  elif [ "$locked" -eq 1 ]; then why='locked'
  elif ! git -C "$path" status --porcelain --untracked-files=all > "$tmp/status"; then why='unreadable'
  elif [ -s "$tmp/status" ]; then why='dirty'
  elif active_worktree "$path"; then why='active or unknown Orca terminal'
  elif recent_worktree "$path"; then why="changed in the last ${WRAP_UP_RECENT_MIN:-30} minutes"
  elif [ -z "$branch" ]; then
    # A PR match alone must never discard a commit absent from all remote branches.
    git for-each-ref --contains "$head" --format='%(refname)' refs/remotes > "$tmp/containing-remotes"
    if [ ! -s "$tmp/containing-remotes" ]; then why='detached with unmerged commits'
    elif git merge-base --is-ancestor "$head" origin/main; then reason='detached at merged commit'
    elif grep -Fxq -- "$head" "$tmp/closed-heads"; then reason='detached at closed PR head'
    else why='detached with unmerged commits'
    fi
  elif ! eligible "refs/heads/$branch" "$branch"; then why='unmerged without closed PR'
  fi
  if [ -n "$why" ]; then
    keep "worktree $path" "$why"
    [ -z "$branch" ] || printf '%s\n' "$branch" >> "$tmp/kept-branches"
  else
    printf 'Remove worktree %s (%s)\n' "$path" "$reason"
    [ "$apply" -eq 0 ] || git worktree remove -- "$path"
    removed=$((removed+1))
  fi
}
while IFS= read -r -d '' field; do
  case "$field" in
    'worktree '*) path=${field#worktree }; branch=''; head=''; locked=0 ;;
    'HEAD '*) head=${field#HEAD } ;;
    'branch refs/heads/'*) branch=${field#branch refs/heads/} ;;
    locked*) locked=1 ;;
    '') process_worktree ;;
  esac
done < "$tmp/worktrees"
[ "$apply" -eq 0 ] || git worktree prune
while IFS= read -r branch; do
  if protected "$branch" || grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "local $branch" 'protected or checked out in kept worktree'
  elif eligible "refs/heads/$branch" "$branch"; then
    printf 'Delete local %s (%s)\n' "$branch" "$reason"
    if [ "$apply" -eq 1 ]; then
      if [ "$reason" = ancestor ]; then
        # -d checks HEAD/upstream, so give it the authoritative merge target.
        git -c "branch.$branch.remote=origin" -c "branch.$branch.merge=refs/heads/main" branch -d -- "$branch"
      else
        git branch -D -- "$branch"
      fi
    fi
    local_deleted=$((local_deleted+1))
  else keep "local $branch" 'unmerged without closed PR'
  fi
done < <(git for-each-ref --format='%(refname:strip=2)' refs/heads)
batch=()
flush_remote() {
  [ ${#batch[@]} -gt 0 ] || return 0
  [ "$apply" -eq 0 ] || git push origin --delete "${batch[@]}"
  batch=()
}
while IFS= read -r ref; do
  branch=${ref#refs/remotes/origin/}
  if protected "$branch" || grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "remote $branch" 'protected or checked out in kept worktree'
  elif eligible "$ref" "$branch"; then
    printf 'Delete remote %s (%s)\n' "$branch" "$reason"
    batch+=("$branch"); remote_deleted=$((remote_deleted+1))
    [ ${#batch[@]} -lt 50 ] || flush_remote
  else keep "remote $branch" 'unmerged without closed PR'
  fi
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)
flush_remote
pane_script="$HOME/.claude/skills/orca-team/worker-pane-close.sh"
if [ -f "$pane_script" ]; then
  echo 'Close ended worker panes'
  [ "$apply" -eq 0 ] || bash "$pane_script"
fi
if [ "$(git -C "$main_checkout" symbolic-ref --quiet --short HEAD || true)" = main ] && [ -z "$(git -C "$main_checkout" status --porcelain --untracked-files=all)" ]; then
  echo 'Fast forward main checkout'
  [ "$apply" -eq 0 ] || git -C "$main_checkout" pull --ff-only origin main
else keep 'main update' 'checkout is not on main or is dirty'
fi
if [ "$apply" -eq 0 ]; then echo 'Planned counts (nothing deleted):'; else echo 'Completed counts:'; fi
printf 'removed worktrees=%s deleted local=%s deleted remote=%s kept=%s\n' "$removed" "$local_deleted" "$remote_deleted" "$kept"
