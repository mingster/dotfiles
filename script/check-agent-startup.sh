#!/usr/bin/env bash
# Verify the Antigravity (agy) startup instruction links installed from dotfiles.
# It checks only the two agy links. Claude, Grok and Orca links are not checked.
# When Antigravity is absent it checks nothing and says so on its last line.
set -euo pipefail
# shellcheck source=lib/app-path.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/app-path.sh"

# Return 0 when setup-antigravity.sh would skip (no Antigravity on this host).
antigravity_should_skip() {
  case "${OSTYPE:-}" in
    darwin*)
      if [ ! -d "$(app_path "Antigravity IDE.app")" ] \
          && [ ! -d "$HOME/Applications/Antigravity IDE.app" ] \
          && ! command -v agy >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    linux*)
      if ! command -v antigravity >/dev/null 2>&1 \
          && ! command -v antigravity-ide >/dev/null 2>&1 \
          && ! command -v agy >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    msys* | cygwin* | *)
      return 0
      ;;
  esac
}

link_physical() {
  local home=$1 target dir base
  target=$(readlink "$home")
  if [ "${target#/}" = "$target" ]; then
    dir=$(cd "$(dirname "$home")" && pwd -P)
    (cd "$dir/$target" && pwd -P)
  else
    base=$(basename "$target")
    printf '%s/%s\n' "$(cd "$(dirname "$target")" && pwd -P)" "$base"
  fi
}

check_link() { # <label> <home-path> <expected-target>
  local label=$1 home=$2 want=$3 have
  if [ ! -e "$home" ] && [ ! -L "$home" ]; then
    echo "check-agent-startup: MISSING $label ($home)" >&2
    exit 1
  fi
  if [ ! -L "$home" ]; then
    echo "check-agent-startup: WRONG $label ($home is not a symlink)" >&2
    exit 1
  fi
  if ! have=$(link_physical "$home"); then
    echo "check-agent-startup: WRONG $label ($home unreadable)" >&2
    exit 1
  fi
  want=$(cd "$(dirname "$want")" && pwd -P)/$(basename "$want")
  if [ "$have" != "$want" ]; then
    echo "check-agent-startup: WRONG $label ($home -> $have, want $want)" >&2
    exit 1
  fi
}

# Warn (never fail) when the fleet config lists remote hosts but no grok_hosts: every grok --on start is refused (#1324).
warn_empty_grok_hosts() {
  local state cfg
  state=${AGENT_STATE_DIR:-$HOME/agent-state}
  for cfg in "${FLEET_PULL_CONFIG:-}" "$state/fleet-pull.json" "$state/fleet-config.json"; do
    [ -n "$cfg" ] && [ -f "$cfg" ] || continue
    command -v jq >/dev/null 2>&1 || return 0
    if jq -e '((.hosts // []) | length > 0) and ((.grok_hosts // []) | length == 0)' "$cfg" >/dev/null 2>&1; then
      echo "check-agent-startup: WARN grok_hosts is empty in $cfg; every grok start with --on is refused (list the hosts that have the grok CLI)" >&2
    fi
    return 0
  done
}

run_check_agent_startup() {
  local dotfiles_root
  warn_empty_grok_hosts
  if antigravity_should_skip; then
    echo 'check-agent-startup: Antigravity IDE not installed; skipping agy links.'
    echo 'check-agent-startup: nothing checked (only agy links are verified, and Antigravity is not installed).'
    return 0
  fi

  DOTFILES="${DOTFILES:-$HOME/dotfiles}"
  dotfiles_root=$(cd "$DOTFILES" 2>/dev/null && pwd -P) || {
    echo 'check-agent-startup: missing dotfiles checkout' >&2
    exit 1
  }

  check_link 'agy global rule orca-agy.md' \
    "$HOME/.gemini/config/rules/orca-agy.md" \
    "$dotfiles_root/.agents/gemini/rules/orca-agy.md"
  check_link 'agy global AGENTS.md' \
    "$HOME/.gemini/config/AGENTS.md" \
    "$dotfiles_root/.agents/claude/CLAUDE.md"
  echo 'check-agent-startup: OK (2 agy links checked).'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_check_agent_startup
fi
