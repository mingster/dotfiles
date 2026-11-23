#!/usr/bin/env bash
# Orca setup: link presets.json into ~/.orca (backs up a differing file). Installs no agent hooks.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1568).
if [ $# -gt 0 ]; then
  echo "Usage: setup-orca.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-orca "$DOTFILES"

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
