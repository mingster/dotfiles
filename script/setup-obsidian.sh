#!/usr/bin/env bash
# Create the Obsidian vault directory used by agents as memory.
# Obsidian itself is installed via install_my_software.sh (macOS) or manually on other platforms.
set -euo pipefail

VAULT="$HOME/Documents/Obsidian"
mkdir -p "$VAULT"

echo "setup-obsidian: vault at $VAULT"
echo "setup-obsidian: open Obsidian, point it at $VAULT, then restart Claude Code for the MCP server to activate"
