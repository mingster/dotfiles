#!/usr/bin/env bash
# Install Zed editor (cross-platform).
# Docs: https://zed.dev/docs/installation
set -euo pipefail

if command -v zed >/dev/null 2>&1; then
  echo "install_zed: zed already in PATH"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "install_zed: brew install --cask zed"
  brew list --cask zed >/dev/null 2>&1 || brew install --cask zed
elif command -v pacman >/dev/null 2>&1; then
  echo "install_zed: sudo pacman -S --needed --noconfirm zed"
  sudo pacman -S --needed --noconfirm zed
else
  echo "install_zed: using https://zed.dev/install.sh"
  curl -fsSL https://zed.dev/install.sh | sh
fi

if ! command -v zed >/dev/null 2>&1; then
  echo "install_zed: zed not on PATH. If you used install.sh, add ~/.local/bin to PATH and open a new shell." >&2
  exit 1
fi

echo "install_zed: ok ($(command -v zed))"
