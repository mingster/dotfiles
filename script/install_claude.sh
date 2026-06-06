#!/usr/bin/env bash
# Install Claude Code CLI (cross-platform).
# Docs: https://code.claude.com/docs/en/setup
# After install, run: bash ~/dotfiles/script/setup-claude-code.sh
set -euo pipefail

if command -v claude >/dev/null 2>&1; then
  echo "install_claude: claude already in PATH ($(claude --version 2>/dev/null || echo ok))"
  exit 0
fi

echo "install_claude: downloading and running https://claude.ai/install.sh"
curl -fsSL https://claude.ai/install.sh | bash

if ! command -v claude >/dev/null 2>&1; then
  echo "install_claude: claude not found on PATH yet." >&2
  echo "  Add ~/.local/bin to PATH (installer puts the binary there), then open a new shell." >&2
  echo "  fish:  fish_add_path ~/.local/bin" >&2
  echo "  bash:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
  exit 1
fi

echo "install_claude: $(claude --version 2>/dev/null || true)"
echo "install_claude: optional checks: claude doctor"
