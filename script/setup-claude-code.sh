#!/usr/bin/env bash
# Claude Code (CLI + Claude Code Desktop): symlink ~/.claude/* from ~/dotfiles/.agents.
# Personal skills: ~/.claude/skills -> .agents/skills (same tree as the skills CLI).
# Other entries from .agents/claude/ (CLAUDE.md, settings.json, agents/, …).
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

# Cursor discovers skills from BOTH ~/.cursor/skills/ and ~/.claude/skills/ (compatibility).
# If both point at the same tree, each skill appears twice in Cursor. Keep ~/.claude/skills
# (Claude Code) and drop a redundant ~/.cursor/skills when canonical paths match.
if [ -e "${HOME}/.cursor/skills" ] && [ -e "${HOME}/.claude/skills" ]; then
  if _c=$(cd "${HOME}/.claude/skills" 2>/dev/null && pwd -P) && _u=$(cd "${HOME}/.cursor/skills" 2>/dev/null && pwd -P); then
    if [ "${_c}" = "${_u}" ]; then
      echo "setup-claude-code: removing ${HOME}/.cursor/skills (same tree as ~/.claude/skills; avoids duplicate skills in Cursor)"
      rm -rf "${HOME}/.cursor/skills"
    fi
  fi
fi

echo "setup-claude-code: linked ~/.claude -> ${CLAUDE_SRC} (skills -> ${AGENTS_ROOT}/skills)"
