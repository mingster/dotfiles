#!/usr/bin/env bash
# Symlink Cursor User settings + keybindings to ~/dotfiles/ide/cursor/* (same layout as VS Code).
# Standard content is maintained in dotfiles (see ide/cursor/rules/README.md).
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
  if [ "$file" = settings.json ] && [ -f "$BASE_CURSOR_DIR/settings.local.json" ]; then
    # An untracked settings.local.json adds list items (spell words), so the result is a rendered copy, not a link.
    rm -f "$CURSOR_USER/$file"
    python3 "$DOTFILES/script/apply-ide-overlay.py" "$BASE_CURSOR_DIR/$file" "$BASE_CURSOR_DIR/settings.local.json" > "$CURSOR_USER/$file"
  else
    ln -sfn "$BASE_CURSOR_DIR/$file" "$CURSOR_USER/$file"
  fi
done

# No ~/.cursor/skills link: Cursor already reads ~/.claude/skills (setup-claude-code.sh), and a
# second link to the same tree lists every skill twice. setup-claude-code.sh removes a stale one.

echo "link-cursor-user: linked $CURSOR_USER/{settings,keybindings,environment}.json -> $BASE_CURSOR_DIR/"
