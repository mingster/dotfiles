#!/usr/bin/env bash
# Claude Code: symlink ~/.claude/* from ~/dotfiles/.agents (shared skills + .agents/claude/*).
# Skills live in .agents/skills (same tree as skills CLI). Claude-only files in .agents/claude/.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
AGENTS_ROOT="$DOTFILES/.agents"
CLAUDE_SRC="$AGENTS_ROOT/claude"

if [ ! -d "$CLAUDE_SRC" ]; then
  echo "setup-claude-code: missing ${CLAUDE_SRC}; clone dotfiles with .agents/claude." >&2
  exit 1
fi

if [ ! -d "$AGENTS_ROOT/skills" ]; then
  echo "setup-claude-code: missing ${AGENTS_ROOT}/skills" >&2
  exit 1
fi

# Old layout: ~/.claude was a single symlink to ~/dotfiles/.claude — replace with granular links
if [ -L "${HOME}/.claude" ]; then
  echo "setup-claude-code: removing legacy ~/.claude symlink"
  rm -f "${HOME}/.claude"
fi

mkdir -p "${HOME}/.claude"

ln -sf "$CLAUDE_SRC/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"
ln -sf "$CLAUDE_SRC/laravel-php-guidelines.md" "${HOME}/.claude/laravel-php-guidelines.md"
ln -sf "$CLAUDE_SRC/settings.json" "${HOME}/.claude/settings.json"
ln -sf "$CLAUDE_SRC/statusline.sh" "${HOME}/.claude/statusline.sh"
chmod +x "$CLAUDE_SRC/statusline.sh" 2>/dev/null || true

rm -rf "${HOME}/.claude/skills"
ln -sf "$AGENTS_ROOT/skills" "${HOME}/.claude/skills"

rm -rf "${HOME}/.claude/agents"
ln -sf "$CLAUDE_SRC/agents" "${HOME}/.claude/agents"

echo "setup-claude-code: linked ~/.claude -> ${CLAUDE_SRC} (skills -> ${AGENTS_ROOT}/skills)"
