#!/usr/bin/env bash
# team-audit.sh and optional metrics for fleet automations (report only). Stdout only; wrapper owns the log file.
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES="$DOTFILES" bash "$DOTFILES/script/team-audit.sh" \
  || printf 'team-audit findings (exit %s)\n' "$?"
metrics="$DOTFILES/bin/team-audit-metrics.ts"
if [ -f "$metrics" ] && command -v bun >/dev/null 2>&1; then
  (cd "$DOTFILES" && bun bin/team-audit-metrics.ts) || printf 'metrics failed (exit %s)\n' "$?"
else
  printf 'skip: metrics script or bun unavailable\n'
fi
