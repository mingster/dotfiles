#!/usr/bin/env bash
# Install Obsidian and create the vault directory used by agents as memory.
set -euo pipefail

VAULT="$HOME/Documents/Obsidian"

# Install the Obsidian app
brew list --cask obsidian >/dev/null 2>&1 || brew install --cask obsidian

# Create vault directory (safe to re-run)
mkdir -p "$VAULT"

echo "setup-obsidian: vault at $VAULT"
echo "setup-obsidian: open Obsidian, point it at $VAULT, then restart Claude Code for the MCP server to activate"
