#!/usr/bin/env bash
# Symlink global Cursor hooks from dotfiles into ~/.cursor/
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
SRC_DIR="$DOTFILES/ide/cursor"
HOOKS_SRC="$SRC_DIR/hooks"
HOOKS_JSON="$SRC_DIR/hooks.json"

mkdir -p "$HOME/.cursor/hooks/state"

if [[ ! -f "$HOOKS_JSON" ]]; then
	echo "link-cursor-hooks: missing $HOOKS_JSON" >&2
	exit 1
fi

ln -sfn "$HOOKS_JSON" "$HOME/.cursor/hooks.json"

shopt -s nullglob
for script in "$HOOKS_SRC"/*.sh; do
	ln -sfn "$script" "$HOME/.cursor/hooks/$(basename "$script")"
done
shopt -u nullglob

chmod +x "$HOOKS_SRC"/*.sh 2>/dev/null || true

echo "link-cursor-hooks: linked ~/.cursor/hooks.json and hook scripts from $HOOKS_SRC"
