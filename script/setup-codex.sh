#!/usr/bin/env bash
# Codex setup: ensure danger-full-access sandbox and approval_policy=never permissions
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

mkdir -p "$HOME/.codex"

if [ -f "$DOTFILES/.codex/config.toml" ] && [ ! -f "$HOME/.codex/config.toml" ]; then
  # The tracked template holds __HOME__ instead of the home folder; render it for this machine.
  sed "s|__HOME__|$HOME|g" "$DOTFILES/.codex/config.toml" > "$HOME/.codex/config.toml"
  # Untracked config.local.toml is appended on first init only.
  if [ -f "$DOTFILES/.codex/config.local.toml" ]; then
    printf '\n' >> "$HOME/.codex/config.toml"
    cat "$DOTFILES/.codex/config.local.toml" >> "$HOME/.codex/config.toml"
  fi
  echo "setup-codex: initialized $HOME/.codex/config.toml from template"
fi

# Reconcile only the managed top-level keys; table-specific settings stay intact.
config="$HOME/.codex/config.toml"
if [ -f "$config" ]; then
  staged=$(mktemp "$HOME/.codex/config.toml.tmp.XXXXXX")
  trap 'rm -f "$staged"' EXIT
  awk '
    BEGIN {
      names[1] = "sandbox_mode"; values[1] = "danger-full-access"
      names[2] = "approval_policy"; values[2] = "never"
      names[3] = "model"; values[3] = "gpt-6.1-sol"
      names[4] = "model_reasoning_effort"; values[4] = "medium"
    }
    function missing(    i) {
      for (i = 1; i <= 4; i++)
        if (!seen[i]) print names[i] " = \"" values[i] "\""
    }
    /^[[:space:]]*\[/ && !table { missing(); table = 1 }
    !table {
      for (i = 1; i <= 4; i++) {
        if ($0 ~ "^[[:space:]]*" names[i] "[[:space:]]*=") {
          print names[i] " = \"" values[i] "\""
          seen[i] = 1
          next
        }
      }
    }
    { print }
    END { if (!table) missing() }
  ' "$config" > "$staged"
  if ! cmp -s "$config" "$staged"; then
    backup=$(mktemp "$config.bak.XXXXXX")
    cp -p "$config" "$backup"
    cat "$staged" > "$config"
    echo "setup-codex: updated managed keys (backup: $backup)"
  fi
  rm -f "$staged"
  trap - EXIT
fi

# Global instructions: link ~/.codex/AGENTS.md to the dotfiles copy (a real file is kept as .bak).
if [ -f "$DOTFILES/.codex/AGENTS.md" ]; then
  if [ -e "$HOME/.codex/AGENTS.md" ] && [ ! -L "$HOME/.codex/AGENTS.md" ]; then
    mv "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.bak"
  fi
  ln -sfn "$DOTFILES/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
fi

echo "setup-codex: done"
