#!/usr/bin/env bash
# Codex setup: ensure danger-full-access sandbox and approval_policy=never permissions
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.codex"

if [ -f "$DOTFILES/.codex/config.toml" ] && [ ! -f "$HOME/.codex/config.toml" ]; then
  cp -f "$DOTFILES/.codex/config.toml" "$HOME/.codex/config.toml"
  echo "setup-codex: initialized $HOME/.codex/config.toml from template"
fi

echo "setup-codex: done"
