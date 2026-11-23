#!/usr/bin/env bash
# Zed: symlink settings from ~/dotfiles/ide/zed/ into ~/.config/zed/.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1568).
if [ $# -gt 0 ]; then
  echo "Usage: setup-zed.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-zed "$DOTFILES"
ZED_SRC="$DOTFILES/ide/zed"
ZED_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/zed"

if ! command -v zed >/dev/null 2>&1 \
    && [ ! -d "/Applications/Zed.app" ] \
    && [ ! -d "$HOME/Applications/Zed.app" ]; then
  echo "setup-zed: Zed not installed; skipping." >&2
  exit 0
fi

if [ ! -f "$ZED_SRC/settings.json" ]; then
  echo "setup-zed: missing $ZED_SRC/settings.json" >&2
  exit 1
fi

mkdir -p "$ZED_CONFIG"
ln -sfn "$ZED_SRC/settings.json" "$ZED_CONFIG/settings.json"
echo "setup-zed: linked $ZED_CONFIG/settings.json -> $ZED_SRC/settings.json"
