#!/usr/bin/env bash
# Copy global Cursor hooks.json and symlink hook scripts from dotfiles into ~/.cursor/.
# hooks.json is copied, not linked: Orca rewrites its own entries in it with the
# absolute home path, which must stay out of this public repo.
set -euo pipefail

case "${1:-}" in
  "") ;;
  -h|--help) echo "Usage: link-cursor-hooks.sh   (takes no arguments)"; exit 0 ;;
  *) echo "Usage: link-cursor-hooks.sh   (takes no arguments)" >&2; exit 2 ;;
esac

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles link-cursor-hooks "$DOTFILES"
SRC_DIR="$DOTFILES/ide/cursor"
HOOKS_SRC="$SRC_DIR/hooks"
HOOKS_JSON="$SRC_DIR/hooks.json"

mkdir -p "$HOME/.cursor/hooks/state"

if [[ ! -f "$HOOKS_JSON" ]]; then
	echo "link-cursor-hooks: missing $HOOKS_JSON" >&2
	exit 1
fi

rm -f "$HOME/.cursor/hooks.json"
cp "$HOOKS_JSON" "$HOME/.cursor/hooks.json"

shopt -s nullglob
for script in "$HOOKS_SRC"/*.sh; do
	ln -sfn "$script" "$HOME/.cursor/hooks/$(basename "$script")"
done
shopt -u nullglob

chmod +x "$HOOKS_SRC"/*.sh 2>/dev/null || true

echo "link-cursor-hooks: copied ~/.cursor/hooks.json and linked hook scripts from $HOOKS_SRC"
