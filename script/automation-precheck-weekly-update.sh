#!/usr/bin/env bash
# Append weekly-update.sh output for fleet automations (opens PRs; no merge).
set -uo pipefail
usage='Usage: automation-precheck-weekly-update.sh [-h|--help]'
if [ $# -gt 0 ]; then
  if [ $# -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then echo "$usage"; exit 0; fi
  echo "$usage" >&2
  exit 2
fi
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
log=${WEEKLY_UPDATE_LOG:-$HOME/.local/state/agent-team/weekly-update.log}
mkdir -p "$(dirname "$log")"
{
  printf '%s weekly-update\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  DOTFILES="$DOTFILES" bash "$DOTFILES/script/weekly-update.sh" \
    || printf 'weekly-update failed (exit %s)\n' "$?"
} >>"$log" 2>&1
