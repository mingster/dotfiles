#!/usr/bin/env bash
# Shared live-check dev server lock and lifecycle helper for qa-sdet verifiers.
# Takes an exclusive lock on the live-check host (waiting up to 30 minutes by
# default), reuses one running dev server on latest main when healthy, starts
# it once when down or behind origin/main, and releases the lock on exit
# without stopping the shared server.
#
# Per-host config lives in untracked script/ship.local.json under
# "live_check_server" (overlaid onto script/ship.config.example.json via
# script/apply-local-overlay.py), keyed by repo slug/name or "default":
#   "live_check_server": {
#     "<owner/repo-or-default>": {
#       "host": "<ssh-host-or-empty-for-local>",
#       "dir": "<checkout-path-on-host>",
#       "sub": "<optional-subdir>",
#       "port": 3100,
#       "url": "http://127.0.0.1:3100",
#       "start_cmd": "<dev-server-command>",
#       "state_dir": "<optional-state-dir>",
#       "wait_seconds": 1800,
#       "ready_seconds": 120
#     }
#   }
#
# Usage:
#   live-check-server.sh [options] -- <verifier-command...>
#   live-check-server.sh [options] acquire
#   live-check-server.sh [options] release
#   live-check-server.sh [options] status
#   live-check-server.sh [options] stop
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat >&2 <<'EOF'
Usage:
  live-check-server.sh [options] -- <command...>
  live-check-server.sh [options] acquire|release|status|stop

Options:
  --repo <slug>            Config key under live_check_server (default: origin repo or "default")
  --config <path>          Local config overlay path (default: script/ship.local.json)
  --host <host>            Live-check SSH host, or "local"
  --dir <path>             Shared checkout directory on the live-check host
  --sub <subdir>           Optional subdirectory inside --dir where start_cmd runs
  --port <port>            Dev server TCP port (default: 3100)
  --url <url>              Readiness URL (default: http://127.0.0.1:<port>)
  --start-cmd <cmd>        Command to start the dev server in foreground
  --state-dir <path>       Directory for lock/, server.pid, server.sha, server.log
  --wait-seconds <sec>     Lock wait limit in seconds before failing (default: 1800 = 30m)
  --poll-seconds <sec>     Lock poll interval in seconds (default: 2)
  --ready-seconds <sec>    Server readiness timeout in seconds (default: 120)
  --owner-pid <pid>        Lock holder PID for acquire (default: caller PPID)
EOF
}

die() {
  echo "live-check-server: $*" >&2
  exit 1
}

repo_key="${LIVE_CHECK_REPO:-}"
config_file="${LIVE_CHECK_CONFIG:-$script_dir/ship.local.json}"
host="${LIVE_CHECK_HOST:-}"
dir="${LIVE_CHECK_DIR:-}"
sub="${LIVE_CHECK_SUB:-}"
port="${LIVE_CHECK_PORT:-}"
url="${LIVE_CHECK_URL:-}"
start_cmd="${LIVE_CHECK_START_CMD:-}"
state_dir="${LIVE_CHECK_STATE_DIR:-}"
wait_seconds="${LIVE_CHECK_WAIT_SECONDS:-}"
poll_seconds="${LIVE_CHECK_POLL_SECONDS:-}"
ready_seconds="${LIVE_CHECK_READY_SECONDS:-}"
owner_pid=""
action=""
cmd_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo_key="${2:-}"; shift 2 ;;
    --config) config_file="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    --sub) sub="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --url) url="${2:-}"; shift 2 ;;
    --start-cmd) start_cmd="${2:-}"; shift 2 ;;
    --state-dir) state_dir="${2:-}"; shift 2 ;;
    --wait-seconds) wait_seconds="${2:-}"; shift 2 ;;
    --poll-seconds) poll_seconds="${2:-}"; shift 2 ;;
    --ready-seconds) ready_seconds="${2:-}"; shift 2 ;;
    --owner-pid) owner_pid="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    acquire|release|status|stop)
      action="$1"
      shift
      break
      ;;
    run)
      action="run"
      shift
      [ "${1:-}" = "--" ] && shift
      cmd_args=("$@")
      break
      ;;
    --)
      action="run"
      shift
      cmd_args=("$@")
      break
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$action" ] || { usage; exit 2; }
if [ "$action" = "run" ] && [ "${#cmd_args[@]}" -eq 0 ]; then
  die "run requires a command after --"
fi

detect_repo_key() {
  if [ -n "$repo_key" ]; then
    printf '%s\n' "$repo_key"
    return
  fi
  local remote=""
  remote=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$remote" ]; then
    remote="${remote%.git}"
    remote=$(printf '%s\n' "$remote" | sed -E 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')
    if [ -n "$remote" ]; then
      printf '%s\n' "$remote"
      return
    fi
  fi
  printf 'default\n'
}

load_config() {
  local key cfg
  key=$(detect_repo_key)
  cfg=$(python3 "$script_dir/apply-local-overlay.py" \
    "$script_dir/ship.config.example.json" "$config_file" 2>/dev/null || printf '{}')
  eval "$(python3 -c '
import json, shlex, sys
data, key = json.loads(sys.argv[1]), sys.argv[2]
lcs = data.get("live_check_server") or {}
entry = {}
if isinstance(lcs, dict):
    if isinstance(lcs.get("dir"), str) or isinstance(lcs.get("start_cmd"), str):
        entry = lcs
    else:
        base = key.split("/")[-1] if "/" in key else key
        entry = lcs.get(key) or lcs.get(base) or lcs.get("default") or {}
if not isinstance(entry, dict):
    entry = {}
for k in ("host", "dir", "sub", "port", "url", "start_cmd", "state_dir", "wait_seconds", "poll_seconds", "ready_seconds"):
    v = entry.get(k, "")
    if v is None:
        v = ""
    print(f"cfg_{k}={shlex.quote(str(v))}")
' "$cfg" "$key")"

  [ -n "$host" ] || host="${cfg_host:-}"
  [ -n "$dir" ] || dir="${cfg_dir:-}"
  [ -n "$sub" ] || sub="${cfg_sub:-}"
  [ -n "$port" ] || port="${cfg_port:-3100}"
  [ -n "$url" ] || url="${cfg_url:-http://127.0.0.1:${port}}"
  [ -n "$start_cmd" ] || start_cmd="${cfg_start_cmd:-}"
  [ -n "$state_dir" ] || state_dir="${cfg_state_dir:-${TMPDIR:-/tmp}/live-check-server-${port}}"
  [ -n "$wait_seconds" ] || wait_seconds="${cfg_wait_seconds:-1800}"
  [ -n "$poll_seconds" ] || poll_seconds="${cfg_poll_seconds:-2}"
  [ -n "$ready_seconds" ] || ready_seconds="${cfg_ready_seconds:-120}"
}

load_config

is_remote_host() {
  [ -n "$host" ] || return 1
  [ "$host" != "local" ] || return 1
  [ "$host" != "localhost" ] || return 1
  [ "$host" != "127.0.0.1" ] || return 1
  local here_host
  here_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')
  [ "$host" != "$here_host" ]
}

if is_remote_host; then
  remote_cmd=("~/dotfiles/script/live-check-server.sh" "--host" "local")
  [ -z "$repo_key" ] || remote_cmd+=("--repo" "$repo_key")
  [ -z "$dir" ] || remote_cmd+=("--dir" "$dir")
  [ -z "$sub" ] || remote_cmd+=("--sub" "$sub")
  [ -z "$port" ] || remote_cmd+=("--port" "$port")
  [ -z "$url" ] || remote_cmd+=("--url" "$url")
  [ -z "$start_cmd" ] || remote_cmd+=("--start-cmd" "$start_cmd")
  [ -z "$state_dir" ] || remote_cmd+=("--state-dir" "$state_dir")
  [ -z "$wait_seconds" ] || remote_cmd+=("--wait-seconds" "$wait_seconds")
  [ -z "$poll_seconds" ] || remote_cmd+=("--poll-seconds" "$poll_seconds")
  [ -z "$ready_seconds" ] || remote_cmd+=("--ready-seconds" "$ready_seconds")
  [ -z "$owner_pid" ] || remote_cmd+=("--owner-pid" "$owner_pid")
  if [ "$action" = "run" ]; then
    remote_cmd+=("--" "${cmd_args[@]}")
  else
    remote_cmd+=("$action")
  fi
  quoted=""
  for arg in "${remote_cmd[@]}"; do
    if [ "$arg" = "~/dotfiles/script/live-check-server.sh" ]; then
      quoted="\$HOME/dotfiles/script/live-check-server.sh"
    else
      quoted="$quoted $(printf '%q' "$arg")"
    fi
  done
  exec ssh "$host" "$quoted"
fi

mkdir -p "$state_dir"
lock_dir="$state_dir/lock"
pid_file="$state_dir/server.pid"
sha_file="$state_dir/server.sha"
log_file="$state_dir/server.log"
lock_held=0

release_lock() {
  if [ "$lock_held" -eq 1 ]; then
    rm -rf "$lock_dir" 2>/dev/null || true
    lock_held=0
  fi
}

acquire_lock() {
  local record_pid="${1:-$$}"
  local waited=0 holder=""
  while ! mkdir "$lock_dir" 2>/dev/null; do
    holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock_dir" 2>/dev/null || true
      continue
    fi
    if [ "$waited" -ge "$wait_seconds" ]; then
      echo "live-check-server: blocked: lock held by pid ${holder:-unknown} after ${wait_seconds}s (30m wait limit)" >&2
      exit 75
    fi
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  printf '%s\n' "$record_pid" > "$lock_dir/pid"
  lock_held=1
}

probe_url() {
  curl -fsS --max-time 2 "$url" >/dev/null 2>&1
}

server_pid_alive() {
  [ -f "$pid_file" ] || return 1
  local srv_pid
  srv_pid=$(cat "$pid_file" 2>/dev/null || true)
  [ -n "$srv_pid" ] && kill -0 "$srv_pid" 2>/dev/null
}

stop_recorded_server() {
  if [ -f "$pid_file" ]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
      local i=0
      while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.2
        i=$((i + 1))
      done
    fi
    rm -f "$pid_file"
  fi
}

resolve_target_sha() {
  [ -n "$dir" ] && [ -d "$dir/.git" -o -f "$dir/.git" ] || die "--dir must point to a git checkout (got: ${dir:-<empty>})"
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" fetch -q origin main 2>/dev/null || true
  fi
  git -C "$dir" rev-parse --verify -q refs/remotes/origin/main \
    || git -C "$dir" rev-parse --verify -q refs/heads/main \
    || git -C "$dir" rev-parse HEAD
}

start_server_once() {
  local target_sha="$1"
  local work_dir="$dir"
  [ -z "$sub" ] || work_dir="$dir/$sub"
  [ -d "$work_dir" ] || die "work_dir does not exist: $work_dir"
  [ -n "$start_cmd" ] || die "--start-cmd (or live_check_server.start_cmd) is required to start the dev server"

  stop_recorded_server
  git -C "$dir" checkout -q --detach "$target_sha"

  (
    cd "$work_dir"
    export PORT="$port" LIVE_CHECK_PORT="$port" LIVE_CHECK_URL="$url"
    nohup bash -c "$start_cmd" >"$log_file" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$pid_file"
  )
  printf '%s\n' "$target_sha" > "$sha_file"

  local elapsed=0 srv_pid
  srv_pid=$(cat "$pid_file" 2>/dev/null || true)
  while [ "$elapsed" -lt "$ready_seconds" ]; do
    if [ -n "$srv_pid" ] && ! kill -0 "$srv_pid" 2>/dev/null; then
      return 1
    fi
    if probe_url; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

ensure_server() {
  local target_sha current_sha="" srv_pid=""
  target_sha=$(resolve_target_sha)
  current_sha=$(cat "$sha_file" 2>/dev/null || true)
  if server_pid_alive && [ "$current_sha" = "$target_sha" ] && probe_url; then
    srv_pid=$(cat "$pid_file")
    echo "live-check-server: reusing server pid=$srv_pid sha=$target_sha url=$url" >&2
    return 0
  fi

  if ! start_server_once "$target_sha"; then
    echo "live-check-server: first server start failed; retrying once" >&2
    if ! start_server_once "$target_sha"; then
      stop_recorded_server
      echo "live-check-server: server failed to become ready at $url within ${ready_seconds}s" >&2
      return 1
    fi
  fi
  srv_pid=$(cat "$pid_file")
  echo "live-check-server: started server pid=$srv_pid sha=$target_sha url=$url" >&2
}

case "$action" in
  status)
    srv_pid=$(cat "$pid_file" 2>/dev/null || true)
    srv_sha=$(cat "$sha_file" 2>/dev/null || true)
    holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if server_pid_alive && probe_url; then
      printf 'status=running pid=%s sha=%s url=%s lock_holder=%s\n' "$srv_pid" "${srv_sha:-none}" "$url" "${holder:-none}"
      exit 0
    fi
    printf 'status=stopped pid=%s sha=%s url=%s lock_holder=%s\n' "${srv_pid:-none}" "${srv_sha:-none}" "$url" "${holder:-none}"
    exit 1
    ;;
  stop)
    stop_recorded_server
    rm -f "$sha_file"
    exit 0
    ;;
  release)
    rm -rf "$lock_dir" 2>/dev/null || true
    exit 0
    ;;
  acquire)
    acquire_lock "${owner_pid:-$PPID}"
    if ! ensure_server; then
      release_lock
      exit 1
    fi
    srv_pid=$(cat "$pid_file")
    srv_sha=$(cat "$sha_file")
    printf 'LIVE_CHECK_URL=%s\nLIVE_CHECK_PORT=%s\nLIVE_CHECK_SHA=%s\nLIVE_CHECK_PID=%s\n' \
      "$url" "$port" "$srv_sha" "$srv_pid"
    exit 0
    ;;
  run)
    trap 'release_lock' EXIT INT TERM
    acquire_lock "$$"
    ensure_server
    srv_pid=$(cat "$pid_file")
    srv_sha=$(cat "$sha_file")
    export LIVE_CHECK_URL="$url" LIVE_CHECK_PORT="$port" LIVE_CHECK_SHA="$srv_sha" LIVE_CHECK_PID="$srv_pid"
    "${cmd_args[@]}"
    ;;
esac
