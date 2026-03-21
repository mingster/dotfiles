#!/usr/bin/env bash
# Install Claude Code CLI on Arch Linux (and other distros) using Anthropic's installer.
# Docs: https://code.claude.com/docs/en/setup
# After install, run dotfiles: bash ~/dotfiles/script/setup-claude-code.sh (or full install.sh).
set -euo pipefail

if command -v claude >/dev/null 2>&1; then
  echo "arch/install_claude: claude already in PATH ($(claude --version 2>/dev/null || echo ok))"
  exit 0
fi

echo "arch/install_claude: downloading and running https://claude.ai/install.sh"
curl -fsSL https://claude.ai/install.sh | bash

if ! command -v claude >/dev/null 2>&1; then
  echo "arch/install_claude: claude not found on PATH yet." >&2
  echo "  Add ~/.local/bin to PATH (installer puts the binary there), then open a new shell." >&2
  echo "  fish:  fish_add_path ~/.local/bin" >&2
  echo "  bash:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
  exit 1
fi

echo "arch/install_claude: $(claude --version 2>/dev/null || true)"
echo "arch/install_claude: optional checks: claude doctor"
