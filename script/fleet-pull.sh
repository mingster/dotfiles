#!/usr/bin/env bash
# Fast-forward the main checkout of the state dir and each configured repo on this host and every fleet host.
# Reads config from $AGENT_STATE_DIR/{fleet-pull.json,fleet-config.json} (default ~/agent-state),
# falling back to script/fleet-pull.config.json only if that is missing.
# Exits non-zero and names the host and repo for a dirty, behind-after-pull, diverged or unreachable checkout.
set -u
usage() {
  cat <<'USAGE'
Usage: fleet-pull.sh [--fix-display] [--help]
Pulls the state dir and each configured repo on this host and every fleet host.
An agent host checkout is reset hard to origin/main. There is no dry run mode.
--fix-display  Before the display check, set the four Claude display keys to the fleet value in
               ~/.claude/settings.json and every Orca profile settings.json (python3, atomic, symlinks skipped).
USAGE
}
fix_display=0
case "${1:-}" in
  '') ;;
  --fix-display) fix_display=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "fleet-pull: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "fleet-pull: unexpected arguments: $*" >&2; usage >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
command -v jq >/dev/null || { echo 'fleet-pull requires jq' >&2; exit 1; }

# shellcheck disable=SC2016
remote='
# A non-login ssh has a bare PATH, so add both Homebrew prefixes (Apple silicon, Intel) to find jq (#1648)
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
host_label=$1
agent_host=$2
fix_display=$3
shift 3
rc=0
# Role files and session-start.md are rendered copies, so only agent-team.sh machine refreshes them
render_team() {
  local out
  [ -f "$1/script/agent-team.sh" ] || return 0
  out=$(DOTFILES="$1" bash "$1/script/agent-team.sh" machine 2>&1) && return 0
  echo "fail $host_label $2 (agent-team.sh machine failed: $(printf "%s\n" "$out" | tail -n 1))"
  rc=1
}
# A hook left in ~/.claude/settings.json that points at a removed dotfiles script prints an error every session (#1416)
check_hooks() {
  local out
  [ -f "$1/script/check-hook-paths.sh" ] && [ -f "$HOME/.claude/settings.json" ] || return 0
  out=$(bash "$1/script/check-hook-paths.sh" "$HOME/.claude/settings.json" 2>&1) && return 0
  printf "%s\n" "$out" | while IFS= read -r line; do echo "fail $host_label $2 ($line)"; done
  rc=1
}
# The four Claude display keys must match on every host and Orca profile, or the subagent list differs per machine (#1409)
check_display() {
  local f out
  [ -f "$1/script/check-display-settings.sh" ] || return 0
  for f in "$HOME/.claude/settings.json" "$HOME"/Library/Application\ Support/orca/claude-profiles/*/home/settings.json; do
    [ -f "$f" ] || continue
    # With --fix-display, fix first. A symlink is skipped and invalid JSON is left alone, so the check below still reports them (#1682)
    if [ "$fix_display" = 1 ] && [ -f "$1/script/fix-display-settings.sh" ]; then
      out=$(bash "$1/script/fix-display-settings.sh" "$f" 2>&1) || true
      case "$out" in "fixed "*) echo "fix  $host_label $2 (display keys set in ${f#"$HOME"/})" ;; esac
    fi
    out=$(bash "$1/script/check-display-settings.sh" "$f" 2>&1) && continue
    printf "%s\n" "$out" | while IFS= read -r line; do echo "fail $host_label $2 ($line in ${f#"$HOME"/})"; done
    rc=1
  done
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
    render_team "$d" "$raw"
    check_hooks "$d" "$raw"
    check_display "$d" "$raw"
    continue
  fi
  b=$(git -C "$d" branch --show-current 2>/dev/null || true)
  if [ -z "$b" ]; then
    # A detached HEAD on origin/main history with a clean tree goes back to main. Local commits or a dirty tree stay a fail (#1683)
    if ! git -C "$d" fetch -q origin 2>/dev/null; then
      echo "fail $host_label $raw (unreachable origin on fetch)"
      rc=1
      continue
    fi
    if [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      echo "fail $host_label $raw (not on main: detached and dirty)"
      rc=1
      continue
    fi
    if ! git -C "$d" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
      echo "fail $host_label $raw (not on main: detached, HEAD is not on origin/main)"
      rc=1
      continue
    fi
    if git -C "$d" rev-parse -q --verify refs/heads/main >/dev/null \
      && ! git -C "$d" merge-base --is-ancestor main origin/main 2>/dev/null; then
      echo "fail $host_label $raw (not on main: detached, local main has commits not on origin/main)"
      rc=1
      continue
    fi
    if ! git -C "$d" checkout -q -B main HEAD >/dev/null 2>&1; then
      echo "fail $host_label $raw (not on main: detached, switch to main failed)"
      rc=1
      continue
    fi
    echo "fix  $host_label $raw (detached HEAD on origin/main history, switched to main)"
    b=main
  fi
  if [ "$b" != main ]; then
    echo "fail $host_label $raw (not on main: $b)"
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
    render_team "$d" "$raw"
    check_hooks "$d" "$raw"
    check_display "$d" "$raw"
  fi
done
exit "$rc"
'

status=0
echo "local"
if [ -e "$state_dir/.git" ]; then
  bash -c "$remote" _ local 0 "$fix_display" "$state_dir" || status=1
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
  bash -c "$remote" _ local "$local_agent" "$fix_display" "${repos[@]}" || status=1
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
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" bash -s -- "$h" "$agent_flag" "$fix_display" "$remote_state" ${repos[@]+"${repos[@]}"} <<<"$remote" 2>&1) || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || status=1
  # ssh exits 255 when it cannot reach the host; any other failure already named its repo.
  if [ "$rc" -eq 255 ]; then
    for r in "$remote_state" ${repos[@]+"${repos[@]}"}; do echo "fail $h $r (unreachable host)"; done
  fi
done

# Then push the secrets folder to the same hosts (skipped when the gate at /opt/secrets-gate/secrets-gate, or $SECRETS_GATE, is not installed).
if [ -x "$here/secrets-sync.sh" ]; then
   "$here/secrets-sync.sh" || status=1
fi
exit "$status"
