#!/usr/bin/env bash
# One scheduled wrap-up round (run by launchd every two hours): lock, Orca check, load check, then
# wrap-up.sh --apply per repo in script/wrap-up-scheduled.config.json. Always exits 0 on a skip.
# A manual wrap-up run does not take this lock; wrap-up's own guards recheck before every delete.
# launchd gives a bare environment, so nothing here depends on the login shell.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="$PATH:$HOME/.local/bin:$HOME/.orca/cli/bin:/opt/homebrew/bin:/usr/local/bin"
config=${WRAP_UP_SCHEDULED_CONFIG:-$here/wrap-up-scheduled.config.json}
fleet_state=${WRAP_UP_SCHEDULED_FLEET_STATE:-$HOME/.claude/state/fleet-config.json}
state_dir=${WRAP_UP_STATE_DIR-${XDG_STATE_HOME:-$HOME/.local/state}/agent-team}
log_file=${WRAP_UP_SCHEDULED_LOG:-$HOME/.orca/logs/wrap-up-scheduled.log}
wrap_up=${WRAP_UP_SCHEDULED_WRAP_UP:-$here/wrap-up.sh}
lock="$state_dir/wrap-up-scheduled.lock"

mkdir -p "$(dirname "$log_file")" "$state_dir"
# Keep one rotated copy past 5 MB.
if [ -f "$log_file" ] && [ "$(wc -c < "$log_file" | tr -d ' ')" -gt 5242880 ]; then mv -f "$log_file" "$log_file.1"; fi
log() { printf '%s wrap-up-scheduled [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" >> "$log_file"; }

# Lock, one per host: a file holding the owner's pid, linked into place so it never exists without it. A holder counts
# only when its pid is alive and still runs this script. A lock with no readable pid counts as live until it is old
# enough to be stale (an older version made a directory). A takeover goes through a guard file, so two runs that both
# judge a lock stale leave one owner.
stale_minutes=${WRAP_UP_SCHEDULED_LOCK_STALE_MINUTES:-10}
lock_pid() { cat "$lock" 2>/dev/null || cat "$lock/pid" 2>/dev/null; }
lock_is_stale() {
  local pid; pid=$(lock_pid)
  case "$pid" in
    ''|*[!0-9]*) [ -n "$(find "$lock" -maxdepth 0 -mmin +"$stale_minutes" 2>/dev/null)" ]; return ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 0
  ! ps -p "$pid" -o command= 2>/dev/null | grep -Fq wrap-up-scheduled
}
# Link a private file holding this pid to $1; fails when $1 exists (ln would drop the file inside a directory, so check first).
link_pid() {
  local mine="$1.$$"
  [ ! -e "$1" ] && echo "$$" > "$mine" && ln "$mine" "$1" 2>/dev/null; local rc=$?
  rm -f "$mine"; return "$rc"
}
log 'round start'
if ! link_pid "$lock"; then
  if ! lock_is_stale; then log "skip: already running (pid $(lock_pid))"; exit 0; fi
  guard="$lock.takeover"
  if ! link_pid "$guard"; then
    # A guard whose taker died is cleared once it is old; this round still skips.
    [ -z "$(find "$guard" -maxdepth 0 -mmin +"$stale_minutes" 2>/dev/null)" ] || rm -f "$guard"
    log 'skip: another run is taking over the lock'; exit 0
  fi
  if lock_is_stale; then
    log 'stale lock, taking over'
    rm -rf "$lock"
  fi
  link_pid "$lock"; got=$?
  rm -f "$guard"
  [ "$got" -eq 0 ] || { log 'skip: lost the lock race'; exit 0; }
fi
release() { if [ "$(cat "$lock" 2>/dev/null)" = "$$" ]; then rm -f "$lock"; fi; }
trap release EXIT

# Orca must answer and report ready.
if ! status_json=$(env -u ORCA_CLI_COMMAND orca status --json 2>/dev/null) \
  || [ "$(printf '%s' "$status_json" | jq -r '.result.runtime.state // ""' 2>/dev/null)" != ready ]; then
  log 'skip: Orca not ready'; exit 0
fi

# 1 minute load against this host's ceiling in the fleet config.
[ -f "$config" ] && jq -e '.repos | type == "array"' "$config" >/dev/null 2>&1 || { log "skip: no config at $config"; exit 0; }
local_host=$(jq -r '.local_host // empty' "$fleet_state" 2>/dev/null)
[ -n "$local_host" ] || local_host=$(hostname -s 2>/dev/null)
limit=$(jq -r --arg h "$local_host" '.host_load_ceilings[$h] // empty | select(type == "number" and . > 0)' "$fleet_state" 2>/dev/null)
if [ -z "$limit" ]; then log "skip: no load limit readable for local host in $fleet_state"; exit 0; fi
if [ -n "${WRAP_UP_SCHEDULED_LOAD_CMD:-}" ]; then load=$(eval "$WRAP_UP_SCHEDULED_LOAD_CMD" 2>/dev/null)
elif [ -r /proc/loadavg ]; then load=$(cut -d' ' -f1 /proc/loadavg)
else load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'); fi
if ! awk -v l="${load:-}" 'BEGIN { exit (l ~ /^[0-9]+([.][0-9]+)?$/) ? 0 : 1 }'; then log 'skip: load unreadable'; exit 0; fi
if awk -v l="$load" -v m="$limit" 'BEGIN { exit (l > m) ? 0 : 1 }'; then log "skip: load $load above limit $limit"; exit 0; fi

# Per repo. The fleet config carries one repo_dir per host, so it is set per repo; no fleet_config means no --fleet.
# ORCA_CLI_COMMAND stays unset: wrap-up refuses --apply in test mode.
while IFS=$'\t' read -r repo_path repo_fleet; do
  [ -n "$repo_path" ] || continue
  case "$repo_path" in '~'|'~/'*) repo_path="$HOME${repo_path#\~}" ;; esac
  case "$repo_fleet" in '~'|'~/'*) repo_fleet="$HOME${repo_fleet#\~}" ;; esac
  args=(--apply)
  if [ -n "$repo_fleet" ]; then args+=(--fleet); fi
  args+=(--repo "$repo_path")
  if [ -n "$repo_fleet" ]; then
    env -u ORCA_CLI_COMMAND WRAP_UP_FLEET_CONFIG="$repo_fleet" bash "$wrap_up" "${args[@]}" >> "$log_file" 2>&1 < /dev/null
  else
    env -u ORCA_CLI_COMMAND -u WRAP_UP_FLEET_CONFIG bash "$wrap_up" "${args[@]}" >> "$log_file" 2>&1 < /dev/null
  fi
  code=$?
  log "repo $repo_path exit $code"
done < <(jq -r '.repos[] | [.path // "", .fleet_config // ""] | @tsv' "$config")
log 'round finished'
exit 0
