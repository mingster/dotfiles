#!/usr/bin/env bash
# Install Orca automations: fleet-watch (5 min), wrap-up-scheduled (2 h), sync drift (daily),
# team-audit-weekly and weekly-update (Monday). Enabled only on the coordinator in agent-state/coordinator.conf.
# Private paths: env vars or ~/.config/fleet-watch/automations.env (no secrets in this repo).
#
# Usage: install-fleet-automations.sh --status
#        install-fleet-automations.sh [--dry-run] --install
#        install-fleet-automations.sh --uninstall
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dotfiles=$(cd "$here/.." && pwd -P)
orca_cli=${ORCA_CLI_COMMAND:-orca}
dry=0
action=""

usage() {
  sed -n '2,9p' "$0"
  printf '\n'
  printf '  --status     Print enabled/disabled for each fleet automation\n'
  printf '  --install    Create or update automations (idempotent by name)\n'
  printf '  --uninstall  Remove fleet automations by name\n'
  printf '  --dry-run    With --install, print planned orca commands only\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status) action=status ;;
    --install) action=install ;;
    --uninstall) action=uninstall ;;
    --dry-run) dry=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "install-fleet-automations: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$action" ] || { usage >&2; exit 2; }
[ "$dry" = 1 ] && [ "$action" = install ] || [ "$dry" = 0 ] || {
  echo 'install-fleet-automations: --dry-run applies only to --install' >&2
  exit 2
}

env_file=${FLEET_AUTOMATIONS_ENV:-$HOME/.config/fleet-watch/automations.env}
if [ -f "$env_file" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
fi

DOTFILES_DIR=${DOTFILES_DIR:-$dotfiles}
if [ -d "$DOTFILES_DIR" ]; then
  DOTFILES_DIR=$(cd "$DOTFILES_DIR" && pwd -P)
fi
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
FLEET_WATCH_CONFIG=${FLEET_WATCH_CONFIG:-$HOME/.config/fleet-watch/config.json}
FLEET_WATCH_STATE=${FLEET_WATCH_STATE:-$HOME/.local/state/agent-team/fleet-watch.state.json}
FLEET_WATCH_PRECHECK_LOG=${FLEET_WATCH_PRECHECK_LOG:-$HOME/.local/state/agent-team/fleet-watch-precheck.log}
FLEET_AUTOMATIONS_TIMEZONE=${FLEET_AUTOMATIONS_TIMEZONE:-${TZ:-}}
FLEET_AUTOMATIONS_PROVIDER=${FLEET_AUTOMATIONS_PROVIDER:-claude}
AUTOMATION_PROMPT=${FLEET_AUTOMATIONS_PROMPT:-'Script only job, the precheck always stops it.'}
FLEET_WATCH_PRECHECK_TIMEOUT=${FLEET_WATCH_PRECHECK_TIMEOUT:-280}
WRAP_UP_PRECHECK_TIMEOUT=${WRAP_UP_PRECHECK_TIMEOUT:-300}
SYNC_DRIFT_LOG=${SYNC_DRIFT_LOG:-$HOME/.local/state/agent-team/sync-team-skills-drift.log}
TEAM_AUDIT_WEEKLY_LOG=${TEAM_AUDIT_WEEKLY_LOG:-$HOME/.local/state/agent-team/team-audit-weekly.log}
SYNC_DRIFT_PRECHECK_TIMEOUT=${SYNC_DRIFT_PRECHECK_TIMEOUT:-300}
TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT=${TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT:-600}
WEEKLY_UPDATE_LOG=${WEEKLY_UPDATE_LOG:-$HOME/.local/state/agent-team/weekly-update.log}
WEEKLY_UPDATE_PRECHECK_TIMEOUT=${WEEKLY_UPDATE_PRECHECK_TIMEOUT:-3600}
FLEET_AUTOMATION_NAMES='fleet-watch wrap-up-scheduled sync-team-skills-drift team-audit-weekly weekly-update'

precheck_path() {
  local p="$HOME/.local/bin"
  local orca_app="/Applications/_dev/Orca.app/Contents/Resources/bin"
  [ -d "$orca_app" ] && p="$p:$orca_app"
  p="$p:${FLEET_AUTOMATIONS_PATH_EXTRA:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin}"
  printf '%s' "$p"
}

coordinator_name() {
  local conf want
  conf=$(cat "$state_dir/coordinator.conf" 2>/dev/null || true)
  want=$(printf '%s\n' "$conf" | awk '$1 == "coordinator" { print $2; exit }' | tr '[:upper:]' '[:lower:]')
  printf '%s' "${want:-mini6}"
}

host_is_coordinator() {
  local me want
  me=$(hostname -s | tr '[:upper:]' '[:lower:]')
  want=$(coordinator_name)
  [ "$me" = "$want" ]
}

fleet_watch_precheck() {
  local path shell_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' python3 '%s/script/fleet-watch.py' --config '%s' --state '%s' >> '%s' 2>&1; exit 1" \
    "$shell_pw" "$DOTFILES_DIR" "$FLEET_WATCH_CONFIG" "$FLEET_WATCH_STATE" "$FLEET_WATCH_PRECHECK_LOG"
}

wrap_up_precheck() {
  local path shell_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' bash '%s/script/wrap-up.sh' --scheduled; exit 1" "$shell_pw" "$DOTFILES_DIR"
}

sync_drift_precheck() {
  local path shell_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' DOTFILES='%s' SYNC_DRIFT_LOG='%s' bash '%s/script/automation-precheck-sync-drift.sh'; exit 1" \
    "$shell_pw" "$DOTFILES_DIR" "$SYNC_DRIFT_LOG" "$DOTFILES_DIR"
}

team_audit_weekly_precheck() {
  local path shell_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' DOTFILES='%s' TEAM_AUDIT_WEEKLY_LOG='%s' bash '%s/script/automation-precheck-team-audit-weekly.sh'; exit 1" \
    "$shell_pw" "$DOTFILES_DIR" "$TEAM_AUDIT_WEEKLY_LOG" "$DOTFILES_DIR"
}

weekly_update_precheck() {
  local path shell_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' DOTFILES='%s' WEEKLY_UPDATE_LOG='%s' bash '%s/script/automation-precheck-weekly-update.sh'; exit 1" \
    "$shell_pw" "$DOTFILES_DIR" "$WEEKLY_UPDATE_LOG" "$DOTFILES_DIR"
}

list_json() {
  "$orca_cli" automations list --json
}

automation_by_name() {
  local name=$1 json
  json=$(list_json)
  AUTOMATION_LOOKUP_JSON=$json AUTOMATION_LOOKUP_NAME=$name python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["AUTOMATION_LOOKUP_JSON"])
if not data.get("ok"):
    sys.exit(2)
for a in data.get("result", {}).get("automations", []):
    if a.get("name") == os.environ["AUTOMATION_LOOKUP_NAME"]:
        print(json.dumps(a))
        sys.exit(0)
sys.exit(1)
PY
}

run_orca() {
  if [ "$dry" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_orca_with_timezone() {
  if [ -n "$FLEET_AUTOMATIONS_TIMEZONE" ]; then
    run_orca "$@" --timezone "$FLEET_AUTOMATIONS_TIMEZONE"
  else
    run_orca "$@"
  fi
}

orca_json_sink=/dev/null

run_orca_json() {
  if [ "$dry" = 1 ]; then
    run_orca_with_timezone "$@"
    return 0
  fi
  run_orca_with_timezone "$@" --json >"$orca_json_sink"
}

ensure_automation() {
  local name=$1 trigger=$2 precheck=$3 timeout=$4 enabled=$5
  local existing id
  if existing=$(automation_by_name "$name" 2>/dev/null); then
    id=$(AUTOMATION_ROW="$existing" python3 - <<'PY'
import json, os
print(json.loads(os.environ["AUTOMATION_ROW"])["id"])
PY
)
    if AUTOMATION_ROW="$existing" AUTOMATION_WANT_TRIGGER="$trigger" \
      AUTOMATION_WANT_PRECHECK="$precheck" AUTOMATION_WANT_TIMEOUT="$timeout" \
      AUTOMATION_WANT_ENABLED="$enabled" python3 - <<'PY'
import json, os
cur = json.loads(os.environ["AUTOMATION_ROW"])
want_enabled = os.environ["AUTOMATION_WANT_ENABLED"] == "1"
if cur.get("rrule") != os.environ["AUTOMATION_WANT_TRIGGER"]:
    raise SystemExit(1)
pc = cur.get("precheck") or {}
if pc.get("command") != os.environ["AUTOMATION_WANT_PRECHECK"]:
    raise SystemExit(1)
if int(pc.get("timeoutSeconds") or 0) != int(os.environ["AUTOMATION_WANT_TIMEOUT"]):
    raise SystemExit(1)
if bool(cur.get("enabled")) != want_enabled:
    raise SystemExit(1)
PY
    then
      echo "install-fleet-automations: $name unchanged (${id})"
      return 0
    fi
    if [ "$enabled" = 1 ]; then
      run_orca_json "$orca_cli" automations edit "$id" \
        --trigger "$trigger" \
        --precheck "$precheck" \
        --precheck-timeout "$timeout" \
        --enabled
    else
      run_orca_json "$orca_cli" automations edit "$id" \
        --trigger "$trigger" \
        --precheck "$precheck" \
        --precheck-timeout "$timeout" \
        --disabled
    fi
    if [ "$dry" = 1 ]; then
      echo "install-fleet-automations: would update $name (${id})"
    else
      echo "install-fleet-automations: $name updated (${id})"
    fi
    return 0
  fi
  if [ "$enabled" = 1 ]; then
    run_orca_json "$orca_cli" automations create \
      --name "$name" \
      --trigger "$trigger" \
      --prompt "$AUTOMATION_PROMPT" \
      --provider "$FLEET_AUTOMATIONS_PROVIDER" \
      --repo "path:$DOTFILES_DIR" \
      --setup skip \
      --precheck "$precheck" \
      --precheck-timeout "$timeout" \
      --enabled
  else
    run_orca_json "$orca_cli" automations create \
      --name "$name" \
      --trigger "$trigger" \
      --prompt "$AUTOMATION_PROMPT" \
      --provider "$FLEET_AUTOMATIONS_PROVIDER" \
      --repo "path:$DOTFILES_DIR" \
      --setup skip \
      --precheck "$precheck" \
      --precheck-timeout "$timeout" \
      --disabled
  fi
  if [ "$dry" = 1 ]; then
    echo "install-fleet-automations: would create $name"
  else
    echo "install-fleet-automations: $name created"
  fi
}

remove_by_name() {
  local name=$1 existing id
  if ! existing=$(automation_by_name "$name" 2>/dev/null); then
    echo "install-fleet-automations: $name not installed"
    return 0
  fi
  id=$(AUTOMATION_ROW="$existing" python3 - <<'PY'
import json, os
print(json.loads(os.environ["AUTOMATION_ROW"])["id"])
PY
)
  if [ "$dry" = 1 ]; then
    run_orca "$orca_cli" automations remove "$id"
    echo "install-fleet-automations: would remove $name (${id})"
  else
    run_orca "$orca_cli" automations remove "$id" --json >"$orca_json_sink"
    echo "install-fleet-automations: $name removed (${id})"
  fi
}

print_status() {
  local name state
  for name in $FLEET_AUTOMATION_NAMES; do
    if existing=$(automation_by_name "$name" 2>/dev/null); then
      state=$(AUTOMATION_ROW="$existing" python3 - <<'PY'
import json, os
print("enabled" if json.loads(os.environ["AUTOMATION_ROW"]).get("enabled") else "disabled")
PY
)
    else
      state=missing
    fi
    printf '%s: %s\n' "$name" "$state"
  done
}

case "$action" in
  status)
    print_status
    ;;
  install)
    enabled=0
    host_is_coordinator && enabled=1
    ensure_automation fleet-watch '*/5 * * * *' "$(fleet_watch_precheck)" "$FLEET_WATCH_PRECHECK_TIMEOUT" "$enabled"
    ensure_automation wrap-up-scheduled '0 */2 * * *' "$(wrap_up_precheck)" "$WRAP_UP_PRECHECK_TIMEOUT" "$enabled"
    ensure_automation sync-team-skills-drift '0 6 * * *' "$(sync_drift_precheck)" "$SYNC_DRIFT_PRECHECK_TIMEOUT" "$enabled"
    ensure_automation team-audit-weekly '0 7 * * 1' "$(team_audit_weekly_precheck)" "$TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT" "$enabled"
    ensure_automation weekly-update '0 8 * * 1' "$(weekly_update_precheck)" "$WEEKLY_UPDATE_PRECHECK_TIMEOUT" "$enabled"
    ;;
  uninstall)
    for name in $FLEET_AUTOMATION_NAMES; do
      remove_by_name "$name"
    done
    ;;
esac
