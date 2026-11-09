#!/usr/bin/env bash
# Fast-forward the main checkout of the state dir and each configured repo on this host and every fleet host.
# Reads config from $AGENT_STATE_DIR/{fleet-pull.json,fleet-config.json} (default ~/agent-state),
# falling back to script/fleet-pull.config.json only if that is missing.
# Exits non-zero and names the host and repo for a dirty, behind-after-pull, diverged or unreachable checkout.
set -u
here=$(cd "$(dirname "$0")" && pwd)
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
command -v jq >/dev/null || { echo 'fleet-pull requires jq' >&2; exit 1; }

# shellcheck disable=SC2016
remote='
host_label=$1
agent_host=$2
shift 2
rc=0
# Role files and session-start.md are rendered copies, so only agent-team.sh machine refreshes them
render_team() {
  [ -f "$1/script/agent-team.sh" ] || return 0
  DOTFILES="$1" bash "$1/script/agent-team.sh" machine >/dev/null 2>&1 && return 0
  echo "fail $host_label $raw (agent-team.sh machine failed)"
  rc=1
}
for raw in "$@"; do
  d=${raw/#\~/$HOME}
  if [ ! -e "$d/.git" ]; then
    echo "fail $host_label $raw (unreachable checkout: missing $d)"
    rc=1
    continue
  fi
  if [ "$agent_host" = 1 ] && [ "$d" != "$HOME/agent-state" ]; then
    if ! git -C "$d" fetch -q origin 2>/dev/null; then
      echo "fail $host_label $raw (unreachable origin on fetch)"
      rc=1
      continue
    fi
    b=$(git -C "$d" branch --show-current 2>/dev/null || true)
    dirty=$(git -C "$d" status --porcelain 2>/dev/null || true)
    ahead=$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    reset_note=""
    if [ "$b" != main ] || [ -n "$dirty" ] || [ "${ahead:-0}" != 0 ]; then
      reset_note=" (reset)"
    fi
    if ! (git -C "$d" checkout -f -q main 2>/dev/null || git -C "$d" checkout -f -q -b main origin/main 2>/dev/null) \
      || ! git -C "$d" reset -q --hard origin/main >/dev/null 2>&1 \
      || ! git -C "$d" clean -fd -q >/dev/null 2>&1; then
      echo "fail $host_label $raw (reset to origin/main failed)"
      rc=1
      continue
    fi
    echo "ok   $host_label $d $(git -C "$d" rev-parse --short HEAD)$reset_note"
    render_team "$d"
    continue
  fi
  b=$(git -C "$d" branch --show-current 2>/dev/null || true)
  if [ "$b" != main ]; then
    echo "fail $host_label $raw (not on main: ${b:-detached})"
    rc=1
    continue
  fi
  if [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "fail $host_label $raw (dirty)"
    rc=1
    continue
  fi
  if ! git -C "$d" fetch -q origin 2>/dev/null; then
    echo "fail $host_label $raw (unreachable origin on fetch)"
    rc=1
    continue
  fi
  if ! git -C "$d" merge --ff-only -q origin/main >/dev/null 2>&1; then
    echo "fail $host_label $raw (diverged: not fast-forward)"
    rc=1
    continue
  fi
  behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 1)
  if [ "${behind:-1}" != 0 ]; then
    echo "fail $host_label $raw (behind after pull: $behind commits behind origin/main)"
    rc=1
    continue
  fi
  echo "ok   $host_label $d $(git -C "$d" rev-parse --short HEAD)"
  if [ -f "$d/script/setup-claude-code.sh" ] && [ -f "$d/script/setup-agent-skills.sh" ]; then
    DOTFILES="$d"
    export DOTFILES
    if ! bash "$DOTFILES/script/setup-claude-code.sh" --keep-settings >/dev/null 2>&1 ||
       ! bash "$DOTFILES/script/setup-agent-skills.sh" >/dev/null 2>&1; then
      echo "fail $host_label $raw (user-level link refresh failed)"
      rc=1
      continue
    fi
    render_team "$d"
  fi
done
exit "$rc"
'

status=0
echo "local"
if [ -e "$state_dir/.git" ]; then
  bash -c "$remote" _ local 0 "$state_dir" || status=1
fi

resolve_fleet_pull_config() {
  if [ -n "${FLEET_PULL_CONFIG:-}" ]; then
    printf '%s\n' "$FLEET_PULL_CONFIG"
    return
  fi
  if [ -f "$state_dir/fleet-pull.json" ]; then
    printf '%s\n' "$state_dir/fleet-pull.json"
    return
  fi
  if [ -f "$state_dir/fleet-config.json" ] && jq -e 'has("repos") or has("hosts") or has("agent_hosts")' "$state_dir/fleet-config.json" >/dev/null 2>&1; then
    printf '%s\n' "$state_dir/fleet-config.json"
    return
  fi
  if [ -f "$here/fleet-pull.config.json" ]; then
    printf '%s\n' "$here/fleet-pull.config.json"
    return
  fi
  if [ -f "$state_dir/fleet-config.json" ]; then
    printf '%s\n' "$state_dir/fleet-config.json"
    return
  fi
  printf '%s\n' "$here/fleet-pull.config.json"
}

cfg=$(resolve_fleet_pull_config)
[ -f "$cfg" ] || { echo "missing $cfg (copy fleet-pull.config.example.json)" >&2; exit 1; }

repos=()
while IFS= read -r r; do
  [ -n "$r" ] && repos+=("$r")
done < <(jq -r '(.repos // [])[]' "$cfg")

agent_hosts=()
while IFS= read -r ah; do
  [ -n "$ah" ] && agent_hosts+=("$ah")
done < <(jq -r '(.agent_hosts // [])[]' "$cfg")

is_agent_host() {
  local target=$1 ah
  for ah in ${agent_hosts[@]+"${agent_hosts[@]}"}; do
    [ "$ah" = "$target" ] && return 0
  done
  return 1
}

local_agent=0
is_agent_host local && local_agent=1
if [ "${#repos[@]}" -gt 0 ]; then
  bash -c "$remote" _ local "$local_agent" "${repos[@]}" || status=1
fi

# The remote shell expands ~, so each host pulls its own state dir.
# shellcheck disable=SC2088
remote_state='~/agent-state'
for h in $(jq -r '(.hosts // [])[]' "$cfg"); do
  [ -n "$h" ] || continue
  echo "$h"
  agent_flag=0
  is_agent_host "$h" && agent_flag=1
  rc=0
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" bash -s -- "$h" "$agent_flag" "$remote_state" ${repos[@]+"${repos[@]}"} <<<"$remote" 2>&1) || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || status=1
  # ssh exits 255 when it cannot reach the host; any other failure already named its repo.
  if [ "$rc" -eq 255 ]; then
    for r in "$remote_state" ${repos[@]+"${repos[@]}"}; do echo "fail $h $r (unreachable host)"; done
  fi
done

# Then push the secrets folder to the same hosts (skipped without script/secrets-sync.config.json).
if [ -x "$here/secrets-sync.sh" ]; then
   "$here/secrets-sync.sh" || status=1
fi
exit "$status"
