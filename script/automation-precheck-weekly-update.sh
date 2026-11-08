#!/usr/bin/env bash
# Append weekly-update.sh output for fleet automations (opens PRs; no merge).
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
log=${WEEKLY_UPDATE_LOG:-$HOME/.local/state/agent-team/weekly-update.log}
mkdir -p "$(dirname "$log")"
{
  printf '%s weekly-update\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  DOTFILES="$DOTFILES" bash "$DOTFILES/script/weekly-update.sh" \
    || printf 'weekly-update failed (exit %s)\n' "$?"
} >>"$log" 2>&1
