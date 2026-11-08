#!/usr/bin/env bash
# weekly-update.sh for fleet automations (opens PRs; no merge). Stdout only; wrapper owns the log file.
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES="$DOTFILES" bash "$DOTFILES/script/weekly-update.sh" \
  || printf 'weekly-update failed (exit %s)\n' "$?"
