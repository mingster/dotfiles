#!/usr/bin/env bash
# Claude Code (CLI + Claude Code Desktop): symlink ~/.claude/* from ~/dotfiles/.agents.
# Skills: ~/.claude/skills -> .agents/skills (same tree as the skills CLI).
# All other entries in .agents/claude/ are linked into ~/.claude/ automatically.
# README.md is excluded (documentation only).
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

# Old layout: ~/.claude was a single symlink — replace with granular links
if [ -L "${HOME}/.claude" ]; then
  echo "setup-claude-code: removing legacy ~/.claude symlink"
  rm -f "${HOME}/.claude"
fi

mkdir -p "${HOME}/.claude"

# Skills: shared tree between skills CLI and Claude Code
rm -rf "${HOME}/.claude/skills"
ln -sfn "$AGENTS_ROOT/skills" "${HOME}/.claude/skills"

# Link every entry in .agents/claude/ into ~/.claude/ (skip README.md)
for entry in "$CLAUDE_SRC"/*; do
  name=$(basename "$entry")
  [ "$name" = "README.md" ] && continue
  ln -sfn "$entry" "${HOME}/.claude/$name"
done

# Cursor discovers skills from BOTH ~/.cursor/skills/ and ~/.claude/skills/ (compatibility).
# If both point at the same tree, each skill appears twice. Remove ~/.cursor/skills when
# it resolves to the same directory as ~/.claude/skills.
if [ -e "${HOME}/.cursor/skills" ] && [ -e "${HOME}/.claude/skills" ]; then
  if _c=$(cd "${HOME}/.claude/skills" 2>/dev/null && pwd -P) && \
     _u=$(cd "${HOME}/.cursor/skills" 2>/dev/null && pwd -P); then
    if [ "${_c}" = "${_u}" ]; then
      echo "setup-claude-code: removing ${HOME}/.cursor/skills (same tree as ~/.claude/skills)"
      rm -rf "${HOME}/.cursor/skills"
    fi
  fi
fi

echo "setup-claude-code: linked ~/.claude <- ${CLAUDE_SRC} (skills <- ${AGENTS_ROOT}/skills)"
