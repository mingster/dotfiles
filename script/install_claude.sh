#!/usr/bin/env bash
# Install Claude Code CLI (cross-platform).
# Docs: https://code.claude.com/docs/en/setup
# After install, run: bash ~/dotfiles/script/setup-claude-code.sh
set -euo pipefail

# Takes no arguments: -h/--help print usage, anything else is refused before any change (#1582).
if [ $# -gt 0 ]; then
  echo "Usage: install_claude.sh (takes no arguments)" >&2
  case "$*" in -h | --help) [ $# -eq 1 ] && exit 0 ;; esac
  exit 2
fi

if command -v claude >/dev/null 2>&1; then
  echo "install_claude: claude already in PATH ($(claude --version 2>/dev/null || echo ok))"
  exit 0
fi

echo "install_claude: downloading and running https://claude.ai/install.sh"
curl -fsSL https://claude.ai/install.sh | bash

if ! command -v claude >/dev/null 2>&1; then
  echo "install_claude: claude not found on PATH yet." >&2
  echo "  Add ~/.local/bin to PATH (installer puts the binary there), then open a new shell." >&2
  echo "  bash:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
  exit 1
fi

echo "install_claude: $(claude --version 2>/dev/null || true)"
echo "install_claude: optional checks: claude doctor"
