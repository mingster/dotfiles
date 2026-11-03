#!/usr/bin/env bash
# Install Cursor and wire up dotfiles config.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

# Install the Cursor app (package manager varies by OS)
case "${OSTYPE:-}" in
  darwin*)
    brew list --cask cursor >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" cursor
    ;;
  linux*)
    command -v cursor >/dev/null 2>&1 || curl https://cursor.com/install -fsS | bash
    ;;
esac

# Global rules: ~/.cursor/rules → dotfiles/ide/cursor/rules
mkdir -p "$DOTFILES/ide/cursor/rules"
mkdir -p "$HOME/.cursor"
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
