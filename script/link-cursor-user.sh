#!/usr/bin/env bash
# Symlink Cursor User settings + keybindings to ~/dotfiles/ide/cursor/* (same layout as VS Code).
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
    echo "link-cursor-user: Windows not automated; copy ${DOTFILES}/ide/cursor/settings.json manually." >&2
    exit 0
    ;;
  *)
    echo "link-cursor-user: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

BASE_CURSOR_DIR="$DOTFILES/ide/cursor"
if [ ! -d "$BASE_CURSOR_DIR" ] && [ -d "$DOTFILES/cursor" ]; then
  BASE_CURSOR_DIR="$DOTFILES/cursor"
  echo "link-cursor-user: falling back to legacy $BASE_CURSOR_DIR" >&2
fi

mkdir -p "$CURSOR_USER"
for file in settings.json keybindings.json environment.json; do
  if [ ! -e "$BASE_CURSOR_DIR/$file" ]; then
    echo "link-cursor-user: missing $BASE_CURSOR_DIR/$file" >&2
    exit 1
  fi
  ln -sfn "$BASE_CURSOR_DIR/$file" "$CURSOR_USER/$file"
done

echo "link-cursor-user: linked $CURSOR_USER/{settings,keybindings,environment}.json -> $BASE_CURSOR_DIR/"
