#!/usr/bin/env bash
# Restore global agent skills from .agents/.skill-lock.json (skills CLI).
# Requires Node/npx. Run from dotfiles: DOTFILES=... script/bootstrap-agents.sh
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
AGENTS_DIR="${DOTFILES}/.agents"

if [ ! -d "$AGENTS_DIR" ]; then
  echo "bootstrap-agents: missing ${AGENTS_DIR} (clone dotfiles and run install.sh first)." >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "bootstrap-agents: npx not found; install Node.js to use the skills CLI." >&2
  exit 1
fi

if [ ! -f "${AGENTS_DIR}/.skill-lock.json" ]; then
  echo "bootstrap-agents: no .skill-lock.json in ${AGENTS_DIR}; nothing to restore." >&2
  exit 1
fi

echo "bootstrap-agents: running npx skills@latest experimental_install in ${AGENTS_DIR}"
(cd "$AGENTS_DIR" && exec npx skills@latest experimental_install)
