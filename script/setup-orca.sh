#!/usr/bin/env bash
# Orca setup: ensure presets.json and agent hooks are configured
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.orca"

if [ -f "$DOTFILES/.orca/presets.json" ]; then
  cp -f "$DOTFILES/.orca/presets.json" "$HOME/.orca/presets.json"
  echo "setup-orca: installed presets.json to $HOME/.orca/presets.json"
fi

echo "setup-orca: done"
