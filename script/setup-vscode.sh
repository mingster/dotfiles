#!/usr/bin/env bash
# VS Code: symlink User settings and keybindings from ~/dotfiles/vscode/.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

case "${OSTYPE:-}" in
  darwin*)
    VSCODE_USER="$HOME/Library/Application Support/Code/User"
    ;;
  linux*)
    VSCODE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
    ;;
  msys* | cygwin*)
    echo "setup-vscode: Windows not automated; copy ${DOTFILES}/vscode/settings.json manually." >&2
    exit 0
    ;;
  *)
    echo "setup-vscode: unknown OSTYPE=${OSTYPE:-}, skipping." >&2
    exit 0
    ;;
esac

mkdir -p "$VSCODE_USER"
ln -sfn "$DOTFILES/vscode/settings.json" "$VSCODE_USER/settings.json"
ln -sfn "$DOTFILES/vscode/keybindings.json" "$VSCODE_USER/keybindings.json"
echo "setup-vscode: linked $VSCODE_USER/{settings,keybindings}.json -> $DOTFILES/vscode/"
