#!/usr/bin/env bash
# Append team-audit.sh and optional metrics for fleet automations (report only).
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
log=${TEAM_AUDIT_WEEKLY_LOG:-$HOME/.local/state/agent-team/team-audit-weekly.log}
mkdir -p "$(dirname "$log")"
{
  printf '%s team-audit-weekly\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  DOTFILES="$DOTFILES" bash "$DOTFILES/script/team-audit.sh" \
    || printf 'team-audit findings (exit %s)\n' "$?"
  metrics="$DOTFILES/bin/team-audit-metrics.ts"
  if [ -f "$metrics" ] && command -v bun >/dev/null 2>&1; then
    (cd "$DOTFILES" && bun bin/team-audit-metrics.ts) || printf 'metrics failed (exit %s)\n' "$?"
  else
    printf 'skip: metrics script or bun unavailable\n'
  fi
} >>"$log" 2>&1
