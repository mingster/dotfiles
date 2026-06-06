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

# Global rules: ~/.cursor/rules → dotfiles/cursor/rules
mkdir -p "$DOTFILES/ide/cursor/rules"
mkdir -p "$HOME/.cursor"
ln -sfn "$DOTFILES/ide/cursor/rules" "$HOME/.cursor/rules"

# User settings + keybindings
bash "$DOTFILES/script/link-cursor-user.sh"

echo "setup-cursor: done"
