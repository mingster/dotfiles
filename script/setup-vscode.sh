#!/usr/bin/env bash
# VS Code: symlink User settings and keybindings from ~/dotfiles/ide/vscode/.
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1568).
if [ $# -gt 0 ]; then
  echo "Usage: setup-vscode.sh (takes no arguments)" >&2
  case "$1" in -h | --help) exit 0 ;; *) exit 2 ;; esac
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
# shellcheck source=lib/dotfiles-source.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-vscode "$DOTFILES"
# shellcheck source=lib/link-user-file.sh
. "$DOTFILES/script/lib/link-user-file.sh"

case "${OSTYPE:-}" in
  darwin*)
    VSCODE_USER="$HOME/Library/Application Support/Code/User"
    if ! command -v code >/dev/null 2>&1 \
        && [ ! -d "/Applications/Visual Studio Code.app" ] \
        && [ ! -d "$HOME/Applications/Visual Studio Code.app" ]; then
      echo "setup-vscode: VS Code not installed; skipping." >&2
      exit 0
    fi
    ;;
  linux*)
    if ! command -v code >/dev/null 2>&1; then
      echo "setup-vscode: VS Code not installed; skipping." >&2
      exit 0
    fi
    # Arch AUR build ('code') installs the OSS variant which uses "Code - OSS"
    if command -v pacman >/dev/null 2>&1; then
      VSCODE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/Code - OSS/User"
    else
      VSCODE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
    fi
    ;;
  msys* | cygwin*)
    echo "setup-vscode: Windows not automated; copy ${DOTFILES}/ide/vscode/settings.json manually." >&2
    exit 0
    ;;
  *)
    echo "setup-vscode: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

VSCODE_SRC="$DOTFILES/ide/vscode"
if [ ! -d "$VSCODE_SRC" ] && [ -d "$DOTFILES/vscode" ]; then
  VSCODE_SRC="$DOTFILES/vscode"
  echo "setup-vscode: falling back to legacy $VSCODE_SRC" >&2
fi

if [ ! -f "$VSCODE_SRC/settings.json" ] || [ ! -f "$VSCODE_SRC/keybindings.json" ]; then
  echo "setup-vscode: missing $VSCODE_SRC/{settings.json,keybindings.json}" >&2
  exit 1
fi

mkdir -p "$VSCODE_USER"
link_user_file "$VSCODE_SRC/settings.json" "$VSCODE_USER/settings.json"
link_user_file "$VSCODE_SRC/keybindings.json" "$VSCODE_USER/keybindings.json"
echo "setup-vscode: linked $VSCODE_USER/{settings,keybindings}.json -> $VSCODE_SRC/"
