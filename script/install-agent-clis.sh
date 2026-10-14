#!/usr/bin/env bash
# Install missing provider CLIs. Authentication remains an owner action.
# Official installers: code.claude.com/docs/en/setup,
# help.openai.com/en/articles/11096431, cursor.com/docs/cli/installation,
# antigravity.google/docs/cli/install/.
set -euo pipefail
DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export PATH="$HOME/.local/bin:$PATH"
bash "$DOTFILES/script/install_claude.sh"
if ! command -v codex >/dev/null 2>&1; then
  if command -v npm >/dev/null 2>&1; then
    npm install -g @openai/codex
  else
    echo 'WARN install-agent-clis: install Node.js/npm, then npm install -g @openai/codex' >&2
  fi
fi
if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
  curl -fsSL https://cursor.com/install | bash
fi
if ! command -v agy >/dev/null 2>&1; then
  curl -fsSL https://antigravity.google/cli/install.sh | bash
fi
