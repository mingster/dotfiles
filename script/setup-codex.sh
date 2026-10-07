#!/usr/bin/env bash
# Codex setup: ensure danger-full-access sandbox and approval_policy=never permissions
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.codex"

if [ -f "$DOTFILES/.codex/config.toml" ] && [ ! -f "$HOME/.codex/config.toml" ]; then
  cp -f "$DOTFILES/.codex/config.toml" "$HOME/.codex/config.toml"
  echo "setup-codex: initialized $HOME/.codex/config.toml from template"
fi

# Global instructions: link ~/.codex/AGENTS.md to the dotfiles copy (a real file is kept as .bak).
if [ -f "$DOTFILES/.codex/AGENTS.md" ]; then
  if [ -e "$HOME/.codex/AGENTS.md" ] && [ ! -L "$HOME/.codex/AGENTS.md" ]; then
    mv "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.bak"
  fi
  ln -sfn "$DOTFILES/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
fi

echo "setup-codex: done"
