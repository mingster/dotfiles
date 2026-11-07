#!/usr/bin/env bash
# Verify agent startup instruction links installed from dotfiles.
set -euo pipefail

# Return 0 when setup-antigravity.sh would skip (no Antigravity on this host).
antigravity_should_skip() {
  case "${OSTYPE:-}" in
    darwin*)
      if [ ! -d "/Applications/Antigravity IDE.app" ] \
          && [ ! -d "/Applications/_dev/Antigravity IDE.app" ] \
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

run_check_agent_startup() {
  local dotfiles_root
  if antigravity_should_skip; then
    echo 'check-agent-startup: Antigravity IDE not installed; skipping agy links.'
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_check_agent_startup
fi
