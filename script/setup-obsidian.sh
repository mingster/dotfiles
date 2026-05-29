#!/usr/bin/env bash
# Install Obsidian and create the vault directory used by agents as memory.
set -euo pipefail

VAULT="$HOME/Documents/Obsidian"

# Install the Obsidian app (package manager varies by OS)
case "${OSTYPE:-}" in
  darwin*)
    brew list --cask obsidian >/dev/null 2>&1 || brew install --cask obsidian
    ;;
  linux*)
    if command -v snap >/dev/null 2>&1; then
      snap list obsidian >/dev/null 2>&1 || snap install obsidian --classic
    elif command -v yay >/dev/null 2>&1; then
      yay -Qq obsidian >/dev/null 2>&1 || yay -S obsidian --noconfirm
    elif command -v paru >/dev/null 2>&1; then
      paru -Qq obsidian >/dev/null 2>&1 || paru -S obsidian --noconfirm
    else
      echo "setup-obsidian: install Obsidian manually from https://obsidian.md/download" >&2
    fi
    ;;
  *)
    echo "setup-obsidian: unsupported OS; install Obsidian manually from https://obsidian.md/download" >&2
    ;;
esac

# Create vault directory (safe to re-run)
mkdir -p "$VAULT"

echo "setup-obsidian: vault at $VAULT"
echo "setup-obsidian: open Obsidian, point it at $VAULT, then restart Claude Code for the MCP server to activate"
