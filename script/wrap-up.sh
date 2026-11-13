#!/usr/bin/env bash
# Preview finished work cleanup; --apply performs the proposed changes.
# Other modes: --scheduled (one round on this host; the coordinator also moves fleet board cards to Done),
# --branch (after a merge), --finish-worker (a settled worker).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Runs a command for at most $1 seconds in its own process group, stdin closed; exit 124 on timeout. Stock macOS has no
# timeout command. Perl needs no version manager, and killing the group means a hung child cannot hold a pipe open.
# TERM goes first and is passed down, so a nested call stops its own group; KILL follows after 3 seconds.
run_limited() {
  local t=$1; shift
  perl -e 'use POSIX ":sys_wait_h"; my $t = shift; my $pid = fork(); die "fork: $!" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); open(STDIN, "<", "/dev/null"); exec(@ARGV) or exit 127; }
    sub stop { kill("TERM", -$pid);
      for (1 .. 30) { waitpid($pid, WNOHANG); last unless kill(0, -$pid); select(undef, undef, undef, 0.1); }
      kill("KILL", -$pid); waitpid($pid, 0); exit $_[0]; }
    $SIG{ALRM} = sub { stop(124) }; $SIG{TERM} = sub { stop(143) };
    alarm($t); waitpid($pid, 0); my $s = $?;
    exit($s & 127 ? 128 + ($s & 127) : $s >> 8);' "$t" "$@"
}
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
real() { if [ -d "$1" ]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
wrap_up_failed=0
fail_item() {
  if [ -n "${failures_file:-}" ] && [ -f "$failures_file" ]; then
    printf '%s\t%s\n' "$1" "$2" >> "$failures_file"
  else
    printf '  %s: %s\n' "$1" "$2" >&2
    wrap_up_failed=1
  fi
}
worktree_present_after_remove() { # <path>
  local wt=$1 rwt p
  [ ! -d "$wt" ] || return 0
  rwt=$(real "$wt")
  while IFS= read -r p; do
    if [ "$p" = "$wt" ] || [ "$p" = "$rwt" ] || [ "$(real "$p")" = "$rwt" ]; then
      return 0
    fi
  done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 1
}

# Orca worker-list rows may name the worktree in .workspace or only in .projection.workspace.id (both "id::path").
jq_worker_row_path_expr() { printf '%s' '((.workspace // .projection.workspace.id // "") | split("::")[1] // "")'; }
jq_worker_row_path_finish_expr() { printf '%s' '((.workspace // .worktreeId // .projection.workspace.id // "") | split("::")[1] // "")'; }

# --scheduled: one round on this host. Lock, orca lookup, Orca check, load check, then --apply on every git repo Orca lists.
# A manual run does not take this lock; the guards below recheck before every delete. Always exits 0: a skip is normal, and a
# failure goes to the log and, on two failed rounds in a row, to one GitHub issue. A schedule gives a bare environment, so
# nothing here depends on the login shell. ORCA_CLI_COMMAND stays unset: --apply refuses it as test mode.
round_log() { printf '%s wrap-up-scheduled [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*$round_note" >> "$log_file"; }
rotate_log() { if [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" -gt 5242880 ]; then mv -f "$1" "$1.1"; fi; } # one copy past 5 MB
guarded_round_rm() { # <rf|f> <path>: only this round's own files, inside the state directory
  case "$2" in "$round_state"/*) ;; *) return 1 ;; esac
  if [ "$1" = rf ]; then rm -rf "$2"; else rm -f "$2"; fi
}
guarded_scratch_rm() { # <rf|f> <path>: only this run's $tmp scratch files
  case "$2" in "$tmp"/*) ;; *) return 1 ;; esac
  if [ "$1" = rf ]; then rm -rf "$2"; else rm -f "$2"; fi
}
# Lock, one per host: a file holding the owner's pid, linked into place so it never exists without it. A holder counts
# only when its pid is alive and still runs a scheduled round. A lock with no readable pid counts as live until it is old
# enough to be stale (an older version made a directory). A takeover goes through a guard file, so two runs that both
# judge a lock stale leave one owner.
lock_pid() { cat "$lock" 2>/dev/null || cat "$lock/pid" 2>/dev/null; }
lock_is_stale() {
  local pid; pid=$(lock_pid)
  case "$pid" in
    ''|*[!0-9]*) [ -n "$(find "$lock" -maxdepth 0 -mmin +"$stale_minutes" 2>/dev/null)" ]; return ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 0
  ! ps -p "$pid" -o command= 2>/dev/null | grep -F wrap-up.sh | grep -Fq -- --scheduled
}
# Link a private file holding this pid to $1; fails when $1 exists (ln would drop the file inside a directory, so check first).
link_pid() {
  local mine="$1.$$"
  [ ! -e "$1" ] && echo "$$" > "$mine" && ln "$mine" "$1" 2>/dev/null; local rc=$?
  guarded_round_rm f "$mine"; return "$rc"
}
take_round_lock() {
  link_pid "$lock" && return 0
  if ! lock_is_stale; then round_log "skip: already running (pid $(lock_pid))"; return 1; fi
  local guard="$lock.takeover" got
  if ! link_pid "$guard"; then
    # A guard whose taker died is cleared once it is old; this round still skips.
    [ -z "$(find "$guard" -maxdepth 0 -mmin +"$stale_minutes" 2>/dev/null)" ] || guarded_round_rm f "$guard"
    round_log 'skip: another run is taking over the lock'; return 1
  fi
  if lock_is_stale; then
    round_note=' (stale lock taken over)'
    guarded_round_rm rf "$lock"
  fi
  link_pid "$lock"; got=$?
  guarded_round_rm f "$guard"
  [ "$got" -eq 0 ] || { round_log 'skip: lost the lock race'; return 1; }
}
release_round_lock() { if [ "$(cat "$lock" 2>/dev/null)" = "$$" ]; then guarded_round_rm f "$lock"; fi; }
# The directory of the orca to use. On one host ~/.orca/cli/bin holds a stale remote CLI that cannot reach the app, so it comes last.
find_orca_dir() {
  local stale="$HOME/.orca/cli/bin" dir list
  list="${WRAP_UP_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}:$PATH:$HOME/.local/bin:${extra_bin:-}"
  local IFS=:
  for dir in $list; do
    if [ "$dir" != "$stale" ] && [ -x "$dir/orca" ]; then printf '%s\n' "$dir"; return 0; fi
  done
  [ -x "$stale/orca" ] && printf '%s\n' "$stale"
}
read_load() {
  if [ -n "${WRAP_UP_SCHEDULED_LOAD_CMD:-}" ]; then eval "$WRAP_UP_SCHEDULED_LOAD_CMD" 2>/dev/null
  elif [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg
  else sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; fi
}
read_cores() {
  if [ -n "${WRAP_UP_SCHEDULED_CORES_CMD:-}" ]; then eval "$WRAP_UP_SCHEDULED_CORES_CMD" 2>/dev/null
  else getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; fi
}
# Failure line, then the streak. The second failed round in a row opens one issue; an open issue with the same title stops a duplicate.
round_failed() {
  local n title repo open tilde='~'
  round_log "round failed: $1"
  n=$(cat "$streak" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1)); echo "$n" > "$streak"
  [ "$n" -ge 2 ] || return 0
  repo=${WRAP_UP_ISSUE_REPO:-} # set by the schedule, never defaulted: this repo is public and the title names the host
  if [ -z "$repo" ]; then round_log 'issue: WRAP_UP_ISSUE_REPO is not set; no issue opened'; return 0; fi
  title="wrap-up: scheduled rounds failing on $(hostname -s 2>/dev/null)"
  if ! open=$(run_limited "$call_timeout" gh issue list --repo "$repo" --state open --search "$title in:title" --limit 100 --json title 2>/dev/null) \
    || ! open=$(printf '%s' "$open" | jq -r --arg t "$title" '[.[] | select(.title == $t)] | length' 2>/dev/null); then
    round_log 'issue: cannot read open issues; retried next failed round'; return 0
  fi
  [ "$open" -eq 0 ] || return 0
  if [ "$(run_limited "$call_timeout" gh repo view "$repo" --json isPrivate --jq .isPrivate 2>/dev/null)" != true ]; then
    round_log "issue: $repo is not private or unreadable; no issue opened"; return 0
  fi
  run_limited "$call_timeout" gh issue create --repo "$repo" --title "$title" \
    --body "Scheduled wrap-up failed $n rounds in a row. Latest: ${1//"$HOME"/$tilde}" >/dev/null 2>&1 \
    || round_log 'issue: could not open the issue; retried next failed round'
}
scheduled_round() {
  set +e
  unset ORCA_CLI_COMMAND WRAP_UP_FLEET_CONFIG
  local started=$SECONDS repo_limit=${WRAP_UP_SCHEDULED_REPO_LIMIT:-${WRAP_UP_TOTAL_TIMEOUT:-900}} wrap_up=${WRAP_UP_SCHEDULED_WRAP_UP:-$here/wrap-up.sh}
  local kill_grace=${WRAP_UP_SCHEDULED_KILL_GRACE:-30} precheck_timeout=${WRAP_UP_PRECHECK_TIMEOUT:-600} round_limit
  local detail_file orca_dir status_json load cores list_json repo_path code count=0 fails="" skipped="" seconds left child_limit kill_limit
  if [ -n "${WRAP_UP_SCHEDULED_ROUND_LIMIT:-}" ]; then
    round_limit=$WRAP_UP_SCHEDULED_ROUND_LIMIT
  elif [ "$precheck_timeout" -gt "$((kill_grace * 2))" ]; then
    round_limit=$((precheck_timeout - kill_grace * 2))
  elif [ "$precheck_timeout" -gt "$kill_grace" ]; then
    round_limit=$((precheck_timeout - kill_grace))
  else
    round_limit=$precheck_timeout
  fi
  call_timeout=${WRAP_UP_CALL_TIMEOUT:-60}
  round_state=${WRAP_UP_STATE_DIR-${XDG_STATE_HOME:-$HOME/.local/state}/agent-team}
  log_file=${WRAP_UP_SCHEDULED_LOG:-$HOME/.orca/logs/wrap-up-scheduled.log}
  detail_file="${log_file%.log}-detail.log"
  extra_bin=${WRAP_UP_EXTRA_BIN-/opt/homebrew/bin:/usr/local/bin}
  lock="$round_state/wrap-up-scheduled.lock"
  streak="$round_state/wrap-up-scheduled.failures"
  stale_minutes=${WRAP_UP_SCHEDULED_LOCK_STALE_MINUTES:-10}
  round_note=""
  mkdir -p "$(dirname "$log_file")" "$round_state"
  rotate_log "$log_file"; rotate_log "$detail_file"
  take_round_lock || exit 0
  trap release_round_lock EXIT

  orca_dir=$(find_orca_dir)
  export PATH="${orca_dir:+$orca_dir:}$PATH:$HOME/.local/bin:$extra_bin:/usr/sbin:/sbin"
  if [ -z "$orca_dir" ]; then round_failed 'no orca CLI on this host'; exit 0; fi

  # Orca must answer and report ready.
  if ! status_json=$(run_limited "$call_timeout" orca status --json 2>/dev/null) \
    || [ "$(printf '%s' "$status_json" | jq -r '.result.runtime.state // ""' 2>/dev/null)" != ready ]; then
    round_log 'skip: Orca not ready'; exit 0
  fi

  # 1 minute load against the cores: skip at 0.7 per core or more.
  load=$(read_load); cores=$(read_cores)
  if ! awk -v l="${load:-}" 'BEGIN { exit (l ~ /^[0-9]+([.][0-9]+)?$/) ? 0 : 1 }'; then round_failed 'load unreadable'; exit 0; fi
  case "$cores" in ''|0*|*[!0-9]*) round_failed 'cores unreadable'; exit 0 ;; esac
  if awk -v l="$load" -v c="$cores" 'BEGIN { exit (l / c >= 0.7) ? 0 : 1 }'; then
    round_log "skip: load $load at or above 0.7 per core ($cores cores)"; exit 0
  fi

  if ! list_json=$(run_limited "$call_timeout" orca repo list --json 2>/dev/null) \
    || ! printf '%s' "$list_json" | jq -e '.result.repos | type == "array"' >/dev/null 2>&1; then
    round_failed 'cannot read orca repo list'; exit 0
  fi

  # Per repo, each with its own budget, while keeping the multi-repo round inside WRAP_UP_PRECHECK_TIMEOUT.
  child_mode=--apply
  [ "${scheduled_dry:-0}" = 1 ] && child_mode=--dry-run
  while IFS= read -r repo_path; do
    [ -n "$repo_path" ] || continue
    [ -f "$repo_path/.agents/head-checks.conf" ] || continue
    left=$((round_limit-(SECONDS-started)))
    if [ "$left" -le 0 ]; then
      printf '%s skip repo %s (round budget %ss spent)\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo_path" "$round_limit" >> "$detail_file"
      skipped="${skipped:+$skipped, }$repo_path"
      continue
    fi
    child_limit=$repo_limit
    if [ "$left" -lt "$child_limit" ] && { [ -n "${WRAP_UP_PRECHECK_TIMEOUT:-}${WRAP_UP_SCHEDULED_ROUND_LIMIT:-}${WRAP_UP_SCHEDULED_REPO_LIMIT:-}" ] || [ "$((SECONDS-started))" -gt 0 ]; }; then
      child_limit=$left
    fi
    kill_limit=$((child_limit+kill_grace))
    printf '%s repo %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo_path" >> "$detail_file"
    # The child stops itself at its budget; the grace only kills a run hung outside its bounded calls.
    # Each slow step has its own cap so one fetch, release, pane sweep or main update cannot spend the round.
    repo_mark=$SECONDS
    WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TOTAL_TIMEOUT=$child_limit \
      WRAP_UP_CALL_TIMEOUT=${WRAP_UP_SCHEDULED_CALL_TIMEOUT:-30} \
      WRAP_UP_PANE_TIMEOUT=${WRAP_UP_SCHEDULED_PANE_TIMEOUT:-20} \
      WRAP_UP_MAIN_TIMEOUT=${WRAP_UP_SCHEDULED_MAIN_TIMEOUT:-20} \
      WRAP_UP_RELEASE_BUDGET=${WRAP_UP_SCHEDULED_RELEASE_BUDGET:-25} \
      WRAP_UP_OPTIONAL_STEP=${WRAP_UP_SCHEDULED_OPTIONAL_STEP:-20} \
      run_limited "$kill_limit" bash "$wrap_up" "$child_mode" --repo "$repo_path" >> "$detail_file" 2>&1
    code=$?
    printf '%s repo %s seconds=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo_path" "$((SECONDS-repo_mark))" >> "$detail_file"
    printf 'repo %s seconds=%s\n' "$repo_path" "$((SECONDS-repo_mark))"
    if [ "$code" -eq 75 ]; then
      printf '%s skip repo %s (another wrap-up run holds the lock)\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$repo_path" >> "$detail_file"
      skipped="${skipped:+$skipped, }$repo_path"
      continue
    fi
    count=$((count+1))
    [ "$code" -eq 0 ] || fails="${fails:+$fails; }repo $repo_path exit $code"
  done < <(printf '%s' "$list_json" | jq -r '.result.repos[] | select(.kind == "git") | .path')

  seconds=$((SECONDS-started))
  if [ -n "$fails" ]; then round_failed "${fails}${skipped:+; skipped=$skipped}"; exit 0; fi
  guarded_round_rm f "$streak"
  # Board cards move to Done here, not in fleet-watch: that pass is frozen and only alerts, and this
  # round is already the one that reads workspaceStatus. Only the coordinator runs it, after cleanup,
  # so this round does not delete a card that just became Done. Each paired host is reached with
  # --environment; an unreachable host is skipped and tried again next round.
  if coordinator_runs_board_done; then
    local board_bin board_mode board_limit board_code
    board_bin=${WRAP_UP_BOARD_DONE:-$here/board-done.py}
    board_mode=--apply
    [ "${scheduled_dry:-0}" = 1 ] && board_mode=--dry-run
    board_limit=${WRAP_UP_SCHEDULED_BOARD_TIMEOUT:-120}
    if [[ "$board_bin" == *.py ]]; then
      run_limited "$board_limit" python3 "$board_bin" --fleet "$board_mode" >> "$detail_file" 2>&1
    else
      run_limited "$board_limit" bash "$board_bin" --fleet "$board_mode" >> "$detail_file" 2>&1
    fi
    board_code=$?
    [ "$board_code" -eq 0 ] || round_log "board-done exit $board_code"
  fi
  round_log "round ok: repos=$count seconds=$seconds${skipped:+ skipped=$skipped}"
  exit 0
}
coordinator_runs_board_done() {
  local conf name here_name
  conf=${BOARD_DONE_COORDINATOR_CONF:-${AGENT_STATE_DIR:-$HOME/agent-state}/coordinator.conf}
  [ -f "$conf" ] || return 1
  name=$(awk '$1 == "coordinator" { print $2; exit }' "$conf")
  here_name=$(hostname -s 2>/dev/null || true)
  [ -n "$name" ] && [ "$name" = "$here_name" ]
}

# --branch: cleanup after ship.sh reads MERGED. Run from a checkout of the repo.
# Usage: wrap-up.sh --branch <pr head> [--head-sha <merged sha>] [--branch ...]    DRY_RUN=1 only prints.
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
# WRAP_UP_CALL_TIMEOUT (default 60); a call that times out is reported as kept.
# --issue and --pr are accepted and ignored: the caller no longer needs numbers here.
limited() { run_limited "$call_timeout" "$@"; }
# Branches under archive/ are never deleted by any cleanup route.
archive_branch() { case "$1" in archive/*) return 0 ;; esac; return 1; }
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
# Sets owner_state (none, unreleased or released) and released_ids for a worktree path, by worker_state.can_remove.
owner_of() {
  local verdict
  released_ids=()
  verdict=$(ROWS="$rows_json" python3 -c '
import json, os, sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
ok, reason, ids = ws.can_remove(json.loads(os.environ["ROWS"]), os.path.realpath(sys.argv[2]), os.path.realpath)
print("released" if ok else ("none" if "owns" in reason else "unreleased"), *ids)' "$worker_state_dir" "$1") || { owner_state=unreleased; return; }
  owner_state=${verdict%% *}
  [ "$verdict" = "$owner_state" ] || read -r -a released_ids <<<"${verdict#* }"
}
wt_of() { git worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'; }
# True when the commit $1 is in origin/main, or equals the merged sha $2.
settled() {
  git merge-base --is-ancestor "$1" origin/main 2>/dev/null && return 0
  [ -n "${2:-}" ] && [ "$(git rev-parse --verify -q "$1^{commit}")" = "$2" ]
}
guarded_merged_worktree_remove() { # <path> <label>: after free_worktree's checks
  local rc=0
  limited git worktree remove -- "$1" >/dev/null 2>&1 || rc=$?
  if [ $rc != 0 ]; then echo "Kept worktree $1 ($2, removal failed)"; return 1; fi
  git worktree prune
  if worktree_present_after_remove "$1"; then
    fail_item "worktree $1" "worktree still present after remove: $1"
    echo "Kept worktree $1 ($2, worktree still present after remove: $1)"
    return 1
  fi
}
guarded_merged_local_delete() { # <branch>: after drop_branch's checks
  if ! run git branch -D -- "$1" >/dev/null; then
    fail_item "local $1" 'delete failed'
    return 1
  fi
  if [ "$dry" != 1 ] && git show-ref --verify --quiet "refs/heads/$1"; then
    fail_item "local $1" "branch ref still exists after delete: $1"
    echo "Kept $1 (branch ref still exists after delete: $1)"
    return 1
  fi
}
guarded_merged_remote_delete() { # <branch>: after drop_branch's checks
  local rc=0
  if [ "$dry" = 1 ]; then echo "[dry-run] git push -q origin --delete $1"; return 0; fi
  limited git push -q origin --delete "$1" >/dev/null 2>&1 || rc=$?
  if [ $rc = 124 ]; then echo "Kept remote $1 (delete timed out)"; elif [ $rc != 0 ]; then echo "wrap-up: remote delete of $1 failed" >&2; fi
}
# Removes the worktree at $1 when it is owned, released, idle, clean and merged. $2 is its label, $3 the merged sha.
# Returns non-zero, after printing why, when it stays.
free_worktree() {
  local wt=$1 label=$2 sha=${3:-} rc
  wt=$(real "$wt")
  if [ "$wt" = "$top" ]; then echo "Kept worktree $wt (current)"; return 1; fi
  case "${wt##*/}" in
    lead-*) echo "protected: kept worktree $wt (lead worktree)"; return 1 ;;
    rm-*) echo "protected: kept worktree $wt (rm-* worktree)"; return 1 ;;
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
      rc=0; limited bash "$pane_close" "${released_ids[@]}" >/dev/null 2>&1 || rc=$?
      if [ $rc = 124 ]; then echo "Kept worktree $wt ($label, closing its panes timed out)"; return 1; fi
    fi
  fi
  rc=0; limited python3 "$here/worktree-idle.py" "$wt" >/dev/null 2>&1 || rc=$?
  if [ $rc != 0 ]; then
    if [ $rc = 124 ]; then echo "Kept worktree $wt ($label, terminal check timed out)"
    else echo "protected: kept worktree $wt (live terminal or unknown inventory)"; fi
    return 1
  fi
  echo "Remove worktree $wt"
  if [ "$dry" != 1 ]; then guarded_merged_worktree_remove "$wt" "$label" || return 1; fi
}

# Removes one branch, its worktree first. $2 is the merged sha when this is a merged PR head.
drop_branch() {
  local b=$1 sha=${2:-} wt tip
  keep_protected "$b" && return 0
  archive_branch "$b" && { echo "Kept $b (archive branch)"; return 0; }
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
    echo "Delete local $b"; guarded_merged_local_delete "$b" || return 0
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/$b" && ! settled "refs/remotes/origin/$b" "$sha"; then
    echo "Kept remote $b (commits not in origin/main)"
  elif git show-ref --verify --quiet "refs/remotes/origin/$b"; then
    echo "Delete remote $b"
    guarded_merged_remote_delete "$b"
  fi
}
after_merge() {
  dry=${DRY_RUN:-0}
  extra_bin=${WRAP_UP_EXTRA_BIN-/opt/homebrew/bin:/usr/local/bin}
  orca_dir=$(find_orca_dir) || true
  export PATH="${orca_dir:+$orca_dir:}$PATH:$HOME/.local/bin:$extra_bin"
  orca=${ORCA_CLI_COMMAND:-orca}
  pane_close=${WORKER_PANE_CLOSE:-$HOME/.claude/skills/orca-team/worker-pane-close.sh}
  call_timeout=${WRAP_UP_CALL_TIMEOUT:-60}
  branches=() shas=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branches+=("${2:-}"); shas+=(""); shift 2 ;;
      --head-sha)
        [ ${#branches[@]} -gt 0 ] || { echo "wrap-up: --head-sha needs a --branch before it" >&2; exit 2; }
        shas[${#shas[@]}-1]=${2:-}; shift 2 ;;
      --issue|--pr) case "${2:-}" in ''|*[!0-9]*) echo "wrap-up: $1 must be a number" >&2; exit 2 ;; esac; shift 2 ;;
      *) echo "wrap-up: unknown argument $1" >&2; exit 2 ;;
    esac
  done
  [ ${#branches[@]} -gt 0 ] || { echo "usage: wrap-up.sh --branch <name> [--head-sha <sha>] [--branch ...]" >&2; exit 2; }

  top=$(cd -P "$(git rev-parse --show-toplevel)" && pwd)
  current=$(git symbolic-ref --quiet --short HEAD || true)

  if [ "$dry" = 1 ]; then
    echo "[dry-run] no fetch; using already-fetched refs"
  else
    limited git fetch -q origin >/dev/null 2>&1 || echo "wrap-up: fetch failed or timed out; using existing refs" >&2
  fi

  # Orca inventory, read once: every worker row of every Run and page. worker-list without --run sees only the
  # caller's Run, so read run-list first; a Run or page that cannot be read leaves the inventory unavailable.
  # worker_state.can_remove decides per worktree.
  worker_state_dir=${WORKER_STATE_DIR:-$here/../.agents/skills/orca-team}
  page_size=${WRAP_UP_PAGE_SIZE:-100}
  rows_json="" inventory_ok=0
  read_rows='
import json, subprocess, sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
orca, size = sys.argv[2], sys.argv[3]
def pages(args):
    cursor, seen = "", set()
    while True:
        cmd = [orca, "orchestration", *args, "--limit", size, "--json"] + (["--cursor", cursor] if cursor else [])
        r = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True, stdin=subprocess.DEVNULL).stdout)["result"]
        yield r
        cursor = ws.next_cursor(r)
        if not cursor: return
        if cursor in seen: raise ValueError("cursor repeated")
        seen.add(cursor)
rows = []
for run in [x["id"] for r in pages(["run-list"]) for x in r["runs"]]:
    for r in pages(["worker-list", "--run", run]): rows += r["workers"]
json.dump(rows, sys.stdout)'
  if command -v "$orca" >/dev/null 2>&1 && [ -f "$worker_state_dir/worker_state.py" ] \
    && rows_json=$(limited python3 -c "$read_rows" "$worker_state_dir" "$orca" "$page_size" 2>/dev/null) && [ -n "$rows_json" ]; then
    inventory_ok=1
  fi

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
  [ "$wrap_up_failed" -eq 0 ] || exit 1
}

# --finish-worker: finish path for a settled worker. Verify head (when required), native worker-release, optional worktree removal.
# Usage: wrap-up.sh --finish-worker --worktree <path> [--dispatch <id>]... [--task-id <id>] [--skip-head-checks "<reason>"]
#   DRY_RUN=1 only prints. Head-checks run first unless skipped or the head is already merged.
# Worktree removal runs only after every dispatch receives released or already_released from worker-release.
merged() {
  git -C "$wt" fetch -q origin main 2>/dev/null || return 1
  if git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then echo "HEAD is already in origin/main"; return 0; fi
  [ "$(cd "$wt" && gh pr view --json state -q .state 2>/dev/null)" = MERGED ] && echo "its PR is already merged"
}

head_proven_in_merged_main() {
  local head="" unique="" mb_rc=0 pr_state="" pr_head=""
  if ! git -C "$wt" fetch -q origin main 2>&1; then
    echo "wrap-up: cannot verify main ancestry; worktree kept at $wt" >&2
    return 1
  fi
  if ! git -C "$wt" rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "wrap-up: cannot verify origin/main; worktree kept at $wt" >&2
    return 1
  fi
  if ! head=$(git -C "$wt" rev-parse HEAD 2>&1); then
    echo "wrap-up: cannot verify HEAD; worktree kept at $wt" >&2
    return 1
  fi
  git -C "$wt" merge-base --is-ancestor "$head" origin/main 2>/dev/null
  mb_rc=$?
  if [ "$mb_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$mb_rc" -gt 1 ]; then
    echo "wrap-up: cannot verify main ancestry; worktree kept at $wt" >&2
    return 1
  fi
  if ! unique=$(git -C "$wt" rev-list --count origin/main.."$head" 2>&1); then
    echo "wrap-up: cannot verify commit ancestry; worktree kept at $wt" >&2
    return 1
  fi
  if [ "$unique" -eq 0 ]; then
    echo "wrap-up: cannot verify main ancestry; worktree kept at $wt" >&2
    return 1
  fi
  if pr_state=$(cd "$wt" && gh pr view --json state -q .state 2>&1); then
    if ! pr_head=$(cd "$wt" && gh pr view --json headRefOid -q .headRefOid 2>&1); then
      echo "wrap-up: cannot verify PR head; worktree kept at $wt" >&2
      return 1
    fi
    if [ "$pr_state" = MERGED ] && [ -n "$pr_head" ] && [ "$pr_head" = "$head" ]; then
      return 0
    fi
  else
    case "$pr_state" in
      *"no pull requests"*|*"no such PR"*) ;;
      *)
        echo "wrap-up: cannot verify PR merge state; worktree kept at $wt" >&2
        return 1
        ;;
    esac
  fi
  echo "wrap-up: HEAD not proven in merged main; worktree kept at $wt" >&2
  return 1
}

guarded_finish_remove() { # <path>: after every check in finish_worker
  if [ "$dry" = 1 ]; then
    echo "[dry-run] git worktree remove -- $1"
    echo "[dry-run] git worktree prune"
    return 0
  fi
  if ! git worktree remove -- "$1"; then
    echo "wrap-up: worktree remove failed; kept $1" >&2
    exit 1
  fi
  git worktree prune
  if worktree_present_after_remove "$1"; then
    fail_item "worktree $1" "worktree still present after remove: $1"
    exit 1
  fi
}

finish_worker() {
  dry=${DRY_RUN:-0}
  extra_bin=${WRAP_UP_EXTRA_BIN-/opt/homebrew/bin:/usr/local/bin}
  orca_dir=$(find_orca_dir) || true
  export PATH="${orca_dir:+$orca_dir:}$PATH:$HOME/.local/bin:$extra_bin"
  orca=${ORCA_CLI_COMMAND:-orca}
  wt="" dispatches=() skip="" skip_set=0 expect_task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) wt=${2:-}; shift 2 ;;
      --dispatch) dispatches+=("${2:-}"); shift 2 ;;
      --task-id) expect_task=${2:-}; shift 2 ;;
      --skip-head-checks) skip_set=1; skip=${2:-}; [ $# -ge 2 ] && shift; shift ;;
      *) echo "wrap-up: unknown argument $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$wt" ] || { echo "usage: wrap-up.sh --finish-worker --worktree <path> [--dispatch <id>]... [--task-id <id>]" >&2; exit 2; }
  wt=$(real "$wt")
  archive_dir=${WRAP_UP_ARCHIVE_DIR:-}
  if [ -n "$archive_dir" ]; then mkdir -p "$archive_dir"; fi

  if [ "$skip_set" = 1 ]; then
    [ -n "$skip" ] || { echo "wrap-up: --skip-head-checks needs a reason" >&2; exit 2; }
    echo "wrap-up: skipping head-checks: $skip"
  else
    checks=${HEAD_CHECKS:-$HOME/dotfiles/script/head-checks.sh}
    if why=$(merged); then
      echo "wrap-up: skipping head-checks, $why"
    elif [ "$dry" = 1 ]; then
      echo "[dry-run] $checks --repo $wt --ref HEAD --base origin/main"
    elif ! "$checks" --repo "$wt" --ref HEAD --base origin/main; then
      echo "wrap-up: head-checks failed, refusing worker_done" >&2
      exit 1
    fi
  fi

  if [ ${#dispatches[@]} -eq 0 ] && command -v "$orca" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r id path; do
      [ -n "$id" ] && [ "$(real "$path")" = "$wt" ] && dispatches+=("$id")
    done < <("$orca" orchestration worker-list --json 2>/dev/null \
      | jq -r '.result.workers[]? | select((.dispatchStatus // .state) != "released" and .stage != "released") | [.dispatchId, ('"$(jq_worker_row_path_finish_expr)"')] | @tsv' 2>/dev/null || true)
  fi

  if ! command -v "$orca" >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "wrap-up: orca and jq are required for worker-release" >&2
    exit 1
  fi

  if [ ${#dispatches[@]} -eq 0 ]; then
    echo "wrap-up: no dispatch id for $wt; refusing release and worktree removal" >&2
    exit 1
  fi

  closed=0 already=0 retained=0 pending=0 unknown=0
  fail=0
  release_body="" release_rc=0

  for id in ${dispatches[@]+"${dispatches[@]}"}; do
    if [ "$dry" = 1 ]; then
      echo "[dry-run] $orca orchestration worker-show --dispatch $id --json"
      echo "[dry-run] $orca orchestration worker-release --dispatch $id --json"
      closed=$((closed + 1))
      continue
    fi
    show=$("$orca" orchestration worker-show --dispatch "$id" --json 2>&1) || {
      echo "wrap-up: worker-show failed for $id; refusing cleanup" >&2
      exit 1
    }
    if [ -n "$archive_dir" ]; then printf '%s\n' "$show" > "$archive_dir/show-$id.json"; fi
    # Current Orca prints result.state/stage/liveness; older Orca nested the status under result.dispatch.
    status=$(printf '%s' "$show" | jq -r '.result | if (.state | type) == "string" then .state else (.dispatch.status // empty) end' 2>/dev/null) || status=""
    final=$(printf '%s' "$show" | jq -r '.result | if .stage == "released" or .terminalState == "released" or .liveness == "exited" then "final" else empty end' 2>/dev/null) || final=""
    [ -z "$final" ] || status="${status:-released}:final"
    case "$status" in
      succeeded|completed|failed|cancelled|released|stopped|*:final) status=${status%:final} ;;
      *)
        echo "wrap-up: refusing release for $id (dispatch status=${status:-unknown})" >&2
        exit 1
        ;;
    esac
    if [ -n "$expect_task" ]; then
      got=$(printf '%s' "$show" | jq -r '.result.taskId // .result.dispatch.taskId // .result.task.id // empty' 2>/dev/null) || got=""
      [ "$got" = "$expect_task" ] || {
        echo "wrap-up: task id mismatch for $id (expected $expect_task, got ${got:-<empty>})" >&2
        exit 1
      }
    fi
    release_body=$("$orca" orchestration worker-release --dispatch "$id" --json 2>&1) || release_rc=$?
    if [ -n "$archive_dir" ]; then printf '%s\n' "$release_body" > "$archive_dir/release-$id.json"; fi
    parsed=$(RELEASE_BODY="$release_body" RELEASE_RC="${release_rc:-0}" DISPATCH_ID="$id" python3 <<'PY'
import json, os, sys
body = os.environ.get("RELEASE_BODY", "")
rc = int(os.environ.get("RELEASE_RC", "0"))
dispatch_id = os.environ.get("DISPATCH_ID", "")
try:
    doc = json.loads(body)
except Exception:
    print("malformed", rc)
    sys.exit(0)
if doc.get("ok") is not True:
    code = (doc.get("error") or {}).get("code") or "error"
    print(code, rc)
    sys.exit(0)
result = doc.get("result") or {}
rid = result.get("dispatchId")
if dispatch_id:
    if rid is None or rid == "":
        print("missing", rc)
        sys.exit(0)
    if rid != dispatch_id:
        print("id_mismatch", rc)
        sys.exit(0)
state = result.get("state") or "missing"
if state in ("released", "already_released") and rc != 0:
    print("nonzero_success", rc)
    sys.exit(0)
print(state, rc)
PY
  ) || {
      echo "wrap-up: could not parse worker-release response for $id" >&2
      fail=1
      unknown=$((unknown + 1))
      continue
    }
    state=${parsed%% *}
    prc=${parsed#* }
    case "$state" in
      released) closed=$((closed + 1)) ;;
      already_released) already=$((already + 1)) ;;
      retained)
        retained=$((retained + 1))
        reason=$(printf '%s' "$release_body" | jq -r '.result.reason // empty' 2>/dev/null || true)
        echo "wrap-up: $id retained${reason:+ ($reason)}; worktree kept" >&2
        ;;
      release_pending) pending=$((pending + 1)); echo "wrap-up: $id release_pending; worktree kept" >&2 ;;
      release_unknown|missing|malformed|error|dispatch_not_found|id_mismatch|nonzero_success)
        unknown=$((unknown + 1))
        fail=1
        echo "wrap-up: worker-release for $id failed ($state, exit $prc)" >&2
        printf '%s\n' "$release_body" >&2
        ;;
      *)
        unknown=$((unknown + 1))
        fail=1
        echo "wrap-up: worker-release for $id returned unknown state $state" >&2
        printf '%s\n' "$release_body" >&2
        ;;
    esac
  done

  echo "wrap-up: closed=$closed already_released=$already retained=$retained pending=$pending unknown=$unknown"

  if [ "$fail" -ne 0 ]; then
    echo "wrap-up: refusing worktree removal after failed or unknown release" >&2
    exit 1
  fi

  if [ "$retained" -ne 0 ] || [ "$pending" -ne 0 ]; then
    echo "wrap-up: worktree kept at $wt"
    exit 0
  fi

  if [ "$dry" != 1 ]; then
    wt_porcelain=""
    unmerged_diff="" unmerged_index=""
    if ! wt_porcelain=$(git -C "$wt" status --porcelain 2>&1); then
      echo "wrap-up: cannot inspect worktree status; worktree kept at $wt" >&2
      exit 0
    fi
    if ! unmerged_diff=$(git -C "$wt" diff --name-only --diff-filter=U 2>&1); then
      echo "wrap-up: cannot inspect unmerged diff; worktree kept at $wt" >&2
      exit 0
    fi
    if ! unmerged_index=$(git -C "$wt" ls-files -u 2>&1); then
      echo "wrap-up: cannot inspect unmerged index; worktree kept at $wt" >&2
      exit 0
    fi
    if [ -n "$wt_porcelain" ] \
      || git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
      || [ -n "$unmerged_diff" ] \
      || [ -n "$unmerged_index" ]; then
      echo "wrap-up: dirty or unmerged worktree kept at $wt"
      exit 0
    fi
  fi

  if [ "$dry" = 1 ]; then
    guarded_finish_remove "$wt"
    exit 0
  fi

  if ! head_proven_in_merged_main; then
    exit 0
  fi

  if [ -d "$wt" ]; then
    guarded_finish_remove "$wt"
    echo "wrap-up: removed worktree $wt"
  fi
}

# Each mode ends the script, so what follows is the default: preview or apply a repo's finished work.
case "${1:-}" in
  --scheduled)
    shift
    scheduled_dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) scheduled_dry=1 ;;
        --apply) scheduled_dry=0 ;;
        -h|--help) echo 'Usage: wrap-up.sh --scheduled [--dry-run|--apply]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
      esac
      shift
    done
    scheduled_round
    ;;
  --finish-worker) shift; finish_worker "$@"; exit 0 ;;
  --branch|--head-sha|--issue|--pr) after_merge "$@"; exit 0 ;;
esac
apply=0
fleet=0
worktrees_only=0
main_update=0
repo=.
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) apply=0 ;;
    --apply) apply=1 ;;
    --stale) : ;; # Accepted for compatibility; stale cleanup is part of every apply.
    --fleet) fleet=1 ;;
    --worktrees-only) worktrees_only=1 ;;
    --main-update) main_update=1 ;; # With --worktrees-only: also update main and install the preset (used per fleet host).
    --repo) [ $# -ge 2 ] || { echo 'Missing --repo path' >&2; exit 2; }; repo=$2; shift ;;
    -h|--help)
      echo 'Usage: wrap-up.sh [--dry-run|--apply] [--stale] [--fleet] [--repo <path>] | --scheduled [--dry-run] | --branch <name> [--head-sha <sha>] ... | --finish-worker --worktree <path>'
      echo 'Worst case runtime: a dry run takes about 5 minutes for one repo. --apply is bounded by WRAP_UP_TOTAL_TIMEOUT (default 900 s), then'
      echo 'the pane close step may add up to WRAP_UP_PANE_TIMEOUT (default 1800 s), each of its calls limited to WRAP_UP_PANE_CALL_TIMEOUT (default 10 s).'
      echo 'The summary counts print before the pane step, so a caller that times out there has them. Only one --apply runs at a time (exit 75 names the holder).'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$fleet" -eq 0 ] || [ "$worktrees_only" -eq 0 ] || { echo 'wrap-up: --fleet and --worktrees-only exclude each other' >&2; exit 2; }
[ "$main_update" -eq 0 ] || [ "$worktrees_only" -eq 1 ] || { echo 'wrap-up: --main-update needs --worktrees-only' >&2; exit 2; }
# A fake orca CLI means a test: never let --apply reach the real temp roots from there.
if [ "$apply" -eq 1 ] && [ -n "${ORCA_CLI_COMMAND:-}" ] && { [ -z "${WRAP_UP_SCRATCH_ROOT+x}" ] || [ -z "${WRAP_UP_LOOSE_ROOT+x}" ]; }; then
  echo 'wrap-up: ORCA_CLI_COMMAND is set (test mode); set WRAP_UP_SCRATCH_ROOT and WRAP_UP_LOOSE_ROOT before --apply' >&2; exit 2
fi
# The browser sweep stops real processes. In test mode it runs only through both fake seams, never the real ps or stop.
browser_sweep=1
if [ -n "${ORCA_CLI_COMMAND:-}" ] && { [ -z "${WRAP_UP_PS_CMD:-}" ] || [ -z "${WRAP_UP_KILL_CMD:-}" ]; }; then browser_sweep=0; fi
command -v jq >/dev/null || { echo 'wrap-up requires jq' >&2; exit 1; }
# One --apply at a time on a host: a file holding the owner's pid, created exclusively. A holder counts only while its pid is
# alive and still runs wrap-up.sh; a run that finds one prints the holder and exits 75. A dry run changes nothing and takes no lock.
apply_lock='' apply_lock_mine=0
guarded_lock_rm() { case "$1" in */wrap-up-apply.lock) rm -f "$1" ;; *) return 1 ;; esac; } # only this lock file
release_apply_lock() { if [ "$apply_lock_mine" -eq 1 ] && [ "$(cat "$apply_lock" 2>/dev/null)" = "$$" ]; then guarded_lock_rm "$apply_lock"; fi; }
take_apply_lock() {
  local dir=${WRAP_UP_STATE_DIR-${XDG_STATE_HOME:-$HOME/.local/state}/agent-team} pid i
  mkdir -p "$dir"; apply_lock="$dir/wrap-up-apply.lock"
  for i in 1 2; do
    if ( set -o noclobber; echo "$$" > "$apply_lock" ) 2>/dev/null; then apply_lock_mine=1; return 0; fi
    pid=$(cat "$apply_lock" 2>/dev/null || true)
    if [ -z "$pid" ] && [ -n "$(find "$apply_lock" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then pid=starting; fi
    if [ "$pid" = starting ] || { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -Fq wrap-up.sh; }; then
      echo "wrap-up: another run holds the lock $apply_lock (pid $pid: $(ps -p "$pid" -o command= 2>/dev/null | cut -c1-120)); not starting" >&2
      exit 75
    fi
    guarded_lock_rm "$apply_lock"
  done
  echo "wrap-up: could not take the lock $apply_lock; not starting" >&2; exit 75
}
extra_bin=${WRAP_UP_EXTRA_BIN-/opt/homebrew/bin:/usr/local/bin}
orca_dir=$(find_orca_dir) || true
export PATH="${orca_dir:+$orca_dir:}$PATH:$HOME/.local/bin:$extra_bin"
repo=$(git -C "$repo" rev-parse --show-toplevel)
cd "$repo"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; release_apply_lock' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
[ "$apply" -eq 0 ] || take_apply_lock
finish() { # prints every failed item with its reason; exit 1 when there is any
  local n; n=$(wc -l < "$tmp/failures" | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    printf 'Failures (%s), retried next run:\n' "$n"
    awk -F'\t' '{ printf "  %s: %s\n", $1, $2 }' "$tmp/failures"
    exit 1
  fi
  exit "$inventory_failed"
}
# Failure ledger. An item wrap-up could not clean is named here with its reason and printed at the end; the run exits
# non-zero and the next run tries it again. A file, so a call made in a subshell still records.
failures_file="$tmp/failures"
: > "$failures_file"
# Every call to git on the network, gh and orca goes through bounded: at most WRAP_UP_CALL_TIMEOUT seconds each (default 60),
# and none starts once WRAP_UP_TOTAL_TIMEOUT seconds (default 900) have passed. Runs the call in its own process group and
# kills the group. Exit 124 means timed out or skipped; either is recorded.
call_timeout=${WRAP_UP_CALL_TIMEOUT:-60}
total_timeout=${WRAP_UP_TOTAL_TIMEOUT:-900}
deadline=$((SECONDS+total_timeout))
optional_deadline=$deadline
# A scheduled round gives each slow optional step its own short limit. A manual run keeps the overall deadline.
begin_optional() {
  local s=${1:-${WRAP_UP_OPTIONAL_STEP:-20}}
  if [ -n "${WRAP_UP_SCHEDULED_CHILD:-}" ]; then optional_deadline=$((SECONDS + s)); else optional_deadline=$deadline; fi
}
optional_ok() { [ "$SECONDS" -lt "$optional_deadline" ]; }
optional_stop() { echo "Warning: $1 stopped at its time limit; the rest waits for the next run." >&2; }
bounded() {
  local left=$((deadline-SECONDS)) t rc=0
  if [ "$left" -le 0 ]; then
    [ -e "$tmp/limit-noted" ] || { : > "$tmp/limit-noted"; fail_item run "overall time limit of ${total_timeout}s reached; later calls skipped"; }
    return 124
  fi
  t=$call_timeout; [ "$left" -ge "$t" ] || t=$left
  run_limited "$t" "$@" || rc=$?
  if [ "$rc" -eq 124 ]; then fail_item "${1##*/} ${2:-} ${3:-}" "timed out after ${t}s"; fi
  return "$rc"
}
# Preview also refreshes tracking refs; only apply changes branches or worktrees.
# Called after terminal close so a slow fetch or PR lookup cannot spend the round before any terminal is closed.
refresh_refs() {
  begin_optional "${WRAP_UP_SCHEDULED_CALL_TIMEOUT:-30}"
  bounded git fetch --prune origin || fail_item 'git fetch' 'failed or timed out; refs may be stale, so fewer items qualify'
  git for-each-ref --format='%(refname) %(objectname)' refs/remotes/origin > "$tmp/remote-planned"
  git rev-parse --verify origin/main >/dev/null
  # One PR lookup for all local and remote branches. An open PR wins over an older closed PR.
  pr_ok=1
  if ! bounded gh pr list --state all --limit 1000 --json headRefName,headRefOid,state > "$tmp/prs"; then
    echo 'Warning: PR lookup unavailable; using ancestry only, stale branches not listed.' >&2
    fail_item 'PR lookup' 'unavailable; closed-PR branches not cleaned this run'
    echo '[]' > "$tmp/prs"; pr_ok=0
  fi
  jq -e 'type == "array"' "$tmp/prs" >/dev/null
  jq -r '.[] | select(.state == "OPEN") | .headRefName' "$tmp/prs" | sort -u > "$tmp/open"
  jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | select(any(.[]; .state == "MERGED" or .state == "CLOSED")) | .[0].headRefName' "$tmp/prs" > "$tmp/closed"
  jq -r 'group_by(.headRefName)[] | select(any(.[]; .state == "OPEN") | not) | .[] | select(.state == "MERGED" or .state == "CLOSED") | .headRefOid // empty' "$tmp/prs" > "$tmp/closed-heads"
  jq -r '.[] | select(.state == "OPEN") | .headRefOid // empty' "$tmp/prs" | sort -u > "$tmp/open-heads"
}
pr_ok=1
echo '[]' > "$tmp/prs"
: > "$tmp/open"
: > "$tmp/closed"
: > "$tmp/closed-heads"
: > "$tmp/open-heads"
: > "$tmp/active"
inventory_read=0
# Set when an unsettled dispatch names a head-checks, QA, browser or gated run: its process may be gone while it still needs the browser.
dispatch_run=''
orca_bin=${ORCA_CLI_COMMAND:-orca}
orca_call() { bounded "$orca_bin" "$@"; }
orca=orca_call
# Close finished terminals on the local host and every listed environment, before the worktree check reads the inventory.
# A released dispatch has no agentTerminalHandle and its leftover terminals still look connected, so a terminal is linked to
# dispatches by handle and by worktree path. Closed: a terminal of a settled dispatch, one whose process exited, or one with
# any other on a path where every dispatch is settled (shells, worker-pane.sh panes, an agent idle at its prompt). Kept: our own,
# a Run coordinator's, a live dispatch's, a lead- worktree's, one with output in the last 10 minutes (a correction pass runs on a
# settled dispatch), a running agent, one outside a worktree, and the main checkout's. A local terminal with no dispatch and
# no running agent is closed (issue 551), on the coordinator and on a fleet host (--worktrees-only). A scheduled
# round closes that local shell once it has had no output for 60 minutes; newer output stays. A shell whose worktree
# path, worktree id, or cwd is a live dispatch's worktree, or a directory inside it, stays open on a scheduled round
# and on a manual run. Every run, manual or scheduled, also closes a
# terminal that is asleep: liveness sleep or exited, or a shell at its prompt with no output for that same
# 60 minutes when no unsettled dispatch owns it. A connected agent with no dispatch record is an owner session and stays,
# on this host and on a fleet host, manual or scheduled, unless Orca reports it asleep. A dispatch that is running, ready,
# pending or waiting keeps the terminal unless liveness is sleep or exited. The prompt is the last non-empty line, so a
# progress line, a heading or a wait for a reply does not count. The same screen read keeps a terminal whose preview shows
# an unanswered question, a pending ask, or an escalation, or whose terminal show reports agentWait, even when the dispatch
# looks settled. List preview can be scrollback from before a full-screen agent started, so the round reads the current
# screen of idle terminals before it decides. On another environment a terminal with no dispatch record and no running
# agent stays kept as unknown owner (a dev server, another coordinator), unless it is asleep or its worktree was removed
# by this run: a second pass over the environments, after the worktree step, closes those. Only a shell with no running
# agent, at a path the environment no longer reports; scheduled rounds close those too. A running agent in a removed
# worktree stays open until its dispatch settles (the gap: a manual run closes it).
# worker-list without --run covers only the Run bound to the caller, and a Run can live on any Orca. So the inventory reads
# every Run on this Orca and on every environment, and one inventory serves all of them; if any of it is unread, nothing closes.
# Each Orca is read directly, so no --include-remote: with it one unreachable host makes a whole Run answer ok:false.
term_closed=0; term_kept=0
main_path=$(git worktree list --porcelain | sed -n '1s/^worktree //p'); main_path=$(cd "$main_path" 2>/dev/null && pwd -P || printf '%s' "$main_path")
: > "$tmp/closing"
: > "$tmp/removed-paths"
terminals_read=0
: > "$tmp/kept-terminals"
terminal_kept() { printf 'Kept terminal %s (%s, %s)\n' "$1" "$2" "$3"; printf '%s %s\n' "$2" "$1" >> "$tmp/kept-terminals"; term_kept=$((term_kept+1)); }
close_terminal_err='close failed'
# terminal show keeps a closed session with no state or status field. Live means this handle is still connected.
# A list payload, a missing handle, or connected false is not a live session.
terminal_show_live() {
  jq -e --arg h "$1" '
    def term:
      if (.result.terminal | type) == "object" then .result.terminal
      elif (.result | type) == "object" and ((.result.handle | type) == "string") then .result
      else {} end;
    .ok == true and (term | .handle == $h and .connected == true and .writable != false
      and .state != "closed" and .status != "closed" and .orphaned != true)
  ' >/dev/null 2>&1
}
close_terminal() {
  local h='' a show rc=0
  for a in "$@"; do h=$a; done
  close_terminal_err='close failed'
  "$orca" terminal close "$@" >/dev/null 2>&1 || rc=$?
  show=$("$orca" terminal show "$@" --json 2>/dev/null) || true
  if printf '%s' "$show" | terminal_show_live "$h"; then
    close_terminal_err="terminal still open after close: $h"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then return 0; fi
  # The command failed. Show can still prove the session is gone.
  printf '%s' "$show" | jq -e --arg h "$h" '
    def term:
      if (.result.terminal | type) == "object" then .result.terminal
      elif (.result | type) == "object" and ((.result.handle | type) == "string") then .result
      else {} end;
    .ok == true and (term | .handle == $h and (.connected == false or .writable == false or .orphaned == true or .state == "closed" or .status == "closed"))
  ' >/dev/null 2>&1
}
# Prints the next page cursor, or nothing on the last page. Fails when a page cannot prove it is the last one.
# Current Orca has top level nextCursor, absent on the last page; older Orca has page.hasMore; 1.4.246 has neither.
next_page_cursor() {
  jq -r 'def cursor: if type == "string" and length > 0 then . else error("bad cursor") end;
    .result | if has("page") then
      if .page.hasMore == true then .page.nextCursor | cursor
      elif .page.hasMore == false then ""
      else error("bad page") end
    elif .nextCursor != null then .nextCursor | cursor
    elif (.workers | length) < 100 then ""
    else error("full page without a cursor") end' "$1" 2>/dev/null
}
read_dispatches() {
  local eargs=() wargs run run_cursor='' cursor
  [ -z "$1" ] || eargs=(--environment "$1")
  : > "$tmp/h-runs"
  : > "$tmp/h-cursors"
  while :; do
    wargs=(); [ -z "$run_cursor" ] || wargs=(--cursor "$run_cursor")
    if ! "$orca" orchestration run-list ${eargs[@]+"${eargs[@]}"} ${wargs[@]+"${wargs[@]}"} --full --json > "$tmp/h-page" 2>/dev/null \
      || ! jq -e '.ok != false and (.result.runs | type == "array") and (.result.truncated != true)' "$tmp/h-page" >/dev/null 2>&1 \
      || ! run_cursor=$(next_page_cursor "$tmp/h-page") || grep -Fxq -- "$run_cursor" "$tmp/h-cursors"; then
      echo "Warning: Run list incomplete on ${1:-local}; closing no terminals." >&2; return 1
    fi
    jq -r '.result.runs[].id' "$tmp/h-page" >> "$tmp/h-runs"
    jq -r '.result.runs[].coordinator_handle // empty' "$tmp/h-page" >> "$tmp/h-coordinators"
    [ -n "$run_cursor" ] || break
    printf '%s\n' "$run_cursor" >> "$tmp/h-cursors"
  done
  while IFS= read -r run <&3; do
    cursor=''
    : > "$tmp/h-cursors"
    while :; do
      wargs=(--run "$run" --limit 100); [ -z "$cursor" ] || wargs+=(--cursor "$cursor")
      if ! "$orca" orchestration worker-list ${eargs[@]+"${eargs[@]}"} "${wargs[@]}" --json > "$tmp/h-page" 2>/dev/null \
        || ! jq -e '.ok != false and (.result.workers | type == "array") and (.result.truncated != true)' "$tmp/h-page" >/dev/null 2>&1; then
        echo 'Warning: coordinator dispatch discovery failed; closing no terminals.' >&2; fail_item 'terminals' 'dispatch discovery failed; none closed'; return 1
      fi
      cat "$tmp/h-page" >> "$tmp/h-workers"
      jq -c --arg env "$1" '.result.workers[] | {env: $env, row: .}' "$tmp/h-page" >> "$tmp/h-release-rows" 2>/dev/null || true
      if ! cursor=$(next_page_cursor "$tmp/h-page") || grep -Fxq -- "$cursor" "$tmp/h-cursors"; then
        echo 'Warning: coordinator dispatch pagination incomplete; closing no terminals.' >&2; return 1
      fi
      [ -n "$cursor" ] || break
      printf '%s\n' "$cursor" >> "$tmp/h-cursors"
    done
  done 3< "$tmp/h-runs"
}
terminal_dispatches() {
  local env_id
  : > "$tmp/h-workers"
  : > "$tmp/h-coordinators"
  : > "$tmp/h-release-rows"
  if ! "$orca" environment list --json > "$tmp/envs" 2>/dev/null || ! jq -e '.ok != false and (.result.environments | type == "array") and (.result.truncated != true)' "$tmp/envs" >/dev/null 2>&1; then
    echo 'Warning: Orca environment list unavailable; closing no terminals.' >&2; return 1
  fi
  read_dispatches '' || return 1
  while IFS= read -r env_id <&3; do
    [ -z "$env_id" ] || read_dispatches "$env_id" || return 1
  done 3< <(jq -r '.result.environments[] | .id // .name // empty' "$tmp/envs")
}
close_finished_terminals() {
  local env=$1 label=${1:-local} late=${2:-0} eargs=() handle reason action
  [ -z "$env" ] || eargs=(--environment "$env")
  # A remote terminal reports its own host's path. A removed worktree is matched to the paths this environment reports
  # for the same repo and branch, never to the coordinator's local path. A path counts as gone only when a fresh
  # listing from the same environment no longer reports it: a checkout that still exists on the branch keeps its shells.
  # An unreadable, empty or truncated listing leaves nothing gone.
  : > "$tmp/h-gone"
  if [ -n "$env" ]; then
    if ! "$orca" worktree list --environment "$env" --json > "$tmp/h-env-worktrees" 2>/dev/null \
      || ! jq -e '.ok != false and (.result.worktrees | type == "array") and (.result.worktrees | length) > 0 and (.result.truncated != true)' "$tmp/h-env-worktrees" >/dev/null 2>&1; then
      echo "Warning: worktree list unavailable on $label; no removed worktree matched there." >&2
    else
      jq -r --rawfile gone "$tmp/removed-paths" --arg env "$env" --slurpfile fresh "$tmp/h-env-worktrees" '
        def br: (.branch // "") | sub("^refs/heads/"; "");
        def path: .path // .workspacePath // "";
        ($gone | split("\n")) as $g
        | [$fresh[0].result.worktrees[] | path] as $live
        | [.result.worktrees[]? | select((.hostId // "local") == "local" and (path as $p | $g | index($p)) != null)] as $loc
        | .result.worktrees[]? | select((.hostId // "local") == $env) | . as $r
        | select(path != "" and ((path as $p | $live | index($p)) == null)
            and any($loc[]; .repoId == $r.repoId and (br | length) > 0 and br == ($r | br))) | path' "$tmp/orca-worktrees" > "$tmp/h-gone" 2>/dev/null || : > "$tmp/h-gone"
    fi
  else
    cp "$tmp/removed-paths" "$tmp/h-gone"
  fi
  if ! "$orca" terminal list ${eargs[@]+"${eargs[@]}"} --json > "$tmp/h-terminals" 2>/dev/null \
    || ! jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$tmp/h-terminals" >/dev/null 2>&1; then
    echo "Warning: terminal inventory incomplete on $label; closing nothing there." >&2; fail_item "terminals on $label" 'inventory incomplete; none closed'; return 0
  fi
  # List preview can lag a full-screen agent. Only idle terminals are worth a show; a fresh one is still working.
  : > "$tmp/h-idle-handles"
  jq -r --arg idle_ms "${WRAP_UP_IDLE_SHELL_MS:-3600000}" '
    .result.terminals[]?
    | select(.connected != false and .writable != false)
    | select((.lastOutputAt | type) == "number" and .lastOutputAt <= (now * 1000 - ($idle_ms | tonumber)))
    | .handle' "$tmp/h-terminals" > "$tmp/h-idle-handles" 2>/dev/null || :
  : > "$tmp/h-screens"
  while IFS= read -r handle; do
    [ -n "$handle" ] || continue
    show=$("$orca" terminal show ${eargs[@]+"${eargs[@]}"} --terminal "$handle" --json 2>/dev/null) || continue
    printf '%s' "$show" | jq -c --arg h "$handle" '
      def term:
        if (.result.terminal | type) == "object" then .result.terminal
        elif (.result | type) == "object" and ((.result.handle | type) == "string") then .result
        else empty end;
      term | select(.handle == $h) | {handle, preview, liveness, agentIdentity, lastOutputAt}
        + (if has("agentWait") then {agentWait} else {} end)
    ' >> "$tmp/h-screens" 2>/dev/null || true
  done < "$tmp/h-idle-handles"
  if [ -s "$tmp/h-screens" ] && jq -s '.' "$tmp/h-screens" > "$tmp/h-screens.json"; then
    if jq --slurpfile screens "$tmp/h-screens.json" '
      ($screens[0] | map(select((.handle | type) == "string" and .handle != "")) | map({(.handle): .}) | add // {}) as $by
      | .result.terminals |= map(
          if $by[.handle] == null then .
          else . as $t | $by[.handle] as $s
            | .preview = (if ($s.preview | type) == "string" and $s.preview != "" then $s.preview else $t.preview end)
            | .liveness = (if ($s.liveness | type) == "string" then $s.liveness else $t.liveness end)
            | .agentIdentity = (if ($s | has("agentIdentity")) then $s.agentIdentity else $t.agentIdentity end)
            | .lastOutputAt = (if ($s.lastOutputAt | type) == "number" then $s.lastOutputAt else $t.lastOutputAt end)
            | .agentWait = (if ($s | has("agentWait")) then $s.agentWait else $t.agentWait end)
          end)
    ' "$tmp/h-terminals" > "$tmp/h-terminals-rich"; then
      mv "$tmp/h-terminals-rich" "$tmp/h-terminals"
    fi
  fi
  jq -r -s --slurpfile terms "$tmp/h-terminals" --rawfile coordinators "$tmp/h-coordinators" --arg own "${ORCA_TERMINAL_HANDLE:-}" --arg scheduled "${WRAP_UP_SCHEDULED_CHILD:-}" --arg idle_ms "${WRAP_UP_IDLE_SHELL_MS:-3600000}" --arg main "$main_path" --arg local "${env:-}" --rawfile gone "$tmp/h-gone" '
    def live_of:
      if (.liveness | type) == "string" then .liveness
      elif (.projection.liveness | type) == "string" then .projection.liveness
      elif (.projection.liveness | type) == "object" then (.projection.liveness.verdict // .projection.liveness.state // "")
      else "" end;
    def outcome_of: (.outcome // .projection.outcome // "");
    def settled:
      ((.dispatchStatus // .state // "") as $s | ["succeeded","completed","failed","cancelled","released","stopped","done"] | index($s))
      or ((outcome_of) as $o | ["worker_done","succeeded","completed","failed","cancelled","stopped","done"] | index($o))
      or (.stage == "released" or .stage == "process_stopped")
      or ((.terminalState // "") as $t | ["released","release_unknown","gone","missing","closed"] | index($t))
      or (live_of == "exited" or live_of == "sleep");
    def at_prompt:
      def vis: gsub("^[[:space:]]+|[[:space:]]+$"; "");
      ((.preview // "") | split("\n") | map(vis) | map(select(length > 0)) | last // "") as $last
      | (
          ($last | test("^(❯|⏵|\\$|%)"))
          or ($last | test("bypass permissions|shift\\+tab to cycle"))
        );
    def idle_prompt:
      (.lastOutputAt | type) == "number"
      and .lastOutputAt <= (now * 1000 - ($idle_ms | tonumber))
      and at_prompt;
    def owner_session: .agentIdentity != null and .connected != false and .writable != false;
    def waiting_on_human:
      (.agentWait == true or (.agentWait | type) == "object")
      or (
        [.preview // "" | split("\n")[] | select(length > 0)] as $lines
        | any($lines[]; test("\\((question|escalation)\\)[[:space:]]*─"))
        or any($lines[]; test("^Question .+ sent\\.$"))
        or any($lines[]; test("^Question .+ is still pending"))
        or any($lines[]; test("^ask timeout after .+ is still pending"))
      );
    def worker_handle: .agentTerminalHandle // (.terminal | strings) // "";
    def screen_of($h):
      if $h == "" then null
      else ([$terms[0].result.terminals[] | select(.handle == $h)][0] // null)
      end;
    def blocking:
      (settled | not) and (
        worker_handle as $wh
        | if (screen_of($wh) == null) then true
          else (screen_of($wh) | (live_of == "sleep" or live_of == "exited") | not)
          end
      );
    def clean:
      if type != "string" or . == "" then ""
      elif . == "/" then "/"
      else sub("/+$"; "") end;
    def path: ((.workspace // .projection.workspace.id // .worktreeId // "") | split("::")[1] // "" | clean);
    def under($root): . == $root or startswith($root + "/");
    [.[].result.workers[]] as $w
    | $terms[0].result.terminals[] | .handle as $h | (.worktreePath // "" | clean) as $p
    | ([$w[] | select((.agentTerminalHandle // (.terminal | strings)) == $h)]) as $mine
    | ([$w[] | select($p != "" and path == $p)]) as $onpath
    | ([$w[] | select(blocking) | path | select(. != "")]) as $live_paths
    | ([ (.worktreeId // "" | if type == "string" then (split("::")[1] // "" | clean) else "" end), (.cwd // "" | clean) ]
        | map(select(. != ""))) as $places
    | (any($live_paths[]; . as $root | ($p != "" and ($p | under($root))))
        or any($places[]; . as $place | any($live_paths[]; . as $root | $place | under($root)))) as $in_live
    | (.connected == false or .writable == false) as $exited
    | if $h == $own then [$h, "own terminal", "keep"]
      elif $coordinators | split("\n") | index($h) then [$h, "coordinator", "keep"]
      elif (($p | split("/") | last) // "" | startswith("lead-")) then [$h, "lead worktree", "keep"]
      elif any(($mine + $onpath)[]; blocking) or $in_live then [$h, "live dispatch", "keep"]
      elif (live_of == "sleep") or (live_of == "exited") then [$h, "sleep", "close"]
      elif owner_session and ($mine | length) == 0 and ($onpath | length) == 0 then [$h, "owner session", "keep"]
      elif waiting_on_human then [$h, "waiting on a human", "keep"]
      elif idle_prompt then [$h, "idle at prompt", "close"]
      elif $scheduled != "" and ($in_live | not) and $local == "" and $p != "" and $p != $main and ($mine | length) == 0 and .agentIdentity == null
        and (((.title // "") | test("worker-pane")) | not)
        and (.lastOutputAt | type) == "number" and .lastOutputAt <= (now * 1000 - ($idle_ms | tonumber))
        then [$h, "no dispatch, no agent, idle", "close"]
      elif ($exited | not) and (.lastOutputAt > now * 1000 - 600000 or (.agentIdentity != null and .lastOutputAt == null)) then [$h, "recent output", "keep"]
      elif ($mine | length) > 0 then [$h, "settled dispatch", "close"]
      elif $exited then [$h, "exited", "close"]
      elif ($onpath | length) > 0 and ((.title // "") | test("worker-pane")) then [$h, "settled worker pane", "close"]
      elif ($onpath | length) > 0 then [$h, "settled dispatch on this path", "close"]
      elif $local != "" and $p != "" and .agentIdentity == null and (.branch // "") != "refs/heads/main" and (.branch // "") != "refs/heads/master" and ($gone | split("\n") | index($p)) then [$h, "worktree gone in this run", "close"]
      elif $local != "" and ($p == "" or .agentIdentity != null or (.branch // "") == "refs/heads/main" or (.branch // "") == "refs/heads/master") then [$h, "unknown owner, still running", "keep"]
      elif $local != "" then [$h, "unknown owner, still running", "keep"]
      elif $p == "" then [$h, "not in a worktree", "keep"]
      elif $p == $main then [$h, "main checkout", "keep"]
      elif .agentIdentity != null then [$h, "running agent", "keep"]
      elif $scheduled != "" and ((.lastOutputAt | type) != "number") then [$h, "no dispatch, no agent, output age unknown", "keep"]
      elif $scheduled != "" and .lastOutputAt > (now * 1000 - ($idle_ms | tonumber)) then [$h, "no dispatch, no agent, output within 60 minutes", "keep"]
      elif $scheduled != "" then [$h, "no dispatch, no agent, idle", "close"]
      else [$h, "no dispatch, no agent", "close"] end
    | @tsv' "$tmp/h-workers" > "$tmp/h-plan"
  while IFS=$'\t' read -r handle reason action; do
    if [ "$late" = 1 ] && [ "$reason" != 'worktree gone in this run' ]; then continue; fi
    if [ "$action" = keep ]; then terminal_kept "$handle" "$label" "$reason"; continue; fi
    printf 'Close terminal %s (%s, %s)\n' "$handle" "$label" "$reason"
    if [ "$apply" -eq 1 ]; then
      if ! close_terminal ${eargs[@]+"${eargs[@]}"} --terminal "$handle"; then
        echo "Warning: closing $handle on $label failed." >&2; fail_item "terminal $handle ($label)" "$close_terminal_err"; continue
      fi
    fi
    [ -n "$env" ] || printf '%s\n' "$handle" >> "$tmp/closing"
    # Kept in the first pass, closed in the late one: count it once, as closed.
    if grep -Fxq -- "$label $handle" "$tmp/kept-terminals"; then term_kept=$((term_kept-1)); fi
    term_closed=$((term_closed+1))
  done < "$tmp/h-plan"
}
# Release finished workers on this Orca and every environment: state succeeded, stopped or failed, or liveness exited or sleep,
# and not yet released. A ready or in_progress worker that is live is never touched, nor the caller's or a coordinator's terminal.
# Issue 855: a row with no terminal and no terminal state was already released (the concise list drops both), and a retained
# one is Orca's final answer; asking again every round spent the whole time limit, so every later step was skipped. Releases
# also stop once half the time limit is used, so the terminal and worktree steps always get their turn. An ok:true receipt
# (released, retained, already_released) counts as released whatever the exit code.
# Issue 877: a worker that has ended (worker_done sent, stopped, exited, or a gone terminal) does not keep its
# terminal as a live dispatch when release has not finished. Terminal close runs first, so a failed or capped
# release cannot skip it. terminalState release_unknown is not asked again; the summary counts it as no action.
released_count=0
no_action_count=0
release_finished_workers() {
  local env id why label receipt release_started=$SECONDS
  while IFS=$'\t' read -r env id why; do
    [ -n "$id" ] || continue
    [ "$env" != - ] || env=''
    label=${env:-local}
    if [ "$why" = no-action ]; then no_action_count=$((no_action_count+1)); continue; fi
    if [ "$apply" -eq 1 ] && [ -n "${WRAP_UP_RELEASE_BUDGET:-}" ] && [ $((SECONDS-release_started)) -ge "$WRAP_UP_RELEASE_BUDGET" ]; then
      echo 'Warning: releases used their time limit; the rest wait for the next run.' >&2
      break
    fi
    if [ "$apply" -eq 1 ] && [ $((deadline-SECONDS)) -lt $((total_timeout/2)) ]; then
      echo 'Warning: releases used half the time limit; the rest wait for the next run.' >&2
      fail_item 'releases' 'half the time limit used; the rest next run'; break
    fi
    printf 'Release worker %s (%s, %s)\n' "$id" "$label" "$why"
    if [ "$apply" -eq 1 ]; then
      if ! receipt=$("$orca" orchestration worker-release --dispatch "$id" ${env:+--environment "$env"} --json 2>/dev/null) \
        && ! jq -e '.ok == true' <<< "$receipt" >/dev/null 2>&1; then
        echo "Warning: releasing $id on $label failed." >&2; fail_item "release $id ($label)" 'worker-release failed'; continue
      fi
    fi
    released_count=$((released_count+1))
  done < <(jq -r -s --rawfile coordinators "$tmp/h-coordinators" --arg own "${ORCA_TERMINAL_HANDLE:-}" '
    def state: (.state // .dispatchStatus // "");
    def handle: (.agentTerminalHandle // (.terminal | strings) // "");
    [.[] | .env as $env | .row | state as $st | handle as $h | (.liveness // "") as $live
      | (.outcome // .projection.outcome // "") as $out
      | select((.dispatchId // "") != "")
      | select(.terminalState != "released" and .terminalState != "retained" and .stage != "released")
      | select($h != "" or .terminalState != null)
      | (if (["succeeded","stopped","failed"] | index($st)) != null then "state " + $st
         elif (["exited","sleep"] | index($live)) != null then "liveness " + $live
         elif (["worker_done","completed","done"] | index($out)) != null then "outcome " + $out
         else empty end) as $why
      | select(((["ready","in_progress"] | index($st)) != null and $live == "live" and ($out == "" or $out == "in_progress")) | not)
      | select($h == "" or ($h != $own and (($coordinators | split("\n")) | index($h) | not)))
      | (if .terminalState == "release_unknown" then "no-action" else $why end) as $act
      | [(if $env == "" then "-" else $env end), .dispatchId, $act]]
    | unique_by([.[0], .[1]])[] | @tsv' "$tmp/h-release-rows")
}
if command -v "$orca_bin" >/dev/null 2>&1 && terminal_dispatches; then
  terminals_read=1
  close_finished_terminals ''
  while IFS= read -r env_id; do
    [ -z "$env_id" ] || close_finished_terminals "$env_id"
  done < <(jq -r '.result.environments[] | .id // .name // empty' "$tmp/envs")
  [ -z "${WRAP_UP_SCHEDULED_CHILD:-}" ] || printf 'step terminals seconds=%s\n' "$SECONDS"
fi
if command -v "$orca_bin" >/dev/null 2>&1; then
  if "$orca" terminal list --json > "$tmp/terminals" && jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$tmp/terminals" >/dev/null; then
    # Unknown ownership is retained too: a live terminal can belong to another Run.
    : > "$tmp/worker-pages"
    : > "$tmp/w-cursors"
    cursor=''
    while :; do
      args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
      if ! "$orca" orchestration worker-list ${args[@]+"${args[@]}"} --json > "$tmp/workers"; then
        echo 'Warning: dispatch discovery failed; retaining all worktrees.' >&2; fail_item 'worktrees' 'dispatch discovery failed; all kept'
        echo '*' >> "$tmp/active"; break
      fi
      if ! jq -e '.ok != false and (.result.workers | type == "array") and (.result.truncated != true)' "$tmp/workers" >/dev/null; then
        echo 'Warning: unexpected worker-list page shape; retaining all worktrees.' >&2; fail_item 'worktrees' 'worker-list page unreadable; all kept'
        echo '*' >> "$tmp/active"; break
      fi
      cat "$tmp/workers" >> "$tmp/worker-pages"
      while IFS=$'\t' read -r dispatch status owned row_path; do
        [ -n "$dispatch" ] || continue
        if "$orca" orchestration worker-show --dispatch "$dispatch" --json > "$tmp/show"; then
          # Any dispatch still live on this host may hold a temp browser; its output names no run, so do not guess from words.
          [ -z "$(jq -c 'select(.result | ((.state // .dispatch.status) as $s | ["succeeded","completed","failed","cancelled","released","stopped"] | index($s)) or .stage == "released" or .terminalState == "released" or .liveness == "exited" | not)' "$tmp/show")" ] || dispatch_run=1
          jq -r 'select(.result | ((.state // .dispatch.status) as $s | ["succeeded","completed","failed","cancelled","released","stopped"] | index($s)) or .stage == "released" or .terminalState == "released" or .liveness == "exited" | not) | .result | (.terminal | objects | (.cwd // .worktreePath // empty)), ((.workspace // .worker.worktreeId // .projection.workspace.id // "") | split("::")[1] // empty)' "$tmp/show" >> "$tmp/active"
        elif [ "$status" = pending ]; then
          # Never started: no worker and no worktree, so worker-show has nothing to return.
          echo "Warning: worker-show failed for pending dispatch $dispatch; skipped." >&2
        elif [ "$status" = start_unknown ] && [ "$owned" = free ] && jq -e '.error.code == "dispatch_not_found"' "$tmp/show" >/dev/null 2>&1; then
          # Never settled: Orca keeps no terminal, workspace or time for it, and cannot show it, so it owns no browser and no worktree.
          echo "Warning: worker-show failed for never-settled dispatch $dispatch; skipped." >&2
        elif jq -e '.error.code == "remote_runtime_unavailable" or (.error.message | startswith("Unknown environment") or startswith("Remote Dispatch"))' "$tmp/show" >/dev/null 2>&1; then
          # Ran on a host this one no longer pairs with, or one that is offline now (issue 855): its worktree and browser live
          # there, that host's wrap-up owns them. A path its row names may still be here, so that one stays.
          [ -z "$row_path" ] || echo "$row_path" >> "$tmp/active"
          echo "Warning: worker-show failed for dispatch $dispatch on an unpaired host; skipped." >&2
        else
          echo "Warning: worker-show failed for $dispatch; retaining all worktrees." >&2; fail_item "dispatch $dispatch" 'worker-show failed; all worktrees kept'
          echo '*' >> "$tmp/active"
        fi
      done < <(jq -r '.result.workers[]? | select(((.dispatchStatus // .state) as $s | ["succeeded","completed","failed","cancelled","released","stopped"] | index($s)) or .stage == "released" or .terminalState == "released" or .liveness == "exited" | not) | . as $row | ($row | '"$(jq_worker_row_path_expr)"') as $p | [$row.dispatchId // empty, $row.dispatchStatus // $row.state // "", (if ($row.terminal // "") != "" or ($p | length > 0) then "owned" else "free" end), $p] | @tsv' "$tmp/workers")
      if ! cursor=$(next_page_cursor "$tmp/workers") || grep -Fxq -- "$cursor" "$tmp/w-cursors"; then
        echo 'Warning: worker-list paging incomplete; retaining all worktrees.' >&2; fail_item 'worktrees' 'worker-list paging incomplete; all kept'
        echo '*' >> "$tmp/active"; break
      fi
      [ -n "$cursor" ] || break
      printf '%s\n' "$cursor" >> "$tmp/w-cursors"
    done
    inventory_read=1
    # Discard terminals positively owned only by settled dispatches. Unknown owners stay safe.
    jq -s '[.[].result.workers[] | .agentTerminalHandle //= (.terminal | strings)] | group_by(.agentTerminalHandle) | map(select(all(.[]; ((.dispatchStatus // .state) as $s | ["succeeded","completed","failed","cancelled","released","stopped"] | index($s)) or .stage == "released" or .terminalState == "released" or .liveness == "exited")) | .[0].agentTerminalHandle) | map(select(. != null))' "$tmp/worker-pages" > "$tmp/ended-handles"
    # A preview leaves the terminals it plans to close open; apply has closed them, so count them as gone in both.
    jq -R . "$tmp/closing" | jq -s . > "$tmp/closing-handles"
    jq -r --slurpfile ended "$tmp/ended-handles" --slurpfile closing "$tmp/closing-handles" '.result.terminals[] | select(.handle as $h | ($ended[0] | index($h) | not) and ($closing[0] | index($h) | not)) | .cwd // .worktreePath // empty' "$tmp/terminals" >> "$tmp/active"
  else
    echo 'Warning: Orca terminal inventory incomplete; retaining all worktrees.' >&2; fail_item 'worktrees' 'terminal inventory incomplete; all kept'
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
if bounded gh repo view --json defaultBranchRef > "$tmp/default" 2>/dev/null; then
  default_branch=$(jq -er '.defaultBranchRef.name | select(type == "string" and length > 0)' "$tmp/default" 2>/dev/null) || default_branch=''
fi
if [ -z "$default_branch" ]; then
  default_branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || default_branch=''
  default_branch=${default_branch#refs/remotes/origin/}
fi
[ -n "$default_branch" ] || protection_ok=0
pages_branch=''
if bounded gh api 'repos/{owner}/{repo}/pages' > "$tmp/pages" 2> "$tmp/pages-err"; then
  if jq -e 'type == "object" and (.source == null or (.source.branch | type == "string" and length > 0))' "$tmp/pages" >/dev/null 2>&1; then
    pages_branch=$(jq -r '.source.branch // empty' "$tmp/pages")
  else protection_ok=0
  fi
elif ! grep -Eq 'HTTP 404|HTTP/[^ ]+ 404' "$tmp/pages-err"; then
  protection_ok=0
fi
if bounded gh api --paginate 'repos/{owner}/{repo}/branches?protected=true&per_page=100' > "$tmp/protection-pages" 2>/dev/null \
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
  if git merge-base --is-ancestor "$1" origin/main; then
    # git branch -d also wants the branch inside its own upstream, so the plan asks the same.
    if [ "${1#refs/heads/}" = "$1" ] || ! git show-ref --verify --quiet "refs/remotes/origin/${1#refs/heads/}" \
      || git merge-base --is-ancestor "$1" "refs/remotes/origin/${1#refs/heads/}"; then reason=ancestor; return 0; fi
    reason='ancestor of main but not of its own upstream'
  fi
  if [ -n "$2" ] && grep -Fxq -- "$2" "$tmp/closed"; then reason='closed PR'; return 0; fi
  # Squash or rebase merges: every commit has a patch-equivalent on origin/main.
  if [ "$pr_ok" -eq 1 ] && [ -n "$2" ] && cherry=$(git cherry origin/main "$1") && ! grep -q '^+' <<< "$cherry"; then reason='patch-merged'; return 0; fi
  return 1
}
# Last copy rule: a remote branch whose commits are not in origin/main, have no patch equivalent there and sit on no other
# ref (a local branch of the same name goes with it) is the only copy of that work, so it stays. An unreadable answer keeps it too.
last_copy_kept=0
last_copy() { # <sha> <branch>
  local others cherry
  git merge-base --is-ancestor "$1" origin/main 2>/dev/null && return 1
  cherry=$(git cherry origin/main "$1" 2>/dev/null) || return 0
  if ! grep -q '^+' <<< "$cherry"; then return 1; fi
  others=$(git for-each-ref --contains "$1" --format='%(refname)' refs/heads refs/remotes/origin 2>/dev/null) || return 0
  [ -z "$(grep -vFx -e "refs/remotes/origin/$2" -e "refs/heads/$2" <<< "$others")" ]
}
# True when every status line is an untracked image (screenshot dirt).
# A worktree counts as clean when every changed path is an untracked image or the hook state file continual-learning.json
# (modified or untracked). Any other change keeps it dirty.
only_ignorable_changes() {
  ! grep -qviE '^\?\? .*\.(png|jpe?g|gif|webp)"?$|^\?\? (.*/)?\.remote-heavy-lock-sha$|^.. \.cursor/hooks/state/continual-learning\.json$' "$1"
}
# A worktree HEAD is safe to drop when it is already in origin/main or named by a remote tracking branch.
head_on_origin() {
  git merge-base --is-ancestor "$1" origin/main 2>/dev/null && return 0
  git branch -r --contains "$1" 2>/dev/null | grep -q .
}
archive_worktree_changes() { # <worktree-path> <archive-dir>
  local wt=$1 dest=$2 untracked
  [ ! -e "$dest" ] || dest="$dest-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$dest" || return 1
  git -C "$wt" diff HEAD > "$dest/changes.patch" 2>/dev/null || return 1
  untracked=$(git -C "$wt" ls-files -o --exclude-standard 2>/dev/null) || return 1
  if [ -n "$untracked" ]; then
    git -C "$wt" ls-files -o --exclude-standard -z 2>/dev/null | tar -czf "$dest/scratch.tgz" -C "$wt" --null -T - 2>/dev/null || return 1
  fi
  return 0
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
# Only known proc lifecycle/access errors may be ignored. Inspect every diagnostic
# so a mixed or unrecognized error cannot turn a partial scan into idle proof.
proc_error_skippable() {
  local line seen=0
  while IFS= read -r line; do
    case "$line" in
      *': No such file or directory') seen=1 ;;
      *': Permission denied') [ "$1" = own-uid ] || return 1; seen=1 ;;
      *) return 1 ;;
    esac
  done < "$tmp/holder-err"
  [ "$seen" -eq 1 ]
}
proc_busy() {
  local pid link dest target pids current_uid owner_uid readlink_flags=(--)
  # GNU/BusyBox readlink otherwise hides errno diagnostics. BSD (test hosts)
  # lacks -v; silent failures there remain unknown and fail closed.
  if readlink --help >/dev/null 2>&1; then readlink_flags=(-v --); fi
  busy='proc inspection failed'
  current_uid=$(id -u 2> "$tmp/holder-err") || return 0
  case "$current_uid" in ''|*[!0-9]*) return 0 ;; esac
  [ ! -s "$tmp/holder-err" ] || return 0
  [ -d "$proc_root" ] && [ -r "$proc_root" ] && [ -x "$proc_root" ] || return 0
  target=$(readlink -f -- "$1" 2> "$tmp/holder-err") || return 0
  [ -n "$target" ] && [ ! -s "$tmp/holder-err" ] || return 0
  # Use a shell glob: a find subprocess would list itself and then disappear,
  # making every scan fail closed on that vanished PID.
  pids=("$proc_root"/[0-9]*)
  # An empty or hidden process inventory cannot prove idleness.
  [ "${pids[0]}" != "$proc_root/[0-9]*" ] || return 0
  for pid in "${pids[@]}"; do
    case "${pid##*/}" in *[!0-9]*) return 0 ;; esac
    # Other users' proc entries normally deny access; inspect only our uid.
    # GNU and BSD stat use different flags (fixtures run on either platform).
    if ! owner_uid=$(LC_ALL=C stat -c %u -- "$pid" 2> "$tmp/holder-err"); then
      proc_error_skippable vanished && continue
      if ! owner_uid=$(LC_ALL=C stat -f %u "$pid" 2> "$tmp/holder-err"); then
        proc_error_skippable vanished && continue
        return 0
      fi
    fi
    case "$owner_uid" in ''|*[!0-9]*) return 0 ;; esac
    [ ! -s "$tmp/holder-err" ] || return 0
    [ "$owner_uid" = "$current_uid" ] || continue
    printf '%s\0' "$pid/cwd" "$pid/root" > "$tmp/proc-links"
    # Own-uid non-dumpable system processes deny these reads; vanished pids
    # are normal during a scan. Every other inspection failure retains items.
    if ! LC_ALL=C find "$pid/fd" -mindepth 1 -maxdepth 1 -print0 >> "$tmp/proc-links" 2> "$tmp/holder-err" \
      || [ -s "$tmp/holder-err" ]; then
      proc_error_skippable own-uid && continue
      return 0
    fi
    while IFS= read -r -d '' link; do
      if ! dest=$(LC_ALL=C readlink "${readlink_flags[@]}" "$link" 2> "$tmp/holder-err") \
        || [ -s "$tmp/holder-err" ]; then
        proc_error_skippable own-uid && continue 2
        return 0
      fi
      [ -n "$dest" ] || return 0
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
# and ps must answer cleanly; unclassified inspection errors keep the item.
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
  inventory_failed=1; fail_item 'worktree inventory' 'could not list worktrees; nothing more deleted in this repo'; return 1
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
  wt=$(checkout_of "$3") || { inventory_failed=1; fail_item 'worktree inventory' 'could not read; item kept'; guard_keep "$1" "$2" 'worktree inventory unavailable'; return 2; }
  [ -n "$wt" ] || return 0
  echo "Warning: $2 is checked out in a worktree now; kept." >&2
  if in_use "$wt"; then guard_keep "$1" "$2" "checked out in $wt, $busy"; else guard_keep "$1" "$2" "checked out in $wt"; fi
  return 1
}
worktree_orca_pin_unknown() { [ "${orca_pin_state:-}" = unknown ]; }
worktree_pinned_in_orca() {
  [ "${orca_pin_state:-}" = ok ] || return 1
  local p r
  p=$(real "$1")
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(real "$r" 2>/dev/null || printf '%s' "$r")" = "$p" ] && return 0
  done < "$tmp/orca-pinned"
  return 1
}
# Orca's board decides what may go: a worktree whose workspaceStatus is set and is not "completed" stays. One Orca does not
# list (no status) falls through to the checks below.
worktree_board_open() {
  [ "${orca_pin_state:-}" = ok ] || return 1
  local p r
  p=$(real "$1")
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(real "$r" 2>/dev/null || printf '%s' "$r")" = "$p" ] && return 0
  done < "$tmp/orca-board-open"
  return 1
}
guarded_orca_worktree_rm() { # <counter> <label> <path>
  local counter=$1 label=$2 path=$3 rc=0 real_path
  real_path=$(real "$path")
  orca_call worktree rm --worktree "path:$real_path" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Warning: could not deregister Orca worktree for $label." >&2
    fail_item "$label" "orca worktree rm failed (exit $rc)"
    guard_keep "$counter" "$label" 'orca worktree rm failed'
    return 1
  fi
  orca_removed=$((${orca_removed:-0}+1))
  return 0
}
guarded_worktree_remove() { # <counter> <label> <path> [--force]
  local orca_rm orca_ok=0 remove_rc=0
  guard_paths "$1" "$2" "$3" || return
  if [ "$inventory_read" -eq 1 ] && command -v "$orca_bin" >/dev/null 2>&1; then
    orca_rm=(worktree rm --worktree "path:$3")
    [ "${4:-}" = --force ] && orca_rm+=(--force)
    if bounded "$orca_bin" "${orca_rm[@]}" >/dev/null 2>&1; then
      orca_ok=1
      if [ ! -d "$3" ]; then
        git worktree prune
        if ! worktree_present_after_remove "$3"; then
          orca_removed=$((${orca_removed:-0}+1))
          return 0
        fi
      fi
    fi
  fi
  # A non-zero exit after the worktree is already gone is a finished remove, not a failure.
  git worktree remove ${4:+"$4"} -- "$3" || remove_rc=$?
  git worktree prune
  if worktree_present_after_remove "$3"; then
    if [ "$remove_rc" -ne 0 ]; then
      echo "Warning: could not remove $2; kept." >&2; fail_item "$2" 'remove failed'; guard_keep "$1" "$2" 'remove failed'
    else
      echo "Warning: $2 still present after remove; kept." >&2
      fail_item "$2" "worktree still present after remove: $3"
      guard_keep "$1" "$2" "worktree still present after remove: $3"
    fi
    return 1
  fi
  [ "$orca_ok" -eq 0 ] || orca_removed=$((${orca_removed:-0}+1))
  return 0
}
# A local branch with a commit on no origin ref holds work that exists only on this host: no delete path removes it,
# whatever made it eligible, and an unreadable count keeps it too.
unpushed_why=''
local_unpushed() { # name; succeeds when the local branch has a commit on no origin ref or the count is unreadable; sets unpushed_why
  local n
  git show-ref --verify --quiet "refs/heads/$1" || return 1
  unpushed_why='unpushed commits: count unreadable'
  n=$(git rev-list --count "refs/heads/$1" --not --remotes=origin 2>/dev/null) || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 0 ] || return 1
  unpushed_why="unpushed commits: $n"
}
guarded_local_branch_delete() { # <counter> <label> <branch> [eligibility reason]
  local del_ok=0
  fresh_inventory || { guard_keep "$1" "$2" 'worktree inventory unavailable'; return 2; }
  branch_free "$1" "$2" "$3" || return
  if local_unpushed "$3"; then guard_keep "$1" "$2" "$unpushed_why"; return 1; fi
  if [ "${4:-}" = ancestor ]; then
    # -d checks HEAD/upstream, so give it the authoritative merge target.
    git -c "branch.$3.remote=origin" -c "branch.$3.merge=refs/heads/main" branch -d -- "$3" && del_ok=1
  else
    git branch -D -- "$3" && del_ok=1
  fi
  if [ "$del_ok" -ne 1 ]; then
    echo "Warning: could not delete $2; kept." >&2; fail_item "$2" 'delete failed'; guard_keep "$1" "$2" 'delete failed'; return 1
  fi
  if git show-ref --verify --quiet "refs/heads/$3"; then
    echo "Warning: $2 ref still exists after delete; kept." >&2
    fail_item "$2" "branch ref still exists after delete: $3"
    guard_keep "$1" "$2" "branch ref still exists after delete: $3"
    return 1
  fi
  return 0
}
guarded_remote_branch_delete() { # <name...>: sets remote_gone to how many went; kept ones count in kept
  local name status=0 live=() leases=()
  remote_gone=0
  remote_live "$@" || status=1
  [ ${#live[@]} -gt 0 ] || return "$status"
  if bounded git push origin --delete "${live[@]}" "${leases[@]}" --atomic; then remote_gone=${#live[@]}; return "$status"; fi
  # One bad ref fails the whole push; retry one by one, each behind a fresh inventory, so only the failing ones are kept.
  for name in "${live[@]}"; do
    remote_live "$name" || { status=1; continue; }
    if bounded git push origin --delete "$name" "${leases[@]}"; then remote_gone=$((remote_gone+1)); continue; fi
    echo "Warning: could not delete remote $name; kept." >&2
    fail_item "remote $name" 'delete failed'
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
    if ! bounded git ls-remote --heads origin "refs/heads/$name" > "$tmp/remote-now"; then
      fail_item "remote $name" 'live lookup failed'
      guard_keep kept "remote $name" 'live remote lookup failed'; status=1; continue
    fi
    actual=$(awk -v r="refs/heads/$name" '$2 == r { print $1 }' "$tmp/remote-now")
    if [ -z "$actual" ]; then
      guard_keep kept "remote $name" 'vanished from remote'; status=1; continue
    fi
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
      guard_keep kept "remote $name" 'remote SHA changed since fetch'; status=1; continue
    fi
    if last_copy "$actual" "$name"; then
      guard_keep kept "remote $name" 'last copy of unmerged work'; last_copy_kept=$((last_copy_kept+1)); status=1; continue
    fi
    live+=("$name")
    # Keep the check atomic if a writer races the ls-remote response.
    leases+=("--force-with-lease=refs/heads/$name:$expected")
  done
  return "$status"
}
guarded_rm() { # <counter> <label> <rf|dir> <path> [more paths to probe]
  local counter=$1 label=$2 mode=$3 target=$4 rc=0; shift 3
  guard_paths "$counter" "$label" "$@" || return
  if [ "$mode" = dir ]; then
    rmdir -- "$target" || rc=$?
  else
    rm -rf -- "$target" || rc=$?
  fi
  if [ "$rc" -eq 0 ] || { [ ! -e "$target" ] && [ ! -L "$target" ]; }; then return 0; fi
  echo "Warning: could not remove $label; kept." >&2; fail_item "$label" 'remove failed'; guard_keep "$counter" "$label" 'remove failed'; return 1
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
removed=0; orca_removed=0; local_deleted=0; remote_deleted=0; kept=0; stale_deleted=0
orca_pin_state=unavailable
: > "$tmp/orca-pinned"
: > "$tmp/orca-board-open"
if [ "$inventory_read" -eq 1 ] && command -v "$orca_bin" >/dev/null 2>&1; then
  orca_pin_state=unknown
  if orca_call worktree list --json > "$tmp/orca-worktrees" 2>/dev/null \
    && jq -e '.ok != false and ((.result.worktrees // []) | type == "array") and (.result.truncated != true)' "$tmp/orca-worktrees" >/dev/null 2>&1; then
    orca_pin_state=ok
    jq -r '.result.worktrees[]? | select(.pinned == true) | (.path // .workspacePath // empty)' "$tmp/orca-worktrees" > "$tmp/orca-pinned"
    jq -r '.result.worktrees[]? | select((.workspaceStatus // "completed") != "completed") | (.path // .workspacePath // empty)' "$tmp/orca-worktrees" > "$tmp/orca-board-open"
  fi
fi
keep() { printf 'Kept %s (%s)\n' "$1" "$2"; kept=$((kept+1)); }
: > "$tmp/kept-branches"
: > "$tmp/kept-worktrees"
: > "$tmp/stale-ok"
refresh_refs
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
  local why='' force='' dest=''
  reason='on a remote branch'
  if [ -z "$main_checkout" ]; then main_checkout=$path; why='main checkout'
  elif [ -z "$branch" ] && case "${path##*/}" in _*) true ;; *) false ;; esac; then why='script-owned _ worktree'
  elif protected "$branch"; then why=$protected_reason
  elif archive_branch "$branch"; then why='archive branch'
  elif case "${path##*/}" in lead-*) true ;; *) false ;; esac; then why='lead worktree'
  elif [ "$locked" -eq 1 ]; then why='locked'
  elif worktree_orca_pin_unknown; then why='Orca pin lookup failed'
  elif worktree_pinned_in_orca "$path"; then why='pinned in Orca'
  elif worktree_board_open "$path"; then why='Orca board status is not completed'
  elif ! git -C "$path" status --porcelain --untracked-files=all > "$tmp/status"; then why='unreadable'
  elif active_worktree "$path"; then why='active or unknown Orca terminal'
  elif recent_worktree "$path"; then why="changed in the last ${WRAP_UP_RECENT_MIN:-30} minutes"
  elif ! head_on_origin "$head"; then why='commits not on any remote (last copy)'
  elif [ -n "$branch" ] && local_unpushed "$branch"; then why="$unpushed_why"
  elif in_use "$path"; then why=$busy
  elif [ -s "$tmp/status" ] && ! only_ignorable_changes "$tmp/status"; then
    dest=${WRAP_UP_WT_ARCHIVE_ROOT:-$HOME/.claude/state/wt-archive}/$(basename "$repo")_${path##*/}
    printf 'Archive worktree %s to %s\n' "$path" "$dest"
    if [ "$apply" -eq 1 ] && ! archive_worktree_changes "$path" "$dest"; then why='dirty, archive failed'
    else reason='archived scratch'
    fi
  elif git merge-base --is-ancestor "$head" origin/main 2>/dev/null; then
    if [ -z "$branch" ]; then reason='detached at merged commit'; else reason=ancestor; fi
  elif [ -z "$branch" ]; then reason='detached at published commit'
  fi
  [ ! -s "$tmp/status" ] || force=--force
  if [ -n "$why" ]; then
    keep "worktree $path" "$why"
    printf '%s\n' "$path" >> "$tmp/kept-worktrees"
    [ -z "$branch" ] || printf '%s\n' "$branch" >> "$tmp/kept-branches"
  else
    printf 'Remove worktree %s (%s)\n' "$path" "$reason"
    if [ "$apply" -eq 0 ] || guarded_worktree_remove kept "worktree $path" "$path" "$force"; then
      removed=$((removed+1))
      printf '%s\n' "$path" >> "$tmp/removed-paths"
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
[ "$apply" -eq 0 ] || git worktree prune || fail_item 'git worktree prune' 'failed'
if [ "$terminals_read" -eq 1 ] && [ -s "$tmp/removed-paths" ]; then
  while IFS= read -r env_id; do
    [ -z "$env_id" ] || close_finished_terminals "$env_id" 1
  done < <(jq -r '.result.environments[] | .id // .name // empty' "$tmp/envs")
fi
[ -z "${WRAP_UP_SCHEDULED_CHILD:-}" ] || printf 'step worktrees seconds=%s\n' "$SECONDS"
# Release is after terminal and worktree cleanup. A failed release is recorded and does not undo a close.
if [ "$terminals_read" -eq 1 ]; then release_finished_workers; fi
while IFS= read -r branch; do
  if protected "$branch"; then
    keep "local $branch" "$protected_reason"
  elif archive_branch "$branch"; then
    keep "local $branch" 'archive branch'
  elif grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "local $branch" 'checked out in kept worktree'
  elif eligible "refs/heads/$branch" "$branch" && local_unpushed "$branch"; then
    keep "local $branch" "$unpushed_why"
    printf '%s\n' "$branch" >> "$tmp/kept-branches"
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
# The main checkout counts as clean when its only changes are untracked symlinks (links a machine install wrote there).
main_checkout_clean() {
  local line
  while IFS= read -r line; do
    case "$line" in '?? '*) [ -L "$main_checkout/${line#\?\? }" ] || return 1 ;; *) return 1 ;; esac
  done < <(git -C "$main_checkout" status --porcelain --untracked-files=all)
}
update_main() {
  local main_t left
  if [ "$(git -C "$main_checkout" symbolic-ref --quiet --short HEAD || true)" = main ] && main_checkout_clean; then
    echo 'Fast forward main checkout'
    if [ "$apply" -eq 1 ]; then
      if [ -n "${WRAP_UP_MAIN_TIMEOUT:-}" ]; then
        main_t=$WRAP_UP_MAIN_TIMEOUT
        left=$((deadline-SECONDS))
        [ "$left" -ge "$main_t" ] || main_t=$left
        [ "$main_t" -gt 0 ] || main_t=1
        run_limited "$main_t" git -C "$main_checkout" -c pull.rebase=false pull --ff-only origin main || fail_item 'main update' 'git pull failed or timed out'
      else
        bounded git -C "$main_checkout" -c pull.rebase=false pull --ff-only origin main || fail_item 'main update' 'git pull failed or timed out'
      fi
    fi
    # The merged preset reaches Orca only through setup-orca.sh; prefer the copy from the freshly updated checkout.
    if [ -f "$main_checkout/.orca/presets.json" ]; then
      setup_orca="$main_checkout/script/setup-orca.sh"; [ -f "$setup_orca" ] || setup_orca="$here/setup-orca.sh"
      echo 'Install merged Orca preset'
      [ "$apply" -eq 0 ] || DOTFILES="$main_checkout" bash "$setup_orca"
    fi
  else keep 'main update' 'checkout is not on main or is dirty'
  fi
}
# Browser sweep (issue 571). Candidates only: a main Chrome Dev or Chromium process on a throwaway profile under a temp
# root, and an agent-browser daemon. Stable Chrome and any profile outside temp are never candidates. Test seams:
# WRAP_UP_PS_CMD (list | show PID | cwd PID) and WRAP_UP_KILL_CMD (PID). Stops by pid with TERM after rereading the pid.
# Process lines are tab separated: pid, ppid, age in seconds, start time, command.
browser_closed=0; browser_kept=0
ps_real() {
  case "$1" in
    list|show)
      local pargs=(-axww); [ "$1" = list ] || pargs=(-ww -p "$2")
      ps "${pargs[@]}" -o pid=,ppid=,etime=,lstart=,command= | awk '{
        t = $3; d = 0
        if (index(t, "-")) { split(t, dp, "-"); d = dp[1]; t = dp[2] }
        n = split(t, a, ":")
        s = (n == 3) ? a[1]*3600 + a[2]*60 + a[3] : a[1]*60 + a[2]; s += d*86400
        cmd = $9; for (i = 10; i <= NF; i++) cmd = cmd " " $i
        printf "%s\t%s\t%s\t%s %s %s %s %s\t%s\n", $1, $2, s, $4, $5, $6, $7, $8, cmd }' ;;
    cwd) command -v lsof >/dev/null 2>&1 || return 1
      local out; out=$(lsof -a -p "$2" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1); [ -n "$out" ] && printf '%s\n' "$out" ;;
  esac
}
ps_do() { if [ -n "${WRAP_UP_PS_CMD:-}" ]; then "$WRAP_UP_PS_CMD" "$@"; else ps_real "$@"; fi; }
kill_do() { if [ -n "${WRAP_UP_KILL_CMD:-}" ]; then "$WRAP_UP_KILL_CMD" "$1"; else kill -TERM "$1"; fi; }
alive_do() {
  if [ -n "${WRAP_UP_ALIVE_CMD:-}" ]; then "$WRAP_UP_ALIVE_CMD" "$1"
  elif [ -n "${WRAP_UP_KILL_CMD:-}" ]; then return 1
  else kill -0 "$1" 2>/dev/null; fi
}
squash_path() { printf '%s' "$1" | sed 's#//*#/#g; s#/$##'; }
is_temp_path() {
  local p root; p=$(squash_path "$1")
  case "$p" in /*) : ;; *) return 1 ;; esac
  case "$p" in */../*|*/..|*/./*|*/.) return 1 ;; esac
  for root in /tmp /private/tmp /var/folders /private/var/folders "$(squash_path "${TMPDIR:-}")"; do
    [ -n "$root" ] || continue
    case "$p" in "$root"/*) return 0 ;; esac
  done
  return 1
}
browser_profile() { local p=${1#*--user-data-dir=}; [ "$p" != "$1" ] || return 1; printf '%s' "${p%% --*}"; }
is_main_browser() {
  case "$1" in *' --type='*) return 1 ;; esac
  case "$1" in "/"*"/Google Chrome Dev.app/"*|"/"*"/Chromium.app/"*) return 0 ;; esac
  return 1
}
# Any Chrome family browser, for the "a daemon may drive it" checks. Only Chrome Dev and Chromium can be closed.
is_any_browser() {
  case "$1" in *' --type='*) return 1 ;; esac
  case "$1" in "/"*"/Google Chrome"*".app/"*|"/"*"/Chromium.app/"*|"/"*"/Microsoft Edge"*".app/"*) return 0 ;; esac
  return 1
}
# Whether a command line runs head-checks, QA admission or the heavy gate. Skips interpreters, env, flags and NAME=value,
# then reads the path up to its first flag (a checkout path may hold a space). A stray match only keeps a browser.
is_gated_run() {
  local rest=$1 w
  while [ -n "$rest" ]; do
    w=${rest%%[[:space:]]*}
    case "$w" in -*|*=*) ;; *) case "${w##*/}" in env|bash|sh|zsh|[Pp]ython|[Pp]ython[0-9]*|node|bun|uv|run) ;; *) break ;; esac ;; esac
    rest=${rest#"$w"}; rest=${rest#"${rest%%[![:space:]]*}"}
  done
  rest=${rest%%[[:space:]]-*}
  case "$rest" in head-checks*|qa-admission*|heavy-gate*|*/head-checks*|*/qa-admission*|*/heavy-gate*) return 0 ;; esac
  return 1
}
is_agent_daemon() {
  local w1 w2; read -r w1 w2 _ <<< "$1"
  case "${w1##*/}" in *agent-browser*) return 0 ;; node|bun) case "${w2:-}" in *agent-browser*) return 0 ;; esac ;; esac
  return 1
}
in_active_path() {
  local target=$1 a
  [ -n "$target" ] || return 1
  [ ! -d "$target" ] || target=$(cd "$target" && pwd -P)
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$target" in "$a"|"$a"/*) return 0 ;; esac
  done < "$tmp/active"
  return 1
}
browser_keep() { printf 'Kept browser %s (%s)\n' "$1" "$2"; browser_kept=$((browser_kept+1)); }
sweep_browsers() {
  local pid ppid age started cmd kind profile cwdir child cppid cmdl now_line n_started n_cmd outside
  [ "$browser_sweep" -eq 1 ] || return 0
  begin_optional
  if ! ps_do list > "$tmp/procs" 2>/dev/null; then echo 'Warning: process list unavailable; closing no browsers.' >&2; return 0; fi
  # Signs that a browser is in use: a running head-checks, QA or heavy-gate run, and a browser outside temp that
  # offers a debugging port (a daemon may be attached to it with nothing to show for it in the process table).
  run_active=$dispatch_run; cdp_outside=''
  while IFS=$'\t' read -r _ _ _ _ cmd; do
    if is_gated_run "$cmd"; then run_active=1; fi
    if is_any_browser "$cmd"; then
      case "$cmd" in *--remote-debugging-port*|*--remote-debugging-pipe*) profile=$(browser_profile "$cmd") && is_temp_path "$profile" || cdp_outside=1 ;; esac
    fi
  done < "$tmp/procs"
  while IFS=$'\t' read -r pid ppid age started cmd; do
    [ -n "$pid" ] || continue
    optional_ok || { optional_stop 'browser sweep'; break; }
    kind=''; profile=''
    if is_main_browser "$cmd"; then
      profile=$(browser_profile "$cmd") || continue
      is_temp_path "$profile" || continue
      kind='stale throwaway browser profile'
    elif is_agent_daemon "$cmd"; then kind='stale agent-browser daemon'
    else continue; fi
    if [ "$inventory_read" -eq 0 ] || grep -Fxq '*' "$tmp/active"; then browser_keep "$pid" 'no complete dispatch inventory'; continue; fi
    case "$age" in ''|*[!0-9]*) browser_keep "$pid" 'age unknown'; continue ;; esac
    if [ "$age" -lt 7200 ]; then browser_keep "$pid" 'younger than 2 hours'; continue; fi
    # Parent pid 1 proves nothing: a macOS app launched through LaunchServices has it too.
    if [ -n "$run_active" ]; then browser_keep "$pid" 'a head-checks, QA or gated run is active'; continue; fi
    if [ "$ppid" != 1 ] && [ "$ppid" != 0 ] && awk -F'\t' -v p="$ppid" '$1 == p { f = 1 } END { exit !f }' "$tmp/procs"; then browser_keep "$pid" 'parent still running'; continue; fi
    if ! cwdir=$(ps_do cwd "$pid" 2>/dev/null) || [ -z "$cwdir" ]; then browser_keep "$pid" 'working directory unreadable'; continue; fi
    if in_active_path "$cwdir" || in_active_path "$profile"; then browser_keep "$pid" 'inside an active dispatch path'; continue; fi
    if [ "$kind" = 'stale agent-browser daemon' ]; then
      outside=''
      while IFS=$'\t' read -r child cppid _ _ cmdl; do
        [ "$cppid" = "$pid" ] && is_any_browser "$cmdl" || continue
        profile=$(browser_profile "$cmdl") || continue
        is_temp_path "$profile" || outside=1
      done < "$tmp/procs"
      case "$cmd" in *--cdp*) outside=1 ;; esac
      [ -z "$cdp_outside" ] || outside=1
      if [ -n "$outside" ]; then browser_keep "$pid" 'drives a browser outside temp'; continue; fi
    fi
    if [ "$apply" -eq 1 ]; then
      # Age moves on a live host, so identity is the start time and the command.
      now_line=$(ps_do show "$pid" 2>/dev/null | head -n 1) || now_line=''
      IFS=$'\t' read -r _ _ _ n_started n_cmd <<< "$now_line"
      if [ -z "$now_line" ] || [ "$n_started" != "$started" ] || [ "$n_cmd" != "$cmd" ]; then browser_keep "$pid" 'process changed since listed'; continue; fi
      if ! kill_do "$pid" >/dev/null 2>&1; then browser_keep "$pid" 'stop failed'; continue; fi
      for _ in {1..25}; do alive_do "$pid" || break; sleep 0.2; done
      if alive_do "$pid"; then
        echo "Warning: browser pid $pid still alive after kill." >&2
        fail_item "browser $pid" "browser pid $pid still alive after kill"
        browser_keep "$pid" "browser pid $pid still alive after kill"
        continue
      fi
    fi
    printf 'Close browser %s (%s)\n' "$pid" "$kind"
    browser_closed=$((browser_closed+1))
  done < "$tmp/procs"
  printf 'browsers closed=%s kept=%s\n' "$browser_closed" "$browser_kept"
}
sweep_browsers
# Grayed-out workspaces (issue 953): every non-main Orca worktree with no terminal attached goes, with its branch kept.
# Uncommitted tracked changes keep it, named in the report. Runs on a fleet host too, ahead of its early exit below.
guarded_idle_worktree_rm() { # <orca id> <path>: after sweep_idle_worktrees' terminal and dirty checks; never --delete-branch
  if orca_call worktree rm --worktree "id:$1" --force >/dev/null 2>&1; then
    printf 'Removed idle worktree %s\n' "$2"
  else
    echo "Warning: could not remove idle worktree $2." >&2; fail_item "idle worktree $2" 'orca worktree rm failed'; return 1
  fi
}
sweep_idle_worktrees() {
  local term_json="$tmp/sweep-terminals" wt_json="$tmp/sweep-worktrees" id path rc gone=0 dirty=0 status_out
  [ -n "${orca_bin:-}" ] && command -v "$orca_bin" >/dev/null 2>&1 || { echo 'Idle worktree sweep skipped: Orca unavailable'; return 0; }
  if ! orca_call terminal list --json > "$term_json" 2>/dev/null \
    || ! jq -e '.ok != false and (.result.terminals | type == "array") and (.result.truncated != true)' "$term_json" >/dev/null 2>&1; then
    echo 'Idle worktree sweep skipped: cannot read the terminal list'; fail_item 'idle worktrees' 'terminal list unreadable; all kept'; return 0
  fi
  if ! orca_call worktree list --json > "$wt_json" 2>/dev/null \
    || ! jq -e '.ok != false and ((.result.worktrees // []) | type == "array") and (.result.truncated != true)' "$wt_json" >/dev/null 2>&1; then
    echo 'Idle worktree sweep skipped: cannot read the worktree list'; fail_item 'idle worktrees' 'worktree list unreadable; all kept'; return 0
  fi
  jq -r '.result.terminals[]? | (.worktreePath // empty) | select(. != "")' "$term_json" > "$tmp/sweep-live"
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] && [ -n "$path" ] || continue
    if grep -Fxq -- "$path" "$tmp/sweep-live" || grep -Fxq -- "$(real "$path")" "$tmp/sweep-live"; then continue; fi
    if [ -d "$path" ]; then
      rc=0; status_out=$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null) || rc=$?
      if [ "$rc" -ne 0 ] || [ -n "$status_out" ]; then
        printf 'Kept idle worktree %s (uncommitted changes)\n' "$path"; dirty=$((dirty+1)); continue
      fi
    fi
    if [ "$apply" -eq 0 ]; then printf 'Remove idle worktree %s\n' "$path"; gone=$((gone+1)); continue; fi
    if guarded_idle_worktree_rm "$id" "$path"; then gone=$((gone+1)); fi
  done < <(jq -r '.result.worktrees[]? | select((.isMainWorktree == true or .git.isMainWorktree == true) | not) | [.id // "", (.path // .workspacePath // "")] | @tsv' "$wt_json")
  printf 'idle worktrees %s=%s kept dirty=%s\n' "$([ "$apply" -eq 0 ] && echo 'to remove' || echo removed)" "$gone" "$dirty"
}
sweep_idle_worktrees
# A fleet host runs worktrees and local branches only: the coordinator run deletes remote branches once. With
# --main-update it also fast forwards a clean main checkout and installs the merged preset.
if [ "$worktrees_only" -eq 1 ]; then
  [ "$main_update" -eq 0 ] || update_main
  if [ "$apply" -eq 0 ]; then echo 'Planned counts (nothing deleted):'; else echo 'Completed counts:'; fi
  printf 'removed worktrees=%s orca records=%s deleted local=%s deleted remote=0 kept=%s stale=0 stale deleted=0\n' "$removed" "$orca_removed" "$local_deleted" "$kept"
  printf 'build caches removed=%s kept=%s bytes=%s\n' "$cache_removed" "$cache_kept" "$cache_bytes"
  missing_lsof_summary
  finish
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
begin_optional
while IFS= read -r ref; do
  optional_ok || { optional_stop 'remote branch cleanup'; break; }
  branch=${ref#refs/remotes/origin/}
  if protected "$branch"; then
    keep "remote $branch" "$protected_reason"
  elif archive_branch "$branch"; then
    keep "remote $branch" 'archive branch'
  elif grep -Fxq -- "$branch" "$tmp/kept-branches"; then
    keep "remote $branch" 'checked out in kept worktree'
  elif eligible "$ref" "$branch" && last_copy "$(git rev-parse "$ref")" "$branch"; then
    keep "remote $branch" 'last copy of unmerged work'; last_copy_kept=$((last_copy_kept+1))
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
  local dir=$1 rest=$2 entry name s rc
  if [ -n "${optional_deadline:-}" ] && [ "$SECONDS" -ge "$optional_deadline" ]; then return 2; fi
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}; s=$(slugify "$name")
    if [ "$rest" = "$s" ]; then return 0; fi
    case "$rest" in
      "$s"-*)
        rc=0
        slug_exists "$entry" "${rest#"$s"-}" || rc=$?
        [ "$rc" -eq 1 ] || return "$rc"
        ;;
    esac
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
  begin_optional
  for entry in "$scratch_root"/*/; do
    optional_ok || { optional_stop 'temp cleanup'; break; }
    entry=${entry%/}; [ -d "$entry" ] || continue
    case "${entry##*/}" in
      -*)
        slug=${entry##*/}; gone=1; rc=0
        slug_exists '' "${slug#-}" || rc=$?
        if [ "$rc" -eq 2 ]; then optional_stop 'temp cleanup'; break; fi
        [ "$rc" -eq 0 ] && gone=0
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
# A local branch with a commit on no origin ref holds work that exists only on this host: it is never deleted, and an
# unreadable count keeps it too. Checked again right before the delete.
stale_found=0
if [ "$pr_ok" -eq 1 ]; then
  begin_optional
  now=$(date +%s)
  {
    git for-each-ref --format='%(refname:strip=2)' refs/heads
    git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin
  } | sort -u > "$tmp/names"
  while IFS= read -r name; do
    optional_ok || { optional_stop 'stale branch cleanup'; break; }
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
    case "$name" in archive/*) keep "stale $name" 'archive branch'; continue ;; esac
    if [ -n "$wt" ] && in_use "$wt"; then keep "stale $name" "$busy"; continue; fi
    if local_unpushed "$name"; then keep "stale $name" "$unpushed_why"; continue; fi
    if [ "$stale_found" -eq 0 ]; then echo 'Stale (eligible for cleanup)'; fi
    stale_found=$((stale_found+1))
    subject=$(git log --reverse --format=%s "origin/main..${refs[0]}" | sed -n 1p)
    printf '  %s, %sh old, %s\n' "$name" $(( (now - newest) / 3600 )) "$subject"
    # A worker may have checked the branch out since the listing above; once the inventory fails, nothing more goes.
    if [ "$apply" -eq 1 ]; then
      if ! fresh_inventory 'deleting no more stale branches'; then keep "stale $name" 'worktree inventory unavailable'; continue; fi
      if local_unpushed "$name"; then keep "stale $name" "$unpushed_why"; continue; fi
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
# Drop Orca sidebar entries whose git worktree is already gone (for example a prior run removed git but not Orca).
if [ "$apply" -eq 1 ] && [ "$orca_pin_state" = ok ]; then
  repo_real=$(cd "$repo" && pwd -P)
  orca_repo_id='' orca_host_id=''
  while IFS=$'\t' read -r rid mp hid; do
    [ -n "$rid" ] && [ -n "$mp" ] || continue
    if [ "$(real "$mp" 2>/dev/null || printf '%s' "$mp")" = "$repo_real" ]; then
      orca_repo_id=$rid orca_host_id=$hid
      break
    fi
  done < <(jq -r '.result.worktrees[]? | select(.isMainWorktree == true or .git.isMainWorktree == true) | [.repoId // empty, (.path // .workspacePath // empty), (.hostId // "local")] | @tsv' "$tmp/orca-worktrees")
  if [ -z "$orca_repo_id" ]; then
    echo "Orca orphan sweep skipped: no main worktree record for $repo_real"
  else
    while IFS= read -r op; do
      [ -n "$op" ] || continue
      [ -d "$op" ] && continue
      worktree_pinned_in_orca "$op" && continue
      printf 'Remove orca record %s (git worktree already gone)\n' "$op"
      guarded_orca_worktree_rm kept "orca record $op" "$op" || true
    done < <(jq -r --arg rid "$orca_repo_id" --arg hid "$orca_host_id" '
      .result.worktrees[]? | select(.repoId == $rid and (.hostId // "local") == $hid)
      | select((.isMainWorktree == true or .git.isMainWorktree == true) | not)
      | select(.pinned != true and .isPinned != true)
      | (.path // .workspacePath // empty) | select(. != "")' "$tmp/orca-worktrees")
  fi
fi
# Counts first: a caller that times out inside the pane step has still seen them.
if [ "$apply" -eq 0 ]; then echo 'Planned counts (nothing deleted):'; else echo 'Completed counts:'; fi
printf 'removed worktrees=%s orca records=%s deleted local=%s deleted remote=%s kept=%s stale=%s stale deleted=%s\n' "$removed" "$orca_removed" "$local_deleted" "$remote_deleted" "$kept" "$stale_found" "$stale_deleted"
printf 'terminals closed=%s kept=%s\n' "$term_closed" "$term_kept"
printf 'workers released=%s\n' "$released_count"
printf 'workers needing no action=%s\n' "$no_action_count"
printf 'last copies kept=%s\n' "$last_copy_kept"
printf 'build caches removed=%s kept=%s bytes=%s\n' "$cache_removed" "$cache_kept" "$cache_bytes"
printf 'chrome clones removed=%s kept=%s\n' "$clone_removed" "$clone_kept"
printf 'temp removed=%s kept=%s bytes=%s\n' "$temp_removed" "$temp_kept" "$temp_bytes"
missing_lsof_summary
pane_script=${WORKER_PANE_CLOSE:-$HOME/.claude/skills/orca-team/worker-pane-close.sh}
if [ -f "$pane_script" ]; then
  echo 'Close ended worker panes'
  if [ "$apply" -eq 1 ]; then
    pane_left=${WRAP_UP_PANE_TIMEOUT:-1800}
    round_left=$((deadline-SECONDS))
    if [ "$round_left" -lt "$pane_left" ]; then
      pane_left=$round_left
    fi
    [ "$pane_left" -gt 0 ] || pane_left=1
    rc=0
    pane_out="$tmp/pane-close"
    ORCA_PANE_CLOSE_TIMEOUT=$pane_left ORCA_PANE_CALL_TIMEOUT=${WRAP_UP_PANE_CALL_TIMEOUT:-10} run_limited "$pane_left" bash "$pane_script" >"$pane_out" 2>&1 || rc=$?
    sed -n '/^sweep: /p' "$pane_out"
    guarded_scratch_rm f "$pane_out"
    # 124 is the sweep running out of its budget: it keeps its records and resumes next round, so it is a note, not a failure.
    if [ "$rc" -eq 124 ]; then echo "Warning: worker-pane-close timed out after ${pane_left}s; retried next run" >&2
    elif [ "$rc" -ne 0 ]; then fail_item 'worker panes' "worker-pane-close exited $rc"; fi
  fi
fi
update_main
# --fleet: run the same cleanup on every host in the untracked fleet config (worktrees and local branches only), then
# fast forward that host's clean main checkout and install the merged preset; a dirty or off main checkout is reported.
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
bash "$root/script/wrap-up.sh" --worktrees-only --main-update $flags --repo "$repo" 2>&1 || status=$?
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
        echo "Warning: fleet host $fhost unreachable or incomplete (status $fstatus); skipped." >&2; fail_item "fleet host $fhost" "unreachable or incomplete (status $fstatus)"; continue
      fi
      awk -v t="$ftag" '$0 == "@@begin-" t "@@" { on = 1; next } index($0, "@@end-" t "-") == 1 { on = 0; next } on' "$tmp/fleet-out" > "$tmp/fleet-body"
      cat "$tmp/fleet-body"
      if [ "$rstatus" -ne 0 ]; then echo "Warning: wrap-up failed on fleet host $fhost (status $rstatus); not counted." >&2; fail_item "fleet host $fhost" "wrap-up exited $rstatus"; continue; fi
      counts=$(sed -n 's/^removed worktrees=\([0-9][0-9]*\)\( orca records=[0-9][0-9]*\)\{0,1\} deleted local=\([0-9][0-9]*\) deleted remote=[0-9]* kept=\([0-9][0-9]*\) .*$/\1 \3 \4/p' "$tmp/fleet-body" | tail -n 1)
      if [ -z "$counts" ]; then echo "Warning: no counts line from fleet host $fhost; not counted." >&2; continue; fi
      read -r c_removed c_local c_kept <<< "$counts"
      t_up=$((t_up+1)); t_removed=$((t_removed+c_removed)); t_local=$((t_local+c_local)); t_kept=$((t_kept+c_kept))
    done < <(jq -r '.hosts[] | [.host // "", .repo_dir // ""] | @tsv' "$fleet_config")
  fi
  printf '\nFleet total (local plus %s of %s hosts reached):\n' "$t_up" "$t_hosts"
  printf 'removed worktrees=%s deleted local=%s kept=%s\n' "$t_removed" "$t_local" "$t_kept"
  if [ -x "$here/fleet-toolchain-check.sh" ]; then
    tc=$("$here/fleet-toolchain-check.sh" 2>&1) || true
    [ -z "$tc" ] || echo "$tc"
  fi
  # Saved Orca reply shapes (#990). Dry mode reads the files and does not call Orca.
  if [ -f "$here/fleet-watch-record.py" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      fail_item 'fleet-watch contract' 'python3 missing'
    else
      contract_rc=0
      contract_out=$(run_limited 180 python3 "$here/fleet-watch-record.py" --dry 2>&1) || contract_rc=$?
      if [ "$contract_rc" -ne 0 ]; then
        printf '%s\n' "$contract_out" >&2
        fail_item 'fleet-watch contract' "reply shape drifted (status ${contract_rc})"
      fi
    fi
  fi
fi
finish
