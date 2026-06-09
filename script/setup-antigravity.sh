#!/usr/bin/env bash
# Antigravity IDE: symlink User settings and keybindings from ~/dotfiles/ide/antigravity/.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

case "${OSTYPE:-}" in
  darwin*)
    AG_USER="$HOME/Library/Application Support/Antigravity IDE/User"
    if [ ! -d "/Applications/Antigravity IDE.app" ] \
        && [ ! -d "/Applications/_dev/Antigravity IDE.app" ] \
        && [ ! -d "$HOME/Applications/Antigravity IDE.app" ]; then
      echo "setup-antigravity: Antigravity IDE not installed; skipping." >&2
      exit 0
    fi
    ;;
  linux*)
    AG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/Antigravity IDE/User"
    if ! command -v antigravity >/dev/null 2>&1 && ! command -v antigravity-ide >/dev/null 2>&1; then
      echo "setup-antigravity: Antigravity IDE not installed; skipping." >&2
      exit 0
    fi
    ;;
  msys* | cygwin*)
    echo "setup-antigravity: Windows not automated; copy ${DOTFILES}/Antigravity/settings.json manually." >&2
    exit 0
    ;;
  *)
    echo "setup-antigravity: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

AG_SRC="$DOTFILES/ide/antigravity"
if [ ! -f "$AG_SRC/settings.json" ] || [ ! -f "$AG_SRC/keybindings.json" ]; then
  echo "setup-antigravity: missing $AG_SRC/{settings.json,keybindings.json}" >&2
  exit 1
fi

mkdir -p "$AG_USER"
ln -sfn "$AG_SRC/settings.json" "$AG_USER/settings.json"
ln -sfn "$AG_SRC/keybindings.json" "$AG_USER/keybindings.json"
echo "setup-antigravity: linked $AG_USER/{settings,keybindings}.json -> $AG_SRC/"
