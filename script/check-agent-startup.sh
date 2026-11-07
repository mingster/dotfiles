#!/usr/bin/env bash
# Verify agent startup instruction links installed from dotfiles.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
dotfiles_root=$(cd "$DOTFILES" 2>/dev/null && pwd -P) || {
  echo 'check-agent-startup: missing dotfiles checkout' >&2
  exit 1
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
  have=$(readlink "$home") || {
    echo "check-agent-startup: WRONG $label ($home unreadable)" >&2
    exit 1
  }
  if [ "$have" != "$want" ]; then
    echo "check-agent-startup: WRONG $label ($home -> $have, want $want)" >&2
    exit 1
  fi
}

check_link 'agy global rule orca-agy.md' \
  "$HOME/.gemini/config/rules/orca-agy.md" \
  "$dotfiles_root/.agents/gemini/rules/orca-agy.md"
check_link 'agy global AGENTS.md' \
  "$HOME/.gemini/config/AGENTS.md" \
  "$dotfiles_root/.agents/claude/CLAUDE.md"
