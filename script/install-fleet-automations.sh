#!/usr/bin/env bash
# Install Orca automations: fleet-watch (5 min), wrap-up-scheduled (10 min), sync drift (daily),
# team-audit-weekly and weekly-update (Monday). wrap-up-scheduled is enabled on every Orca host;
# the rest are enabled only on the coordinator in agent-state/coordinator.conf.
# Private paths: env vars or ~/.config/fleet-watch/automations.env (no secrets in this repo).
#
# Usage: install-fleet-automations.sh --status
#        install-fleet-automations.sh [--dry-run] --install
#        install-fleet-automations.sh --uninstall
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/automation-path.sh
. "$here/lib/automation-path.sh"

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

DOTFILES_DIR=${DOTFILES_DIR:-$HOME/dotfiles}
if [ -d "$DOTFILES_DIR" ]; then
  DOTFILES_DIR=$(cd "$DOTFILES_DIR" && pwd -P)
fi
if [ ! -f "$DOTFILES_DIR/script/fleet-watch.py" ]; then
  echo "install-fleet-automations: missing $DOTFILES_DIR/script/fleet-watch.py" >&2
  exit 1
fi
orca_app_bin=${FLEET_ORCA_APP_BIN:-/Applications/_dev/Orca.app/Contents/Resources/bin}
resolve_orca_cli() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    command -v "$ORCA_CLI_COMMAND" >/dev/null 2>&1 || return 1
    printf '%s\n' "$ORCA_CLI_COMMAND"
    return 0
  fi
  if [ -x "$orca_app_bin/orca" ]; then
    printf '%s\n' "$orca_app_bin/orca"
    return 0
  fi
  if [ -z "${FLEET_ORCA_APP_BIN+x}" ] && command -v orca >/dev/null 2>&1; then
    command -v orca
    return 0
  fi
  if [ -z "${FLEET_ORCA_APP_BIN+x}" ] && [ -x "$HOME/.local/bin/orca" ]; then
    printf '%s\n' "$HOME/.local/bin/orca"
    return 0
  fi
  return 1
}
if ! orca_cli=$(resolve_orca_cli); then
  echo "install-fleet-automations: skip: Orca app not installed on $(uname -n)"
  exit 0
fi
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
# Scheduled config: repo_roots, host_caps, and per-host monitor paths.
# ~/.config/fleet-watch/config.json is not the scheduled config.
FLEET_WATCH_CONFIG=${FLEET_WATCH_CONFIG:-$HOME/.claude/state/fleet-watch-elon.json}
FLEET_WATCH_STATE=${FLEET_WATCH_STATE:-$HOME/.local/state/agent-team/fleet-watch.state.json}
FLEET_WATCH_AUTOMATION_LOG=${FLEET_WATCH_AUTOMATION_LOG:-$HOME/.orca/logs/fleet-watch.log}
FLEET_WATCH_PRECHECK_LOG=${FLEET_WATCH_PRECHECK_LOG:-$FLEET_WATCH_AUTOMATION_LOG}
FLEET_AUTOMATIONS_TIMEZONE=${FLEET_AUTOMATIONS_TIMEZONE:-${TZ:-}}
FLEET_AUTOMATIONS_PROVIDER=${FLEET_AUTOMATIONS_PROVIDER:-claude}
AUTOMATION_PROMPT=${FLEET_AUTOMATIONS_PROMPT:-'Script only job, the precheck always stops it.'}
FLEET_WATCH_PRECHECK_TIMEOUT=${FLEET_WATCH_PRECHECK_TIMEOUT:-280}
WRAP_UP_SCHEDULED_REPO_LIMIT=${WRAP_UP_SCHEDULED_REPO_LIMIT:-300}
WRAP_UP_PRECHECK_TIMEOUT=${WRAP_UP_PRECHECK_TIMEOUT:-600}
WRAP_UP_SCHEDULED_LOG=${WRAP_UP_SCHEDULED_LOG:-$HOME/.orca/logs/wrap-up-scheduled.log}
# Issue 855: failed rounds open an issue on the private fleet state repo. wrap-up.sh refuses a public one, since titles name hosts.
WRAP_UP_ISSUE_REPO=${WRAP_UP_ISSUE_REPO:-mingster/agent-state}
SYNC_DRIFT_LOG=${SYNC_DRIFT_LOG:-$HOME/.local/state/agent-team/sync-team-skills-drift.log}
TEAM_AUDIT_WEEKLY_LOG=${TEAM_AUDIT_WEEKLY_LOG:-$HOME/.local/state/agent-team/team-audit-weekly.log}
SYNC_DRIFT_PRECHECK_TIMEOUT=${SYNC_DRIFT_PRECHECK_TIMEOUT:-300}
TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT=${TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT:-600}
WEEKLY_UPDATE_LOG=${WEEKLY_UPDATE_LOG:-$HOME/.local/state/agent-team/weekly-update.log}
WEEKLY_UPDATE_PRECHECK_TIMEOUT=${WEEKLY_UPDATE_PRECHECK_TIMEOUT:-600}  # Orca caps a precheck at 600 s
FLEET_TOOLCHAIN_LOG=${FLEET_TOOLCHAIN_LOG:-$HOME/.local/state/agent-team/fleet-toolchain.log}
FLEET_TOOLCHAIN_PRECHECK_TIMEOUT=${FLEET_TOOLCHAIN_PRECHECK_TIMEOUT:-600}
STAGING_DAILY_LOG=${STAGING_DAILY_LOG:-$HOME/.local/state/agent-team/staging-daily.log}
STAGING_DAILY_PRECHECK_TIMEOUT=${STAGING_DAILY_PRECHECK_TIMEOUT:-300}
FLEET_STAGING_DAILY_TIMEZONE=${FLEET_STAGING_DAILY_TIMEZONE:-Asia/Taipei}
FLEET_AUTOMATION_NAMES='fleet-watch wrap-up-scheduled sync-team-skills-drift team-audit-weekly weekly-update fleet-toolchain daily-program-1900'

precheck_path() {
  automation_tool_path
}

coordinator_name() {
  local conf want
  if [ ! -f "$state_dir/coordinator.conf" ]; then
    echo "install-fleet-automations: missing $state_dir/coordinator.conf" >&2
    return 1
  fi
  conf=$(cat "$state_dir/coordinator.conf" 2>/dev/null || true)
  want=$(printf '%s\n' "$conf" | awk '$1 == "coordinator" { print $2; exit }' | tr '[:upper:]' '[:lower:]')
  if [ -z "$want" ]; then
    echo "install-fleet-automations: missing coordinator in $state_dir/coordinator.conf" >&2
    return 1
  fi
  printf '%s' "$want"
}

host_is_coordinator() {
  local me want
  me=$(hostname -s | tr '[:upper:]' '[:lower:]')
  want=$1
  [ -n "$want" ] && [ "$me" = "$want" ]
}

automation_wrap() {
  local name=$1 log=$2
  shift 2
  local path shell_pw log_pw
  path=$(precheck_path)
  shell_pw=$(printf '%s' "$path" | sed "s/'/'\\\\''/g")
  log_pw=$(printf '%s' "$log" | sed "s/'/'\\\\''/g")
  printf "PATH='%s' bash '%s/script/automation-precheck-wrapper.sh' '%s' '%s' --" \
    "$shell_pw" "$DOTFILES_DIR" "$name" "$log_pw"
  while [ $# -gt 0 ]; do
    printf ' %q' "$1"
    shift
  done
  printf '; exit 1'
}

fleet_watch_precheck() {
  automation_wrap fleet-watch "$FLEET_WATCH_AUTOMATION_LOG" \
    env "FLEET_WATCH_LOG_PATH=$FLEET_WATCH_AUTOMATION_LOG" \
    python3 "$DOTFILES_DIR/script/fleet-watch.py" --config "$FLEET_WATCH_CONFIG" --state "$FLEET_WATCH_STATE"
}

wrap_up_precheck() {
  local env_args=(
    "WRAP_UP_SCHEDULED_LOG=$WRAP_UP_SCHEDULED_LOG"
    "WRAP_UP_SCHEDULED_REPO_LIMIT=$WRAP_UP_SCHEDULED_REPO_LIMIT"
    "WRAP_UP_PRECHECK_TIMEOUT=$WRAP_UP_PRECHECK_TIMEOUT"
  )
  [ -n "$WRAP_UP_ISSUE_REPO" ] && env_args+=("WRAP_UP_ISSUE_REPO=$WRAP_UP_ISSUE_REPO")
  automation_wrap wrap-up-scheduled "$WRAP_UP_SCHEDULED_LOG" \
    env "${env_args[@]}" \
    bash "$DOTFILES_DIR/script/wrap-up.sh" --scheduled
}

sync_drift_precheck() {
  automation_wrap sync-team-skills-drift "$SYNC_DRIFT_LOG" \
    env "DOTFILES=$DOTFILES_DIR" "SYNC_DRIFT_LOG=$SYNC_DRIFT_LOG" bash "$DOTFILES_DIR/script/automation-precheck-sync-drift.sh"
}

team_audit_weekly_precheck() {
  automation_wrap team-audit-weekly "$TEAM_AUDIT_WEEKLY_LOG" \
    env "DOTFILES=$DOTFILES_DIR" "TEAM_AUDIT_WEEKLY_LOG=$TEAM_AUDIT_WEEKLY_LOG" bash "$DOTFILES_DIR/script/automation-precheck-team-audit-weekly.sh"
}

weekly_update_precheck() {
  automation_wrap weekly-update "$WEEKLY_UPDATE_LOG" \
    env "DOTFILES=$DOTFILES_DIR" "WEEKLY_UPDATE_LOG=$WEEKLY_UPDATE_LOG" bash "$DOTFILES_DIR/script/automation-precheck-weekly-update.sh"
}

fleet_toolchain_precheck() {
  automation_wrap fleet-toolchain "$FLEET_TOOLCHAIN_LOG" \
    env "DOTFILES_DIR=$DOTFILES_DIR" "AGENT_STATE_DIR=$state_dir" \
    bash -c "rc=0; bash '$DOTFILES_DIR/script/fleet-pull.sh' || rc=\$?; bash '$DOTFILES_DIR/script/fleet-toolchain-check.sh' --apply || rc=\$?; exit \$rc"
}

staging_daily_precheck() {
  local env_args=(
    "DOTFILES=$DOTFILES_DIR"
    "AGENT_STATE_DIR=$state_dir"
    "FLEET_WATCH_CONFIG=$FLEET_WATCH_CONFIG"
    "STAGING_DAILY_LOG=$STAGING_DAILY_LOG"
  )
  [ -n "${FLEET_STAGING_REPOS:-}" ] && env_args+=("FLEET_STAGING_REPOS=$FLEET_STAGING_REPOS")
  automation_wrap daily-program-1900 "$STAGING_DAILY_LOG" \
    env "${env_args[@]}" \
    bash "$DOTFILES_DIR/script/automation-precheck-staging-daily.sh"
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
  local out rc=0
  out=$(run_orca_with_timezone "$@" --json) || rc=$?
  printf '%s\n' "$out" >"$orca_json_sink"
  [ "$rc" -eq 0 ] || echo "install-fleet-automations: orca $2 $3 failed: $out" >&2
  return "$rc"
}

# Orca matches path: selectors as strings, so a repo registered under a
# symlink is missed. Prefer the id of the repo whose real path is dotfiles.
dotfiles_repo_selector() {
  { "$orca_cli" repo list --json 2>/dev/null || true; } | WANT="$DOTFILES_DIR" python3 -c '
import json, os, sys
s = sys.stdin.read()
try:
    repos = json.loads(s[s.find("{"):s.rfind("}") + 1])["result"]["repos"]
except Exception:
    repos = []
for r in repos:
    if r.get("path") and os.path.realpath(r["path"]) == os.environ["WANT"]:
        print("id:" + r["id"])
        sys.exit(0)
print("path:" + os.environ["WANT"])
'
}

ensure_automation() {
  local name=$1 trigger=$2 precheck=$3 timeout=$4 enabled=$5 tz=${6:-$FLEET_AUTOMATIONS_TIMEZONE}
  local existing id
  if existing=$(automation_by_name "$name" 2>/dev/null); then
    id=$(AUTOMATION_ROW="$existing" python3 - <<'PY'
import json, os
print(json.loads(os.environ["AUTOMATION_ROW"])["id"])
PY
)
    if AUTOMATION_ROW="$existing" AUTOMATION_WANT_TRIGGER="$trigger" \
      AUTOMATION_WANT_PRECHECK="$precheck" AUTOMATION_WANT_TIMEOUT="$timeout" \
      AUTOMATION_WANT_ENABLED="$enabled" AUTOMATION_WANT_TIMEZONE="$tz" python3 - <<'PY'
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
want_tz = os.environ.get("AUTOMATION_WANT_TIMEZONE") or ""
if want_tz and (cur.get("timezone") or "") != want_tz:
    raise SystemExit(1)
PY
    then
      echo "install-fleet-automations: $name unchanged (${id})"
      return 0
    fi
    if [ "$enabled" = 1 ]; then
      FLEET_AUTOMATIONS_TIMEZONE="$tz" run_orca_json "$orca_cli" automations edit "$id" \
        --trigger "$trigger" \
        --precheck "$precheck" \
        --precheck-timeout "$timeout" \
        --enabled
    else
      FLEET_AUTOMATIONS_TIMEZONE="$tz" run_orca_json "$orca_cli" automations edit "$id" \
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
    FLEET_AUTOMATIONS_TIMEZONE="$tz" run_orca_json "$orca_cli" automations create \
      --name "$name" \
      --trigger "$trigger" \
      --prompt "$AUTOMATION_PROMPT" \
      --provider "$FLEET_AUTOMATIONS_PROVIDER" \
      --repo "$repo_selector" \
      --setup skip \
      --precheck "$precheck" \
      --precheck-timeout "$timeout" \
      --enabled
  else
    FLEET_AUTOMATIONS_TIMEZONE="$tz" run_orca_json "$orca_cli" automations create \
      --name "$name" \
      --trigger "$trigger" \
      --prompt "$AUTOMATION_PROMPT" \
      --provider "$FLEET_AUTOMATIONS_PROVIDER" \
      --repo "$repo_selector" \
      --setup skip \
      --precheck "$precheck" \
      --precheck-timeout "$timeout" \
      --disabled
  fi
  if [ "$dry" = 1 ]; then
    echo "install-fleet-automations: would create $name ($trigger${tz:+ $tz})"
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
    coord_want=$(coordinator_name) || exit 1
    enabled=0
    host_is_coordinator "$coord_want" && enabled=1
    repo_selector=$(dotfiles_repo_selector)
    ensure_automation fleet-watch '*/5 * * * *' "$(fleet_watch_precheck)" "$FLEET_WATCH_PRECHECK_TIMEOUT" "$enabled"
    ensure_automation wrap-up-scheduled '*/10 * * * *' "$(wrap_up_precheck)" "$WRAP_UP_PRECHECK_TIMEOUT" 1
    # The owner turns these three on by hand; the installer only creates them disabled.
    ensure_automation sync-team-skills-drift '0 6 * * *' "$(sync_drift_precheck)" "$SYNC_DRIFT_PRECHECK_TIMEOUT" 0
    ensure_automation team-audit-weekly '0 7 * * 1' "$(team_audit_weekly_precheck)" "$TEAM_AUDIT_WEEKLY_PRECHECK_TIMEOUT" 0
    ensure_automation weekly-update '0 8 * * 1' "$(weekly_update_precheck)" "$WEEKLY_UPDATE_PRECHECK_TIMEOUT" 0
    ensure_automation fleet-toolchain '0 5 * * *' "$(fleet_toolchain_precheck)" "$FLEET_TOOLCHAIN_PRECHECK_TIMEOUT" "$enabled"
    # Renamed from staging-daily-1900 (#834); drop the old entry when a host still has it.
    automation_by_name staging-daily-1900 >/dev/null 2>&1 && remove_by_name staging-daily-1900
    ensure_automation daily-program-1900 '0 19 * * *' "$(staging_daily_precheck)" "$STAGING_DAILY_PRECHECK_TIMEOUT" "$enabled" "$FLEET_STAGING_DAILY_TIMEZONE"
    ;;
  uninstall)
    for name in $FLEET_AUTOMATION_NAMES; do
      remove_by_name "$name"
    done
    ;;
esac
