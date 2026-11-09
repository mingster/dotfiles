#!/usr/bin/env bash
# Session start: fast-forward the main checkout of the project and of ~/dotfiles when it is on main,
# clean and behind origin/main, then name local tools below the fleet floor
# ($AGENT_STATE_DIR/fleet-floor.json, written daily on the coordinator by fleet-toolchain-check.sh).
# Never touches a dirty or diverged checkout or a worktree branch, and always exits 0.
# Usage: session-sync.sh [<project dir>]
# Tests: SESSION_SYNC_PROBE (tool probe script), SESSION_SYNC_FETCH_TIMEOUT (seconds, default 5).
set -u
here=$(cd "$(dirname "$0")" && pwd)
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
fetch_timeout=${SESSION_SYNC_FETCH_TIMEOUT:-5}
export GIT_TERMINAL_PROMPT=0

common_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

fetch_main() { # <dir>: fetch origin, giving up after the timeout so an offline host does not stall the session
  local pid n=0 batch=()
  # Never prompt over ssh, unless the user or repo already chose their own ssh command
  if [ -z "${GIT_SSH_COMMAND:-}" ] && ! git -C "$1" config core.sshCommand >/dev/null 2>&1; then
    batch=(-c "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=$fetch_timeout")
  fi
  git ${batch[@]+"${batch[@]}"} -C "$1" fetch -q origin main >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt $((fetch_timeout * 10)) ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 0.1
  done
  wait "$pid"
}

sync_main() { # <dir inside a checkout>
  local common d label behind ahead
  common=$(common_of "$1") || return 0
  d=$(dirname "$common")
  [ -e "$d/.git" ] || return 0
  label=$(basename "$d")
  [ "$(git -C "$d" branch --show-current 2>/dev/null)" = main ] || return 0
  if ! fetch_main "$d"; then
    echo "session-sync: $label fetch failed, skipped"
    return 0
  fi
  behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  [ "$behind" != 0 ] || return 0
  ahead=$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  if [ "$ahead" != 0 ]; then
    echo "session-sync: $label has diverged from origin/main, left alone"
  elif [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "session-sync: $label is $behind behind origin/main but dirty, left alone"
  elif git -C "$d" merge --ff-only -q origin/main >/dev/null 2>&1; then
    echo "session-sync: $label fast-forwarded $behind commit$([ "$behind" = 1 ] || echo s) to $(git -C "$d" rev-parse --short HEAD)"
  else
    echo "session-sync: $label fast-forward failed, left alone"
  fi
}

check_floor() {
  local floor="$state_dir/fleet-floor.json" host probe t want st have
  [ -f "$floor" ] && command -v jq >/dev/null 2>&1 || return 0
  host=$(jq -r '.host // "coordinator"' "$floor" 2>/dev/null) || return 0
  probe=$(bash "${SESSION_SYNC_PROBE:-$here/lib/toolchain-probe.sh}" 2>/dev/null)
  while read -r t want; do
    [ -n "$t" ] || continue
    st=$(awk -v t="$t" '$1 == t { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$probe")
    case "$st" in
      ok\ *)
        have=${st#ok }
        if older "$have" "$want"; then echo "session-sync: $t $have is below $host $want"; fi
        ;;
      missing) echo "session-sync: $t missing ($host has $want)" ;;
    esac
  done < <(jq -r '.tools // {} | to_entries[] | "\(.key) \(.value)"' "$floor" 2>/dev/null)
}

project=${1:-${CLAUDE_PROJECT_DIR:-$PWD}}
sync_main "$project"
dotfiles=${DOTFILES_DIR:-$HOME/dotfiles}
# Skip ~/dotfiles when the project is the dotfiles repo itself
if [ -d "$dotfiles" ] && [ "$(common_of "$dotfiles")" != "$(common_of "$project")" ]; then
  sync_main "$dotfiles"
fi
check_floor
exit 0
