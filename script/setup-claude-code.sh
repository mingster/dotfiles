#!/usr/bin/env bash
# Claude Code (CLI + Claude Code Desktop): symlink ~/.claude/* from ~/dotfiles/.agents.
# Skills: real home directories with individual links to tracked dotfiles skills.
# All other entries in .agents/claude/ are linked into ~/.claude/ automatically.
# README.md is excluded (documentation only).
set -euo pipefail
KEEP_SETTINGS=0
case "${1:-}" in
  --keep-settings) KEEP_SETTINGS=1 ;;
  '') ;;
  *) echo 'Usage: setup-claude-code.sh [--keep-settings]' >&2; exit 2 ;;
esac

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

# Refuse before the first write to HOME (#797).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles setup-claude-code "$DOTFILES"

# Old layout: ~/.claude was a single symlink — replace with granular links
if [ -L "${HOME}/.claude" ]; then
  echo "setup-claude-code: removing legacy ~/.claude symlink"
  rm -f "${HOME}/.claude"
fi

mkdir -p "${HOME}/.claude"

export DOTFILES
bash "$DOTFILES/script/setup-agent-skills.sh"

# CLAUDE.md is COPIED, not linked. Cowork sessions skip a ~/.claude/CLAUDE.md that is
# itself a symlink, and skip user-scope imports resolving outside the session working
# directory, so a linked or @-imported global file silently fails to load there.
# https://code.claude.com/docs/en/memory#import-additional-files
# The copy means edits to ~/.claude/CLAUDE.md do not flow back: edit
# .agents/claude/CLAUDE.md and re-run this script.
rm -f "${HOME}/.claude/CLAUDE.md"
cp "$CLAUDE_SRC/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"

# Link every other entry in .agents/claude/ into ~/.claude/ (skip README.md and CLAUDE.md)
for entry in "$CLAUDE_SRC"/*; do
  name=$(basename "$entry")
  [ "$name" = "README.md" ] && continue
  [ "$name" = "CLAUDE.md" ] && continue
  [ "$name" != settings.json ] || [ "$KEEP_SETTINGS" -eq 0 ] || continue
  ln -sfn "$entry" "${HOME}/.claude/$name"
done

TEAM_CLAUDE="$DOTFILES/templates/agent-team/.claude"
if [ -d "$TEAM_CLAUDE/hooks" ]; then
  [ ! -L "${HOME}/.claude/hooks" ] || rm -f "${HOME}/.claude/hooks"
  mkdir -p "${HOME}/.claude/hooks"
  # session-start.md is a rendered copy owned by `agent-team.sh machine`; do not link it here.
  for hook in guard-bash.py strikes.py worker-budget.py; do
    [ -e "$TEAM_CLAUDE/hooks/$hook" ] || continue
    ln -sfn "$TEAM_CLAUDE/hooks/$hook" "${HOME}/.claude/hooks/$hook"
  done
fi
if [ -d "$TEAM_CLAUDE/bin" ]; then
  [ ! -L "${HOME}/.claude/bin" ] || rm -f "${HOME}/.claude/bin"
  mkdir -p "${HOME}/.claude/bin"
  for helper in env-peek.py state-of-play.sh; do
    [ -e "$TEAM_CLAUDE/bin/$helper" ] || continue
    ln -sfn "$TEAM_CLAUDE/bin/$helper" "${HOME}/.claude/bin/$helper"
  done
fi

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
echo "setup-claude-code: copied ~/.claude/CLAUDE.md (re-run after editing the source)"
