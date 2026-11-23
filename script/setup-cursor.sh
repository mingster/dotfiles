#!/usr/bin/env bash
# Install Cursor and wire up dotfiles config.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1568).
if [ $# -gt 0 ]; then
  echo "Usage: setup-cursor.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-cursor "$DOTFILES"

# Install the Cursor app (package manager varies by OS)
case "${OSTYPE:-}" in
  darwin*)
    brew list --cask cursor >/dev/null 2>&1 || brew install --cask cursor
    ;;
  linux*)
    command -v cursor >/dev/null 2>&1 || curl https://cursor.com/install -fsS | bash
    ;;
esac

# Global rules: ~/.cursor/rules → dotfiles/ide/cursor/rules
mkdir -p "$DOTFILES/ide/cursor/rules"
mkdir -p "$HOME/.cursor"
# A real folder is moved aside first: ln -sfn would nest the link inside it and the rules would never load.
if [ -d "$HOME/.cursor/rules" ] && [ ! -L "$HOME/.cursor/rules" ]; then
  rules_bak="$HOME/.cursor/rules.bak-$(date +%Y%m%d%H%M%S)"
  mv "$HOME/.cursor/rules" "$rules_bak"
  echo "setup-cursor: backed up existing ~/.cursor/rules to $rules_bak"
fi
ln -sfn "$DOTFILES/ide/cursor/rules" "$HOME/.cursor/rules"

# User settings + keybindings
bash "$DOTFILES/script/link-cursor-user.sh"

# Global hooks (~/.cursor/hooks.json)
bash "$DOTFILES/script/link-cursor-hooks.sh"

# CLI configuration (~/.cursor/cli-config.json) with full permissions
if [ -f "$DOTFILES/ide/cursor/cli-config.json" ]; then
  # Keep authInfo: a plain copy erased the cursor-agent login on every run.
  cfg="$HOME/.cursor/cli-config.json"
  tmp="$(mktemp)"
  if [ -f "$cfg" ] && jq -e 'has("authInfo")' "$cfg" >/dev/null 2>&1; then
    jq -s '.[0] + {authInfo: .[1].authInfo}' "$DOTFILES/ide/cursor/cli-config.json" "$cfg" > "$tmp"
  else
    cp "$DOTFILES/ide/cursor/cli-config.json" "$tmp"
  fi
  mv -f "$tmp" "$cfg"
fi

echo "setup-cursor: done"
