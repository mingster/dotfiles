#!/usr/bin/env bash
# Orca setup: ensure presets.json and agent hooks are configured
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.orca"

src="$DOTFILES/.orca/presets.json"
dest="$HOME/.orca/presets.json"
if [ -f "$src" ]; then
  if [ -L "$dest" ] && [ "$dest" -ef "$src" ]; then
    echo "setup-orca: presets.json already linked"
  else
    if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
      backup="$dest.bak-$(date +%Y%m%d%H%M%S)"
      cp -p "$dest" "$backup"
      echo "setup-orca: backed up existing presets.json to $backup"
    fi
    ln -sfn "$src" "$dest"
    echo "setup-orca: linked presets.json to $src"
  fi
fi

echo "setup-orca: done"
