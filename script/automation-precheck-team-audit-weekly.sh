#!/usr/bin/env bash
# Append team-audit.sh (agent-team.sh check per project) and the weekly metrics for fleet automations (report only).
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
log=${TEAM_AUDIT_WEEKLY_LOG:-$HOME/.local/state/agent-team/team-audit-weekly.log}
mkdir -p "$(dirname "$log")"
{
  printf '%s team-audit-weekly\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  # team-audit.sh runs `agent-team.sh check <project>` for each project and, with
  # TEAM_AUDIT_RUN_METRICS=1, `script/team-audit-metrics.ts --repo <owner/name>` too.
  if [ -f "$DOTFILES/script/team-audit-metrics.ts" ] && command -v bun >/dev/null 2>&1; then
    run_metrics=1
  else
    run_metrics=0
    printf 'skip: team-audit-metrics.ts or bun unavailable\n'
  fi
  TEAM_AUDIT_RUN_METRICS=$run_metrics DOTFILES="$DOTFILES" bash "$DOTFILES/script/team-audit.sh" \
    || printf 'team-audit findings (exit %s)\n' "$?"
} >>"$log" 2>&1
