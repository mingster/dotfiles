#!/usr/bin/env bash
# Preview finished work cleanup; --apply performs the proposed changes.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
apply=0
fleet=0
worktrees_only=0
repo=.
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0 ;;
    --apply) apply=1 ;;
    --stale) : ;; # Accepted for compatibility; stale cleanup is part of every apply.
    --fleet) fleet=1 ;;
    --worktrees-only) worktrees_only=1 ;;
    --repo) [ $# -ge 2 ] || { echo 'Missing --repo path' >&2; exit 2; }; repo=$2; shift ;;
    -h|--help) echo 'Usage: wrap-up.sh [--dry-run|--apply] [--stale] [--fleet] [--repo <path>]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$fleet" -eq 0 ] || [ "$worktrees_only" -eq 0 ] || { echo 'wrap-up: --fleet and --worktrees-only exclude each other' >&2; exit 2; }
# A fake orca CLI means a test: never let --apply reach the real temp roots from there.
if [ "$apply" -eq 1 ] && [ -n "${ORCA_CLI_COMMAND:-}" ] && { [ -z "${WRAP_UP_SCRATCH_ROOT+x}" ] || [ -z "${WRAP_UP_LOOSE_ROOT+x}" ]; }; then
  echo 'wrap-up: ORCA_CLI_COMMAND is set (test mode); set WRAP_UP_SCRATCH_ROOT and WRAP_UP_LOOSE_ROOT before --apply' >&2; exit 2
fi
command -v jq >/dev/null || { echo 'wrap-up requires jq' >&2; exit 1; }
repo=$(git -C "$repo" rev-parse --show-toplevel)
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Preview also refreshes tracking refs; only apply changes branches or worktrees.
git fetch --prune origin
git for-each-ref --format='%(refname) %(objectname)' refs/remotes/origin > "$tmp/remote-planned"
git rev-parse --verify origin/main >/dev/null
# One PR lookup for all local and remote branches. An open PR wins over an older closed PR.
pr_ok=1
if ! gh pr list --state all --limit 1000 --json headRefName,headRefOid,state > "$tmp/prs"; then
  echo 'Warning: PR lookup unavailable; using ancestry only, stale branches not listed.' >&2
  echo '[]' > "$tmp/prs"; pr_ok=0
fi
jq -e 'type == "array"' "$tmp/prs" >/dev/null
jq -r '.[] | select(.state == "OPEN") | .headRefName' "$tmp/prs" | sort -u > "$tmp/open"
jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | select(any(.[]; .state == "MERGED" or .state == "CLOSED")) | .[0].headRefName' "$tmp/prs" > "$tmp/closed"
jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | .[] | select(.state == "MERGED" or .state == "CLOSED") | .headRefOid // empty' "$tmp/prs" > "$tmp/closed-heads"
jq -r '.[] | select(.state == "OPEN") | .headRefOid // empty' "$tmp/prs" | sort -u > "$tmp/open-heads"
: > "$tmp/active"
orca=${ORCA_CLI_COMMAND:-orca}
# Close finished terminals on the local host and every listed environment, before the worktree check reads the inventory.
# A released dispatch has no agentTerminalHandle and its leftover terminals still look connected, so a terminal is linked to
# dispatches by handle and by worktree path. Closed: a terminal of a settled dispatch, one whose process exited, or one with
# no agent on a path where every dispatch is settled (shells, worker-pane.sh panes). Kept: our own, a live dispatch's, one
# running an agent, a lead- worktree's, and a terminal on a path with no dispatch (reported as unknown owner).
# Dispatches come from the coordinator, including its remote workers. Reuse that inventory
# for every environment; a remote Orca need not own the dispatch of a terminal it hosts.
term_closed=0; term_kept=0
: > "$tmp/closing"
terminal_kept() { printf 'Kept terminal %s (%s, %s)\n' "$1" "$2" "$3"; term_kept=$((term_kept+1)); }
close_terminal() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$orca" terminal close "$@" >/dev/null 2>&1
  else "$orca" terminal close "$@" >/dev/null 2>&1
  fi
}
terminal_dispatches() {
  local wargs cursor=''
  : > "$tmp/h-workers"
  : > "$tmp/h-cursors"
  while :; do
    wargs=(--include-remote --limit 100); [ -z "$cursor" ] || wargs+=(--cursor "$cursor")
    if ! "$orca" orchestration worker-list "${wargs[@]}" --json > "$tmp/h-page" 2>/dev/null \
      || ! jq -e '.ok != false and (.result.workers | type == "array")
        and (.result.page.hasMore | type == "boolean")' "$tmp/h-page" >/dev/null 2>&1; then
      echo 'Warning: coordinator dispatch discovery failed; closing no terminals.' >&2; return 1
    fi
    cat "$tmp/h-page" >> "$tmp/h-workers"
    jq -e '.result.page.hasMore' "$tmp/h-page" >/dev/null || break
    if ! cursor=$(jq -er '.result.page.nextCursor | select(type == "string" and length > 0)' "$tmp/h-page") \
      || grep -Fxq -- "$cursor" "$tmp/h-cursors"; then
      echo 'Warning: coordinator dispatch pagination incomplete; closing no terminals.' >&2; return 1
    fi
    printf '%s\n' "$cursor" >> "$tmp/h-cursors"
  done
}
close_finished_terminals() {
  local env=$1 label=${1:-local} eargs=() handle reason action
  [ -z "$env" ] || eargs=(--environment "$env")
  if ! "$orca" terminal list ${eargs[@]+"${eargs[@]}"} --json > "$tmp/h-terminals" 2>/dev/null \
    || ! jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$tmp/h-terminals" >/dev/null 2>&1; then
    echo "Warning: terminal inventory incomplete on $label; closing nothing there." >&2; return 0
  fi
  jq -r -s --slurpfile terms "$tmp/h-terminals" --arg own "${ORCA_TERMINAL_HANDLE:-}" '
    def settled: .dispatchStatus as $s | ["completed","failed","cancelled","released"] | index($s);
    def path: (.projection.workspace.id // "") | split("::")[1] // "";
    [.[].result.workers[]] as $w
    | $terms[0].result.terminals[] | .handle as $h | (.worktreePath // "") as $p
    | ([$w[] | select(.agentTerminalHandle == $h)]) as $mine
    | ([$w[] | select($p != "" and path == $p)]) as $onpath
    | (.connected == false or .writable == false) as $exited
    | if $h == $own then [$h, "own terminal", "keep"]
      elif any(($mine + $onpath)[]; settled | not) then [$h, "live dispatch", "keep"]
      elif ($p | split("/") | last | startswith("lead-")) then [$h, "lead worktree", "keep"]
      elif ($mine | length) > 0 then [$h, "settled dispatch", "close"]
      elif $exited then [$h, "exited", "close"]
      elif ($onpath | length) > 0 and .agentIdentity != null then [$h, "agent running", "keep"]
      elif ($onpath | length) > 0 and ((.title // "") | test("worker-pane")) then [$h, "settled worker pane", "close"]
      elif ($onpath | length) > 0 then [$h, "settled dispatch on this path", "close"]
      else [$h, "unknown owner, still running", "keep"] end
    | @tsv' "$tmp/h-workers" > "$tmp/h-plan"
  while IFS=$'\t' read -r handle reason action; do
    if [ "$action" = keep ]; then terminal_kept "$handle" "$label" "$reason"; continue; fi
    printf 'Close terminal %s (%s, %s)\n' "$handle" "$label" "$reason"
    [ -n "$env" ] || printf '%s\n' "$handle" >> "$tmp/closing"
    if [ "$apply" -eq 1 ]; then
      close_terminal ${eargs[@]+"${eargs[@]}"} --terminal "$handle" || echo "Warning: closing $handle on $label failed." >&2
    fi
    term_closed=$((term_closed+1))
  done < "$tmp/h-plan"
}
if [ "$worktrees_only" -eq 0 ] && command -v "$orca" >/dev/null 2>&1 && terminal_dispatches; then
  close_finished_terminals ''
  if "$orca" environment list --json > "$tmp/envs" 2>/dev/null && jq -e '.result.environments | type == "array"' "$tmp/envs" >/dev/null 2>&1; then
    while IFS= read -r env_id; do
      [ -z "$env_id" ] || close_finished_terminals "$env_id"
    done < <(jq -r '.result.environments[] | .id // .name // empty' "$tmp/envs")
  else
    echo 'Warning: Orca environment list unavailable; closed local terminals only.' >&2
  fi
fi
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
        echo 'Warning: unexpected worker-list page shape; retaining all worktrees.' >&2
        echo '*' >> "$tmp/active"; break
      fi
      cat "$tmp/workers" >> "$tmp/worker-pages"
      while IFS=$'\t' read -r dispatch status; do
        [ -n "$dispatch" ] || continue
        if "$orca" orchestration worker-show --dispatch "$dispatch" --json > "$tmp/show"; then
          jq -r 'select(.result.dispatch.status as $s | ["completed","failed","cancelled","released"] | index($s) | not) | .result | (.terminal.cwd // .terminal.worktreePath // empty), ((.worker.worktreeId // "") | split("::")[1] // empty)' "$tmp/show" >> "$tmp/active"
        elif [ "$status" = pending ]; then
          # Never started: no worker and no worktree, so worker-show has nothing to return.
          echo "Warning: worker-show failed for pending dispatch $dispatch; skipped." >&2
        else
          echo "Warning: worker-show failed for $dispatch; retaining all worktrees." >&2
          echo '*' >> "$tmp/active"
        fi
      done < <(jq -r '.result.workers[]? | select(.dispatchStatus as $s | ["completed","failed","cancelled","released"] | index($s) | not) | [.dispatchId // empty, .dispatchStatus // ""] | @tsv' "$tmp/workers")
      cursor=$(jq -r 'if .result.page.hasMore then .result.page.nextCursor // empty else empty end' "$tmp/workers")
      [ -n "$cursor" ] || break
    done
    # Discard terminals positively owned only by settled dispatches. Unknown owners stay safe.
    jq -s '[.[].result.workers[]] | group_by(.agentTerminalHandle) | map(select(all(.[]; .dispatchStatus as $s | ["completed","failed","cancelled","released"] | index($s))) | .[0].agentTerminalHandle) | map(select(. != null))' "$tmp/worker-pages" > "$tmp/ended-handles"
    # A preview leaves the terminals it plans to close open; apply has closed them, so count them as gone in both.
    jq -R . "$tmp/closing" | jq -s . > "$tmp/closing-handles"
    jq -r --slurpfile ended "$tmp/ended-handles" --slurpfile closing "$tmp/closing-handles" '.result.terminals[] | select(.handle as $h | ($ended[0] | index($h) | not) and ($closing[0] | index($h) | not)) | .cwd // .worktreePath // empty' "$tmp/terminals" >> "$tmp/active"
  else
    echo 'Warning: Orca terminal inventory incomplete; retaining all worktrees.' >&2
    echo '*' >> "$tmp/active"
  fi
elif [ "$worktrees_only" -eq 1 ]; then
  # A fleet host with no Orca CLI cannot prove a worktree is idle, so it keeps them all.
  echo 'Warning: Orca unavailable; retaining all worktrees.' >&2
  echo '*' >> "$tmp/active"
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
# Missing or malformed safety metadata never authorizes a branch deletion.
protection_ok=1
: > "$tmp/protected"
default_branch=''
if gh repo view --json defaultBranchRef > "$tmp/default" 2>/dev/null; then
  default_branch=$(jq -er '.defaultBranchRef.name | select(type == "string" and length > 0)' "$tmp/default" 2>/dev/null) || default_branch=''
fi
if [ -z "$default_branch" ]; then
  default_branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || default_branch=''
  default_branch=${default_branch#refs/remotes/origin/}
fi
[ -n "$default_branch" ] || protection_ok=0
pages_branch=''
if gh api 'repos/{owner}/{repo}/pages' > "$tmp/pages" 2> "$tmp/pages-err"; then
  if jq -e 'type == "object" and (.source == null or (.source.branch | type == "string" and length > 0))' "$tmp/pages" >/dev/null 2>&1; then
    pages_branch=$(jq -r '.source.branch // empty' "$tmp/pages")
  else protection_ok=0
  fi
elif ! grep -Eq 'HTTP 404|HTTP/[^ ]+ 404' "$tmp/pages-err"; then
  protection_ok=0
fi
if gh api --paginate 'repos/{owner}/{repo}/branches?protected=true&per_page=100' > "$tmp/protection-pages" 2>/dev/null \
  && jq -es 'length > 0 and all(.[]; type == "array" and all(.[]; .name | type == "string" and length > 0))' "$tmp/protection-pages" >/dev/null 2>&1; then
  jq -rs '.[][] | .name' "$tmp/protection-pages" > "$tmp/protected"
else protection_ok=0
fi
protected() {
  protected_reason=protected
  [ -n "$1" ] || return 1
  if [ "$1" = "$default_branch" ]; then protected_reason='default branch'; return 0; fi
  if [ "$1" = gh-pages ] || { [ -n "$pages_branch" ] && [ "$1" = "$pages_branch" ]; }; then
    protected_reason='GitHub Pages branch'; return 0
  fi
  case "$1" in main|master|staging|production|web2/*|*/staging|*/production|HEAD|lead-queue|*/lead-queue) return 0 ;; esac
  grep -Fxq -- "$1" "$tmp/protected" && return 0
  if [ "$protection_ok" -eq 0 ]; then protected_reason='branch protection lookup unavailable'; return 0; fi
  return 1
}
eligible() {
  reason='unmerged without closed PR'
  if [ -n "$2" ] && grep -Fxq -- "$2" "$tmp/open"; then reason='open PR'; return 1; fi
  if git merge-base --is-ancestor "$1" origin/main; then reason=ancestor; return 0; fi
  if [ -n "$2" ] && grep -Fxq -- "$2" "$tmp/closed"; then reason='closed PR'; return 0; fi
  # Squash or rebase merges: every commit has a patch-equivalent on origin/main.
  if [ "$pr_ok" -eq 1 ] && [ -n "$2" ] && cherry=$(git cherry origin/main "$1") && ! grep -q '^+' <<< "$cherry"; then reason='patch-merged'; return 0; fi
  return 1
}
# True when every status line is an untracked image (screenshot dirt).
screenshots_only() {
  ! grep -qviE '^\?\? .*\.(png|jpe?g|gif|webp)"?$' "$1"
}
# Holder checks return true for busy OR unknown, with the reason in $busy.
# fuser checks inodes, not directory trees: enumerate descendants as well as the
# target so a nested cwd or open file cannot be mistaken for an idle directory.
fuser_busy() {
  local entry holders status batch bytes
  if [ -d "$1" ]; then
    if ! find "$1" -print0 > "$tmp/holder-paths" 2> "$tmp/holder-err" || [ -s "$tmp/holder-err" ]; then
      busy='fuser traversal failed'; return 0
    fi
  else printf '%s\0' "$1" > "$tmp/holder-paths"
  fi
  while :; do
    batch=(); bytes=0
    while IFS= read -r -d '' entry; do
      batch+=("$entry"); bytes=$((bytes + ${#entry} + 1))
      # Bound argument count and size, including worktrees with long paths.
      [ "${#batch[@]}" -lt 64 ] && [ "$bytes" -lt 16384 ] || break
    done
    [ "${#batch[@]}" -gt 0 ] || break
    status=0
    # psmisc fuser rejects --; these paths are absolute, so no terminator is needed.
    holders=$(fuser "${batch[@]}" 2> "$tmp/holder-err") || status=$?
    if [ "$status" -eq 0 ] || [ -n "$holders" ]; then busy='held open by a running process'; return 0; fi
    if [ "$status" -ne 1 ] || [ -s "$tmp/holder-err" ]; then busy='fuser failed'; return 0; fi
  done < "$tmp/holder-paths"
  return 1
}
# Tests inject a disposable proc tree; production always defaults to /proc.
proc_root=${WRAP_UP_TEST_PROC_ROOT:-/proc}
proc_busy() {
  local pid link dest target pids
  busy='proc inspection failed'
  [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ] || return 0
  target=$(readlink -f -- "$1" 2> "$tmp/holder-err") || return 0
  [ -n "$target" ] && [ ! -s "$tmp/holder-err" ] || return 0
  # Use a shell glob: a find subprocess would list itself and then disappear,
  # making every scan fail closed on that vanished PID.
  pids=("$proc_root"/[0-9]*)
  # An empty or hidden process inventory cannot prove idleness.
  [ -d "${pids[0]}" ] || return 0
  for pid in "${pids[@]}"; do
    case "${pid##*/}" in *[!0-9]*) return 0 ;; esac
    [ -d "$pid" ] && [ -r "$pid" ] && [ -x "$pid" ] \
      && [ -d "$pid/fd" ] && [ -r "$pid/fd" ] && [ -x "$pid/fd" ] || return 0
    printf '%s\0' "$pid/cwd" "$pid/root" > "$tmp/proc-links"
    if ! find "$pid/fd" -mindepth 1 -maxdepth 1 -print0 >> "$tmp/proc-links" 2> "$tmp/holder-err" \
      || [ -s "$tmp/holder-err" ]; then return 0; fi
    while IFS= read -r -d '' link; do
      dest=$(readlink -- "$link" 2> "$tmp/holder-err") || return 0
      [ -n "$dest" ] && [ ! -s "$tmp/holder-err" ] || return 0
      # Match literal paths as well as Linux's marker for unlinked holders.
      case "$dest" in
        "$target"|"$target"/*|"$target (deleted)") busy='held open by a running process'; return 0 ;;
      esac
    done < "$tmp/proc-links"
  done
  busy=''; return 1
}
linux_holder_check_available() {
  case "$OSTYPE" in
    linux*) command -v fuser >/dev/null 2>&1 || { [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ]; } ;;
    *) return 1 ;;
  esac
}
path_busy() {
  local holders status=0
  if command -v lsof >/dev/null 2>&1; then
    if [ -d "$1" ]; then holders=$(lsof -t +D "$1" 2>"$tmp/lsof-err") || status=$?
    else holders=$(lsof -t -- "$1" 2>"$tmp/lsof-err") || status=$?
    fi
    if [ -n "$holders" ]; then busy='held open by a running process'; return 0; fi
    if [ "$status" -gt 1 ] || [ -s "$tmp/lsof-err" ]; then busy='lsof failed'; return 0; fi
    return 1
  fi
  case "$OSTYPE" in
    linux*)
      # Scan the process inventory once, independently of the target tree size.
      # Only an unavailable proc root permits fallback; partial scans stay busy.
      if [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ]; then proc_busy "$1"; return $?; fi
      if command -v fuser >/dev/null 2>&1; then fuser_busy "$1"; return $?; fi
      if [ -d "$proc_root" ]; then proc_busy "$1"; return $?; fi
      ;;
  esac
  busy='lsof unavailable'; return 0
}
# The one gate before anything is deleted because nothing runs there (worktrees,
# stale branches, build caches, Chrome clones, temp items). Both the holder check
# and ps must answer cleanly; errors and unreadable state always keep the item.
in_use() {
  local ps_status=0 line esc
  busy=''
  if path_busy "$1"; then return 0; fi
  if ! command -v ps >/dev/null 2>&1; then busy='ps unavailable'; return 0; fi
  ps -axo command= > "$tmp/ps" 2>"$tmp/ps-err" || ps_status=$?
  if [ "$ps_status" -ne 0 ] || [ -s "$tmp/ps-err" ]; then busy='ps failed'; return 0; fi
  # Also the shell escaped spelling (a\ b). After the path only an argument boundary counts, so a sibling prefix does not.
  esc=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_.\/:=-]/\\&/g')
  while IFS= read -r line; do
    case "$line" in
      *"$1"|*"$1"[/\ :=\"\',\;]*|*"$esc"|*"$esc"[/\ :=\"\',\;]*) busy='a process command line names it'; return 0 ;;
    esac
  done < "$tmp/ps"
  return 1
}
# Every destructive command below runs inside one of the guarded_* functions (wrap-up.test.sh lints this). Each one,
# as its last step before the command, re-reads the checkout inventory and runs in_use on every worktree the delete
# touches. Busy, unknown or a failed inventory keeps the item: it is reported and counted (in the counter named by the
# first argument) and the function returns non-zero. A failed inventory stops every later delete in this run.
inventory_failed=0
guard_keep() { # <counter> <label> <why>
  printf 'Kept %s (%s)\n' "$2" "$3"
  printf -v "$1" '%s' "$(( ${!1} + 1 ))"
}
fresh_inventory() { # [what the warning says stops]
  [ "$inventory_failed" -eq 0 ] && git worktree list --porcelain > "$tmp/wt-now" && return 0
  [ "$inventory_failed" -eq 1 ] || echo "Warning: could not list worktrees; ${1:-deleting nothing more in this repo}." >&2
  inventory_failed=1; return 1
}
# The worktree that has the branch checked out in the fresh inventory, if any.
checkout_of() { awk -v b="branch refs/heads/$1" '/^worktree /{ p = substr($0, 10) } $0 == b { print p; exit }' "$tmp/wt-now"; }
guard_paths() { # <counter> <label> <path...>: fresh inventory, then in_use on each path
  local counter=$1 label=$2 p; shift 2
  fresh_inventory || { guard_keep "$counter" "$label" 'worktree inventory unavailable'; return 2; }
  for p in "$@"; do
    if in_use "$p"; then guard_keep "$counter" "$label" "$busy"; return 1; fi
  done
}
branch_free() { # <counter> <label> <branch>: after fresh_inventory, keeps the item when a worktree has the branch now
  local wt
  wt=$(checkout_of "$3") || { inventory_failed=1; guard_keep "$1" "$2" 'worktree inventory unavailable'; return 2; }
  [ -n "$wt" ] || return 0
  echo "Warning: $2 is checked out in a worktree now; kept." >&2
  if in_use "$wt"; then guard_keep "$1" "$2" "checked out in $wt, $busy"; else guard_keep "$1" "$2" "checked out in $wt"; fi
  return 1
}
guarded_worktree_remove() { # <counter> <label> <path> [--force]
  guard_paths "$1" "$2" "$3" || return
  git worktree remove ${4:+"$4"} -- "$3" && return 0
  echo "Warning: could not remove $2; kept." >&2; guard_keep "$1" "$2" 'remove failed'; return 1
}
guarded_local_branch_delete() { # <counter> <label> <branch> [eligibility reason]
  fresh_inventory || { guard_keep "$1" "$2" 'worktree inventory unavailable'; return 2; }
  branch_free "$1" "$2" "$3" || return
  if [ "${4:-}" = ancestor ]; then
    # -d checks HEAD/upstream, so give it the authoritative merge target.
    git -c "branch.$3.remote=origin" -c "branch.$3.merge=refs/heads/main" branch -d -- "$3" && return 0
  else
    git branch -D -- "$3" && return 0
  fi
  echo "Warning: could not delete $2; kept." >&2; guard_keep "$1" "$2" 'delete failed'; return 1
}
guarded_remote_branch_delete() { # <name...>: sets remote_gone to how many went; kept ones count in kept
  local name status=0 live=() leases=()
  remote_gone=0
  remote_live "$@" || status=1
  [ ${#live[@]} -gt 0 ] || return "$status"
  if git push origin --delete "${live[@]}" "${leases[@]}" --atomic; then remote_gone=${#live[@]}; return "$status"; fi
  # One bad ref fails the whole push; retry one by one, each behind a fresh inventory, so only the failing ones are kept.
  for name in "${live[@]}"; do
    remote_live "$name" || { status=1; continue; }
    if git push origin --delete "$name" "${leases[@]}"; then remote_gone=$((remote_gone+1)); continue; fi
    echo "Warning: could not delete remote $name; kept." >&2
    guard_keep kept "remote $name" 'delete failed'; status=1
  done
  return "$status"
}
remote_live() { # <name...>: fresh checkout inventory and live SHA; also sets caller's push leases
  local name status=0 expected actual
  live=()
  leases=()
  if ! fresh_inventory; then
    for name in "$@"; do guard_keep kept "remote $name" 'worktree inventory unavailable'; done
    return 2
  fi
  for name in "$@"; do
    if ! branch_free kept "remote $name" "$name"; then status=1; continue; fi
    expected=$(awk -v r="refs/remotes/origin/$name" '$1 == r { print $2 }' "$tmp/remote-planned")
    if ! git ls-remote --heads origin "refs/heads/$name" > "$tmp/remote-now"; then
      guard_keep kept "remote $name" 'live remote lookup failed'; status=1; continue
    fi
    actual=$(awk -v r="refs/heads/$name" '$2 == r { print $1 }' "$tmp/remote-now")
    if [ -z "$actual" ]; then
      guard_keep kept "remote $name" 'vanished from remote'; status=1; continue
    fi
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
      guard_keep kept "remote $name" 'remote SHA changed since fetch'; status=1; continue
    fi
    live+=("$name")
    # Keep the check atomic if a writer races the ls-remote response.
    leases+=("--force-with-lease=refs/heads/$name:$expected")
  done
  return "$status"
}
guarded_rm() { # <counter> <label> <rf|dir> <path> [more paths to probe]
  local counter=$1 label=$2 mode=$3 target=$4; shift 3
  guard_paths "$counter" "$label" "$@" || return
  if [ "$mode" = dir ]; then
    rmdir -- "$target" && return 0
  else
    rm -rf -- "$target" && return 0
  fi
  echo "Warning: could not remove $label; kept." >&2; guard_keep "$counter" "$label" 'remove failed'; return 1
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
removed=0; local_deleted=0; remote_deleted=0; kept=0; stale_deleted=0
keep() { printf 'Kept %s (%s)\n' "$1" "$2"; kept=$((kept+1)); }
: > "$tmp/kept-branches"
: > "$tmp/kept-worktrees"
: > "$tmp/stale-ok"
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
  local why='' force=''
  if [ -z "$main_checkout" ]; then main_checkout=$path; why='main checkout'
  elif [ -z "$branch" ] && case "${path##*/}" in _*) true ;; *) false ;; esac; then why='script-owned _ worktree'
  elif protected "$branch"; then why=$protected_reason
  elif case "${path##*/}" in lead-*) true ;; *) false ;; esac; then why='lead worktree'
  elif [ "$locked" -eq 1 ]; then why='locked'
  elif ! git -C "$path" status --porcelain --untracked-files=all > "$tmp/status"; then why='unreadable'
  elif [ -s "$tmp/status" ] && ! screenshots_only "$tmp/status"; then why='dirty'
  elif active_worktree "$path"; then why='active or unknown Orca terminal'
  elif recent_worktree "$path"; then why="changed in the last ${WRAP_UP_RECENT_MIN:-30} minutes"
  elif [ -z "$branch" ] && [ "$pr_ok" -ne 1 ]; then why='PR lookup unavailable'
  elif [ -z "$branch" ] && grep -Fxq -- "$head" "$tmp/open-heads"; then why='open PR head'
  elif [ -z "$branch" ]; then
    # A PR match alone must never discard a commit absent from all remote branches.
    git for-each-ref --contains "$head" --format='%(refname)' refs/remotes > "$tmp/containing-remotes"
    if [ ! -s "$tmp/containing-remotes" ]; then why='detached with unmerged commits'
    elif git merge-base --is-ancestor "$head" origin/main; then reason='detached at merged commit'
    elif grep -Fxq -- "$head" "$tmp/closed-heads"; then reason='detached at closed PR head'
    else why='detached with unmerged commits'
    fi
  elif ! eligible "refs/heads/$branch" "$branch"; then
    why=$reason
    [ "$reason" = 'open PR' ] || printf '%s\t%s\n' "$branch" "$path" >> "$tmp/stale-ok"
  fi
  if [ -z "$why" ] && in_use "$path"; then why=$busy; fi
  [ ! -s "$tmp/status" ] || force=--force
  if [ -n "$why" ]; then
    keep "worktree $path" "$why"
    printf '%s\n' "$path" >> "$tmp/kept-worktrees"
    [ -z "$branch" ] || printf '%s\n' "$branch" >> "$tmp/kept-branches"
  else
    printf 'Remove worktree %s (%s)\n' "$path" "$reason"
    if [ "$apply" -eq 0 ] || guarded_worktree_remove kept "worktree $path" "$path" "$force"; then
      removed=$((removed+1))
    else
      printf '%s\n' "$path" >> "$tmp/kept-worktrees"
      [ -z "$branch" ] || printf '%s\n' "$branch" >> "$tmp/kept-branches"
    fi
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
  if protected "$branch"; then
    keep "local $branch" "$protected_reason"
  elif grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "local $branch" 'checked out in kept worktree'
  elif eligible "refs/heads/$branch" "$branch"; then
    printf 'Delete local %s (%s)\n' "$branch" "$reason"
    if [ "$apply" -eq 0 ] || guarded_local_branch_delete kept "local $branch" "$branch" "$reason"; then
      local_deleted=$((local_deleted+1))
    else
      printf '%s\n' "$branch" >> "$tmp/kept-branches"
    fi
  else keep "local $branch" "$reason"
  fi
done < <(git for-each-ref --format='%(refname:strip=2)' refs/heads)
# Build caches (WRAP_UP_BUILD_CACHE_DIRS, default .next) take up to 10G each. Drop them in every worktree kept above when no
# process has its cwd or open files there and no process command line names it. Top level and one level down (web/.next).
build_cache_dirs=${WRAP_UP_BUILD_CACHE_DIRS-.next}
cache_removed=0; cache_kept=0; cache_bytes=0
drop_build_caches() {
  local wt wt_real cache parent parent_real name kb found names=() valid=()
  read -r -a names <<< "$build_cache_dirs"
  # Plain directory names only: a path, "." or ".." could point outside the worktree.
  for name in ${names[@]+"${names[@]}"}; do
    case "$name" in
      */*|.|..) echo "Warning: ignoring build cache name '$name' (must be a plain directory name)." >&2 ;;
      *) valid+=("$name") ;;
    esac
  done
  [ ${#valid[@]} -gt 0 ] || return 0
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    wt_real=$(cd "$wt" && pwd -P) || continue
    found=()
    for name in "${valid[@]}"; do
      for cache in "$wt/$name" "$wt"/*/"$name"; do
        [ -d "$cache" ] && [ ! -L "$cache" ] || continue
        # The real parent must be the worktree root or a real child of it, so no symlinked ancestor can leak out.
        parent=${cache%/*}
        parent_real=$(cd "$parent" && pwd -P) || continue
        if [ "$parent_real" != "$wt_real" ] && [ "${parent_real%/*}" != "$wt_real" ]; then
          echo "Warning: build cache $cache resolves outside the worktree; skipped." >&2; continue
        fi
        found+=("$cache")
      done
    done
    [ ${#found[@]} -gt 0 ] || continue
    in_use "$wt" || true
    for cache in "${found[@]}"; do
      if [ -n "$busy" ]; then
        printf 'Kept build cache %s (%s)\n' "$cache" "$busy"; cache_kept=$((cache_kept+1)); continue
      fi
      kb=$(du -sk -- "$cache" 2>/dev/null | cut -f1) || kb=0
      kb=${kb:-0}
      printf 'Remove build cache %s (%s KB)\n' "$cache" "$kb"
      if [ "$apply" -eq 0 ] || guarded_rm cache_kept "build cache $cache" rf "$cache" "$wt"; then
        cache_removed=$((cache_removed+1)); cache_bytes=$((cache_bytes + kb * 1024))
      fi
    done
  done < "$tmp/kept-worktrees"
}
drop_build_caches
missing_lsof_summary() {
  if ! command -v lsof >/dev/null 2>&1 && ! linux_holder_check_available; then
    printf 'lsof unavailable: kept all worktrees=%s and Chrome clones=%s\n' "$(wc -l < "$tmp/kept-worktrees" | tr -d ' ')" "${clone_kept:-0}"
  fi
}
# A fleet host runs worktrees and local branches only: the coordinator run deletes remote branches once, and a
# checkout there is never fast forwarded.
if [ "$worktrees_only" -eq 1 ]; then
  if [ "$apply" -eq 0 ]; then echo 'Planned counts (nothing deleted):'; else echo 'Completed counts:'; fi
  printf 'removed worktrees=%s deleted local=%s deleted remote=0 kept=%s stale=0 stale deleted=0\n' "$removed" "$local_deleted" "$kept"
  printf 'build caches removed=%s kept=%s bytes=%s\n' "$cache_removed" "$cache_kept" "$cache_bytes"
  missing_lsof_summary
  exit "$inventory_failed"
fi
batch=()
flush_remote() {
  [ ${#batch[@]} -gt 0 ] || return 0
  if [ "$apply" -eq 1 ]; then
    guarded_remote_branch_delete "${batch[@]}" || true
    remote_deleted=$((remote_deleted+remote_gone))
  fi
  batch=()
}
while IFS= read -r ref; do
  branch=${ref#refs/remotes/origin/}
  if protected "$branch"; then
    keep "remote $branch" "$protected_reason"
  elif grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "remote $branch" 'checked out in kept worktree'
  elif eligible "$ref" "$branch"; then
    printf 'Delete remote %s (%s)\n' "$branch" "$reason"
    batch+=("$branch")
    [ "$apply" -eq 1 ] || remote_deleted=$((remote_deleted+1))
    [ ${#batch[@]} -lt 50 ] || flush_remote
  else keep "remote $branch" "$reason"
  fi
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)
flush_remote
# Each Chrome launch leaves a code_sign_clone under the per-user temp dir (macOS), in the T dir or its sibling X dir.
# Remove those no process holds open.
clone_removed=0; clone_kept=0
clone_root=${WRAP_UP_CLONE_ROOT-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
clone_dirs=()
if [ -n "$clone_root" ]; then
  clone_root=${clone_root%/}
  clone_dirs=("$clone_root")
  case "$clone_root" in */T) clone_dirs+=("${clone_root%/T}/X") ;; esac
fi
for clone_dir in ${clone_dirs[@]+"${clone_dirs[@]}"}; do
  [ -d "$clone_dir" ] || continue
  for clone in "$clone_dir"/com.google.Chrome*.code_sign_clone/code_sign_clone.*; do
    [ -d "$clone" ] || continue
    if in_use "$clone"; then
      printf 'Kept Chrome clone %s (%s)\n' "$clone" "$busy"; clone_kept=$((clone_kept+1))
    else
      printf 'Remove Chrome clone %s\n' "$clone"
      if [ "$apply" -eq 0 ] || guarded_rm clone_kept "Chrome clone $clone" rf "$clone"; then clone_removed=$((clone_removed+1)); fi
    fi
  done
done
# Agent temp files (inventory: docs/agents/wrap-up-temp-files.md). Removable when nothing holds the item open and either
# its worktree is gone or nothing in it changed for 24 h. The coordinator inbox waiter files are never touched.
temp_removed=0; temp_kept=0; temp_bytes=0
scratch_root=${WRAP_UP_SCRATCH_ROOT-/tmp/claude-$(id -u)}
loose_root=${WRAP_UP_LOOSE_ROOT-/tmp}
state_dir=${WRAP_UP_STATE_DIR-${XDG_STATE_HOME:-$HOME/.local/state}/agent-team}
# Slug of a path as the Claude Code scratch tree names it: every non alphanumeric character becomes a dash.
slugify() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
# True when some directory on disk has this slug. Walks down from / matching entries, so dashes need no guessing.
slug_exists() {
  local dir=$1 rest=$2 entry name s
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}; s=$(slugify "$name")
    if [ "$rest" = "$s" ]; then return 0; fi
    case "$rest" in "$s"-*) slug_exists "$entry" "${rest#"$s"-}" && return 0 ;; esac
  done
  return 1
}
# temp_item <path> <worktree gone: 0|1>
temp_item() {
  local item=$1 gone=$2 why='' kb sid
  case "${item##*/}" in elon-wait.sh|elon-waiter.json) return 0 ;; esac
  case "$item" in "$state_dir"|"$state_dir"/*) return 0 ;; esac
  kb=$(du -sk -- "$item" | cut -f1)
  for sid in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    [ -z "$sid" ] || [ "${item##*/}" != "$sid" ] || why="current session's own scratch dir"
  done
  case "$PWD/" in "$item"/*) why="current session's own scratch dir" ;; esac
  if [ -n "$why" ]; then :
  elif [ "$gone" -eq 0 ] && [ -n "$(find "$item" -mmin -1440 -print -quit)" ]; then why='touched in the last 24 h'
  elif in_use "$item"; then why=$busy
  fi
  if [ -n "$why" ]; then
    printf 'Kept temp %s (%s)\n' "$item" "$why"; temp_kept=$((temp_kept+1)); return 0
  fi
  if [ "$gone" -eq 1 ]; then why='worktree gone'; else why='untouched for 24 h'; fi
  printf 'Remove temp %s (%s KB, %s)\n' "$item" "$kb" "$why"
  if [ "$apply" -eq 0 ] || guarded_rm temp_kept "temp $item" rf "$item"; then
    temp_removed=$((temp_removed+1)); temp_bytes=$((temp_bytes + kb * 1024))
  fi
}
if [ -d "$scratch_root" ]; then
  for entry in "$scratch_root"/*/; do
    entry=${entry%/}; [ -d "$entry" ] || continue
    case "${entry##*/}" in
      -*)
        slug=${entry##*/}; gone=1
        if slug_exists '' "${slug#-}"; then gone=0; fi
        for session in "$entry"/*/; do
          session=${session%/}; [ -d "$session" ] || continue
          temp_item "$session" "$gone"
        done
        # The emptied slug parent goes too, unless something may still run there.
        if [ -z "$(ls -A -- "$entry" 2>/dev/null)" ]; then
          if in_use "$entry"; then printf 'Kept temp %s (%s)\n' "$entry" "$busy"; temp_kept=$((temp_kept+1))
          elif [ "$apply" -eq 1 ]; then guarded_rm temp_kept "temp $entry" dir "$entry" || true
          fi
        fi ;;
      qa-*) temp_item "$entry" 0 ;;
    esac
  done
fi
if [ -d "$loose_root" ]; then
  for entry in "$loose_root"/[0-9][0-9]*-*.log "$loose_root"/[0-9][0-9]*-*.sh; do
    [ -f "$entry" ] && [ -O "$entry" ] || continue
    temp_item "$entry" 0
  done
  for entry in "$loose_root"/playwright-artifacts-* "$loose_root"/playwright_chromiumdev_profile-*; do
    [ -d "$entry" ] && [ -O "$entry" ] || continue
    temp_item "$entry" 0
  done
fi
# Stale: unmerged, no open PR, at least 8 h old, nothing running. Deleted with --apply.
stale_found=0
if [ "$pr_ok" -eq 1 ]; then
  now=$(date +%s)
  {
    git for-each-ref --format='%(refname:strip=2)' refs/heads
    git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin
  } | sort -u > "$tmp/names"
  while IFS= read -r name; do
    [ -n "$name" ] && ! protected "$name" || continue
    wt=$(awk -F'\t' -v n="$name" '$1 == n { print substr($0, length(n) + 2); exit }' "$tmp/stale-ok")
    if [ -z "$wt" ] && grep -Fxq -- "$name" "$tmp/kept-branches"; then continue; fi
    refs=()
    for ref in "refs/heads/$name" "refs/remotes/origin/$name"; do
      git show-ref --verify --quiet "$ref" || continue
      ! eligible "$ref" "$name" || continue
      [ "$reason" != 'open PR' ] || { refs=(); break; }
      refs+=("$ref")
    done
    [ ${#refs[@]} -gt 0 ] || continue
    newest=0
    for ref in "${refs[@]}"; do
      t=$(git log -1 --format=%ct "$ref"); [ "$t" -le "$newest" ] || newest=$t
    done
    [ $((now - newest)) -ge 28800 ] || continue
    if [ -n "$wt" ] && in_use "$wt"; then keep "stale $name" "$busy"; continue; fi
    if [ "$stale_found" -eq 0 ]; then echo 'Stale (eligible for cleanup)'; fi
    stale_found=$((stale_found+1))
    subject=$(git log --reverse --format=%s "origin/main..${refs[0]}" | sed -n 1p)
    printf '  %s, %sh old, %s\n' "$name" $(( (now - newest) / 3600 )) "$subject"
    # A worker may have checked the branch out since the listing above; once the inventory fails, nothing more goes.
    if [ "$apply" -eq 1 ]; then
      if ! fresh_inventory 'deleting no more stale branches'; then keep "stale $name" 'worktree inventory unavailable'; continue; fi
      now_wt=$(checkout_of "$name")
      if [ -n "$now_wt" ] && [ "$now_wt" != "$wt" ]; then
        if in_use "$now_wt"; then keep "stale $name" "checked out in $now_wt, $busy"
        else keep "stale $name" "checked out in $now_wt"
        fi
        continue
      fi
    fi
    printf 'Delete stale %s\n' "$name"
    stale_failed=0
    if [ "$apply" -eq 1 ]; then
      # A kept worktree keeps its refs too. The local branch comes first in refs, so a kept one keeps the remote one.
      if [ -n "$wt" ] && ! guarded_worktree_remove kept "stale $name" "$wt" --force; then stale_failed=1; fi
      for ref in "${refs[@]}"; do
        [ "$stale_failed" -eq 0 ] || break
        case "$ref" in
          refs/heads/*) guarded_local_branch_delete kept "local $name" "$name" || stale_failed=1 ;;
          *) guarded_remote_branch_delete "$name" || stale_failed=1 ;;
        esac
      done
    fi
    [ "$stale_failed" -eq 1 ] || stale_deleted=$((stale_deleted+1))
  done < "$tmp/names"
fi
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
printf 'removed worktrees=%s deleted local=%s deleted remote=%s kept=%s stale=%s stale deleted=%s\n' "$removed" "$local_deleted" "$remote_deleted" "$kept" "$stale_found" "$stale_deleted"
printf 'terminals closed=%s kept=%s\n' "$term_closed" "$term_kept"
printf 'build caches removed=%s kept=%s bytes=%s\n' "$cache_removed" "$cache_kept" "$cache_bytes"
printf 'chrome clones removed=%s kept=%s\n' "$clone_removed" "$clone_kept"
printf 'temp removed=%s kept=%s bytes=%s\n' "$temp_removed" "$temp_kept" "$temp_bytes"
missing_lsof_summary
# --fleet: run the same cleanup on every host in the untracked fleet config (worktrees and local branches only).
# Config: {"hosts": [{"host": "<ssh host>", "repo_dir": "<checkout on that host>"}]}; see wrap-up-fleet.config.example.json.
# An unreachable or failing host only warns. The script and arguments travel as base64 so a login shell's own output
# never reaches the parse; the remote output is framed between tagged markers.
if [ "$fleet" -eq 1 ]; then
  fleet_config=${WRAP_UP_FLEET_CONFIG:-$here/wrap-up-fleet.config.json}
  ssh_cmd=${WRAP_UP_FLEET_SSH:-ssh}
  t_hosts=0; t_up=0; t_removed=$removed; t_local=$local_deleted; t_kept=$kept
  # read, not $(cat <<...): bash 3.2 misparses the case pattern's ')' inside a command substitution.
  IFS= read -r -d '' remote_script <<'REMOTE' || true
d() { printf '%s' "$1" | base64 -d; }
repo=$(d "$1") flags=$(d "$2") tag=$(d "$3")
case "$repo" in '~'|'~/'*) repo="$HOME${repo#\~}" ;; esac
export PATH="$PATH:$HOME/.local/bin:$HOME/.orca/cli/bin:/opt/homebrew/bin:/usr/local/bin"
root=${DOTFILES_DIR:-$HOME/dotfiles}
[ ! -d "$HOME/dotfiles-main" ] || root="$HOME/dotfiles-main"
printf '%s\n' "@@begin-$tag@@"
status=0
# shellcheck disable=SC2086 # flags is a fixed word list built by the caller
bash "$root/script/wrap-up.sh" --worktrees-only $flags --repo "$repo" 2>&1 || status=$?
printf '\n%s\n' "@@end-$tag-$status@@"
REMOTE
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  if [ ! -f "$fleet_config" ] || ! jq -e '.hosts | type == "array"' "$fleet_config" >/dev/null 2>&1; then
    echo "Warning: fleet config $fleet_config missing or invalid; no fleet host cleaned." >&2
  else
    flags=--dry-run; [ "$apply" -eq 0 ] || flags=--apply
    while IFS=$'\t' read -r fhost frepo; do
      [ -n "$fhost" ] || continue
      t_hosts=$((t_hosts+1))
      printf '\n== Fleet host %s ==\n' "$fhost"
      case "$fhost" in -*|*[!A-Za-z0-9._-]*) echo "Warning: bad host name in fleet config; skipped." >&2; continue ;; esac
      [ -n "$frepo" ] || { echo "Warning: no repo_dir for $fhost; skipped." >&2; continue; }
      ftag="wrap-up-$$-$RANDOM"
      fstatus=0
      fwrap=("$ssh_cmd" -o BatchMode=yes -o ConnectTimeout=10 "$fhost" bash -c "\"\$(echo $(b64 "$remote_script") | base64 -d)\"" wrap-up "$(b64 "$frepo")" "$(b64 "$flags")" "$(b64 "$ftag")")
      if command -v timeout >/dev/null 2>&1; then fwrap=(timeout "${WRAP_UP_FLEET_TIMEOUT:-900}" "${fwrap[@]}"); fi
      "${fwrap[@]}" < /dev/null > "$tmp/fleet-out" 2> "$tmp/fleet-err" || fstatus=$?
      rstatus=$(sed -n "s/^@@end-$ftag-\([0-9][0-9]*\)@@\$/\1/p" "$tmp/fleet-out" | tail -n 1)
      if [ "$fstatus" -ne 0 ] || [ -z "$rstatus" ]; then
        echo "Warning: fleet host $fhost unreachable or incomplete (status $fstatus); skipped." >&2; continue
      fi
      awk -v t="$ftag" '$0 == "@@begin-" t "@@" { on = 1; next } index($0, "@@end-" t "-") == 1 { on = 0; next } on' "$tmp/fleet-out" > "$tmp/fleet-body"
      cat "$tmp/fleet-body"
      if [ "$rstatus" -ne 0 ]; then echo "Warning: wrap-up failed on fleet host $fhost (status $rstatus); not counted." >&2; continue; fi
      counts=$(sed -n 's/^removed worktrees=\([0-9][0-9]*\) deleted local=\([0-9][0-9]*\) deleted remote=[0-9]* kept=\([0-9][0-9]*\) .*$/\1 \2 \3/p' "$tmp/fleet-body" | tail -n 1)
      if [ -z "$counts" ]; then echo "Warning: no counts line from fleet host $fhost; not counted." >&2; continue; fi
      read -r c_removed c_local c_kept <<< "$counts"
      t_up=$((t_up+1)); t_removed=$((t_removed+c_removed)); t_local=$((t_local+c_local)); t_kept=$((t_kept+c_kept))
    done < <(jq -r '.hosts[] | [.host // "", .repo_dir // ""] | @tsv' "$fleet_config")
  fi
  printf '\nFleet total (local plus %s of %s hosts reached):\n' "$t_up" "$t_hosts"
  printf 'removed worktrees=%s deleted local=%s kept=%s\n' "$t_removed" "$t_local" "$t_kept"
fi
exit "$inventory_failed"
