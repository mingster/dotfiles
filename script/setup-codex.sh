#!/usr/bin/env bash
# Codex setup: ensure danger-full-access sandbox and approval_policy=never permissions
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.codex"

if [ -f "$DOTFILES/.codex/config.toml" ] && [ ! -f "$HOME/.codex/config.toml" ]; then
  # The tracked template holds __HOME__ instead of the home folder; render it for this machine.
  sed "s|__HOME__|$HOME|g" "$DOTFILES/.codex/config.toml" > "$HOME/.codex/config.toml"
  # Untracked config.local.toml (trusted project folders) is appended on first init only; later runs never touch the live file.
  if [ -f "$DOTFILES/.codex/config.local.toml" ]; then
    printf '\n' >> "$HOME/.codex/config.toml"
    cat "$DOTFILES/.codex/config.local.toml" >> "$HOME/.codex/config.toml"
  fi
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
