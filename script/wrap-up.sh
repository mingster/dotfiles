#!/usr/bin/env bash
# Preview finished work cleanup; --apply performs the proposed changes.
set -euo pipefail
apply=0
stale=0
repo=.
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0 ;;
    --apply) apply=1 ;;
    --stale) stale=1 ;;
    --repo) [ $# -ge 2 ] || { echo 'Missing --repo path' >&2; exit 2; }; repo=$2; shift ;;
    -h|--help) echo 'Usage: wrap-up.sh [--dry-run|--apply] [--stale] [--repo <path>]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
# A fake orca CLI means a test: never let --apply reach the real temp roots from there.
if [ "$apply" -eq 1 ] && [ -n "${ORCA_CLI_COMMAND:-}" ] && { [ -z "${WRAP_UP_SCRATCH_ROOT+x}" ] || [ -z "${WRAP_UP_LOOSE_ROOT+x}" ]; }; then
  echo 'wrap-up: ORCA_CLI_COMMAND is set (test mode); set WRAP_UP_SCRATCH_ROOT and WRAP_UP_LOOSE_ROOT before --apply' >&2; exit 2
fi
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
# worker-list is newest first; only the newest WRAP_UP_WORKER_PAGES pages of 100 are read (older dispatches never match,
# so their paths count as unknown owner and stay). Handles belong to the host that issued them, so each host is handled alone.
term_closed=0; term_kept=0
: > "$tmp/closing"
terminal_kept() { printf 'Kept terminal %s (%s, %s)\n' "$1" "$2" "$3"; term_kept=$((term_kept+1)); }
close_terminal() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$orca" terminal close "$@" >/dev/null 2>&1
  else "$orca" terminal close "$@" >/dev/null 2>&1
  fi
}
close_finished_terminals() {
  local env=$1 label=${1:-local} eargs=() wargs cursor='' handle reason action pages=0
  [ -z "$env" ] || eargs=(--environment "$env")
  if ! "$orca" terminal list ${eargs[@]+"${eargs[@]}"} --json > "$tmp/h-terminals" 2>/dev/null \
    || ! jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$tmp/h-terminals" >/dev/null 2>&1; then
    echo "Warning: terminal inventory incomplete on $label; closing nothing there." >&2; return 0
  fi
  : > "$tmp/h-workers"
  while :; do
    wargs=(--limit 100); [ -z "$cursor" ] || wargs+=(--cursor "$cursor")
    if ! "$orca" orchestration worker-list ${eargs[@]+"${eargs[@]}"} "${wargs[@]}" --json > "$tmp/h-page" 2>/dev/null \
      || ! jq -e '.ok != false and (.result.workers | type == "array")' "$tmp/h-page" >/dev/null 2>&1; then
      echo "Warning: dispatch discovery failed on $label; closing nothing there." >&2; return 0
    fi
    cat "$tmp/h-page" >> "$tmp/h-workers"
    cursor=$(jq -r 'if .result.page.hasMore then .result.page.nextCursor // empty else empty end' "$tmp/h-page")
    pages=$((pages+1))
    [ -n "$cursor" ] && [ "$pages" -lt "${WRAP_UP_WORKER_PAGES:-2}" ] || break
  done
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
if command -v "$orca" >/dev/null 2>&1; then
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
# True when a process has the worktree open; unknown (no lsof) counts as running.
running_in() {
  command -v lsof >/dev/null 2>&1 || return 0
  [ -n "$(lsof -t +D "$1" 2>/dev/null || true)" ]
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
  elif protected "$branch"; then why='protected'
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
  [ ! -s "$tmp/status" ] || force=--force
  if [ -n "$why" ]; then
    keep "worktree $path" "$why"
    [ -z "$branch" ] || printf '%s\n' "$branch" >> "$tmp/kept-branches"
  else
    printf 'Remove worktree %s (%s)\n' "$path" "$reason"
    [ "$apply" -eq 0 ] || git worktree remove ${force:+"$force"} -- "$path"
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
  else keep "local $branch" "$reason"
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
    if ! command -v lsof >/dev/null 2>&1; then
      printf 'Kept Chrome clone %s (lsof unavailable)\n' "$clone"; clone_kept=$((clone_kept+1)); continue
    fi
    # Rule: remove only when lsof ends 0 or 1 (1 = no open files) with no output and no stderr. Any other result keeps.
    lsof_status=0; holders=$(lsof -t +D "$clone" 2>"$tmp/lsof-err") || lsof_status=$?
    if [ -n "$holders" ]; then
      printf 'Kept Chrome clone %s (held open by a running process)\n' "$clone"; clone_kept=$((clone_kept+1))
    elif [ "$lsof_status" -gt 1 ] || [ -s "$tmp/lsof-err" ]; then
      printf 'Kept Chrome clone %s (lsof failed)\n' "$clone"; clone_kept=$((clone_kept+1))
    else
      printf 'Remove Chrome clone %s\n' "$clone"
      [ "$apply" -eq 0 ] || rm -rf -- "$clone"
      clone_removed=$((clone_removed+1))
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
  local item=$1 gone=$2 why='' kb holders lsof_status=0 sid
  case "${item##*/}" in elon-wait.sh|elon-waiter.json) return 0 ;; esac
  case "$item" in "$state_dir"|"$state_dir"/*) return 0 ;; esac
  kb=$(du -sk -- "$item" | cut -f1)
  for sid in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    [ -z "$sid" ] || [ "${item##*/}" != "$sid" ] || why="current session's own scratch dir"
  done
  case "$PWD/" in "$item"/*) why="current session's own scratch dir" ;; esac
  if [ -n "$why" ]; then :
  elif [ "$gone" -eq 0 ] && [ -n "$(find "$item" -mmin -1440 -print -quit)" ]; then why='touched in the last 24 h'
  elif ! command -v lsof >/dev/null 2>&1; then why='lsof unavailable'
  else
    if [ -d "$item" ]; then holders=$(lsof -t +D "$item" 2>"$tmp/lsof-err") || lsof_status=$?
    else holders=$(lsof -t -- "$item" 2>"$tmp/lsof-err") || lsof_status=$?
    fi
    if [ -n "$holders" ]; then why='held open by a running process'
    elif [ "$lsof_status" -gt 1 ] || [ -s "$tmp/lsof-err" ]; then why='lsof failed'
    fi
  fi
  if [ -n "$why" ]; then
    printf 'Kept temp %s (%s)\n' "$item" "$why"; temp_kept=$((temp_kept+1)); return 0
  fi
  if [ "$gone" -eq 1 ]; then why='worktree gone'; else why='untouched for 24 h'; fi
  printf 'Remove temp %s (%s KB, %s)\n' "$item" "$kb" "$why"
  [ "$apply" -eq 0 ] || rm -rf -- "$item"
  temp_removed=$((temp_removed+1)); temp_bytes=$((temp_bytes + kb * 1024))
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
        [ "$apply" -eq 0 ] || rmdir -- "$entry" 2>/dev/null || true ;;
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
# Stale: unmerged, no open PR, older than 24 h, nothing running. Listed; deleted only with --stale.
stale_found=0; stale_deleted=0
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
    if [ -n "$wt" ] && running_in "$wt"; then continue; fi
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
    [ $((now - newest)) -ge 86400 ] || continue
    if [ "$stale_found" -eq 0 ]; then echo 'Stale (needs a decision)'; fi
    stale_found=$((stale_found+1))
    subject=$(git log --reverse --format=%s "origin/main..${refs[0]}" | sed -n 1p)
    printf '  %s, %sh old, %s\n' "$name" $(( (now - newest) / 3600 )) "$subject"
    [ "$stale" -eq 1 ] || continue
    printf 'Delete stale %s\n' "$name"
    if [ -n "$wt" ] && [ "$apply" -eq 1 ]; then git worktree remove --force -- "$wt"; fi
    for ref in "${refs[@]}"; do
      case "$ref" in
        refs/heads/*) [ "$apply" -eq 0 ] || git branch -D -- "$name" ;;
        *) batch+=("$name") ;;
      esac
    done
    stale_deleted=$((stale_deleted+1))
  done < "$tmp/names"
  flush_remote
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
printf 'chrome clones removed=%s kept=%s\n' "$clone_removed" "$clone_kept"
printf 'temp removed=%s kept=%s bytes=%s\n' "$temp_removed" "$temp_kept" "$temp_bytes"
