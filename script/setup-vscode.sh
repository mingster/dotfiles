#!/usr/bin/env bash
# VS Code: symlink User settings and keybindings from ~/dotfiles/ide/vscode/.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

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

mkdir -p "$VSCODE_USER"
ln -sfn "$DOTFILES/ide/vscode/settings.json" "$VSCODE_USER/settings.json"
ln -sfn "$DOTFILES/ide/vscode/keybindings.json" "$VSCODE_USER/keybindings.json"
echo "setup-vscode: linked $VSCODE_USER/{settings,keybindings}.json -> $DOTFILES/ide/vscode/"
