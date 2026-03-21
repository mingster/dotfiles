#!/usr/bin/env bash
# Symlink Cursor User settings + keybindings to ~/dotfiles/cursor/* (same layout as VS Code).
# Standard content is maintained in dotfiles (synced from riben.life web stack — see cursor/rules/README.md).
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

case "${OSTYPE:-}" in
  darwin*)
    CURSOR_USER="$HOME/Library/Application Support/Cursor/User"
    ;;
  linux*)
    CURSOR_USER="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor/User"
    ;;
  msys* | cygwin*)
    echo "link-cursor-user: Windows not automated; copy ${DOTFILES}/cursor/settings.json manually." >&2
    exit 0
    ;;
  *)
    echo "link-cursor-user: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

mkdir -p "$CURSOR_USER"
ln -sfn "$DOTFILES/cursor/settings.json" "$CURSOR_USER/settings.json"
ln -sfn "$DOTFILES/cursor/keybindings.json" "$CURSOR_USER/keybindings.json"
echo "link-cursor-user: linked $CURSOR_USER/{settings,keybindings}.json -> $DOTFILES/cursor/"
