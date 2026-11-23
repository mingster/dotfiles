#!/usr/bin/env bash
# Append only agent-team.sh check output for fleet automations (read-only drift report).
set -uo pipefail
usage='Usage: automation-precheck-sync-drift.sh [-h|--help]'
if [ $# -gt 0 ]; then
  if [ $# -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then echo "$usage"; exit 0; fi
  echo "$usage" >&2
  exit 2
fi
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
CONF="${TEAM_AUDIT_CONF:-$DOTFILES/script/team-audit.local.conf}"
log=${SYNC_DRIFT_LOG:-$HOME/.local/state/agent-team/sync-team-skills-drift.log}
mkdir -p "$(dirname "$log")"
{
  printf '%s sync-team-skills-drift\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  projects=()
  if [ -f "$CONF" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      projects+=("${line/#\~/$HOME}")
    done < "$CONF"
  fi
  if [ ${#projects[@]} -eq 0 ]; then
    printf 'skip: no project roots in %s\n' "$CONF"
    exit 0
  fi
  DOTFILES="$DOTFILES" bash "$DOTFILES/script/agent-team.sh" check "${projects[@]}" \
    || printf 'drift or check failure (exit %s)\n' "$?"
} >>"$log" 2>&1
