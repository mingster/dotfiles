#!/usr/bin/env bash
# Orca setup: ensure presets.json and agent hooks are configured
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.orca"

src="$DOTFILES/.orca/presets.json"
dest="$HOME/.orca/presets.json"
if [ -f "$src" ]; then
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    echo "setup-orca: presets.json already current"
  else
    if [ -f "$dest" ]; then
      backup="$dest.bak-$(date +%Y%m%d%H%M%S)"
      cp -p "$dest" "$backup"
      echo "setup-orca: backed up existing presets.json to $backup"
    fi
    cp -f "$src" "$dest"
    echo "setup-orca: installed presets.json to $dest"
  fi
fi

echo "setup-orca: done"
