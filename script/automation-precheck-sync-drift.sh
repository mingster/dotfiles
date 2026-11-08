#!/usr/bin/env bash
# sync-team-skills --check for fleet automations (read-only drift report). Stdout only; wrapper owns the log file.
set -uo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
CONF="${TEAM_AUDIT_CONF:-$DOTFILES/script/team-audit.local.conf}"
projects=()
if [ -f "$CONF" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    projects+=("${line/#\~/$HOME}")
  done < "$CONF"
fi
if [ ${#projects[@]} -eq 0 ]; then
  printf 'skip: no project roots in %s\n' "$CONF"
  [ -n "${AUTOMATION_TRACE_SUMMARY_FILE:-}" ] && printf '%s\n' 'skip: no project roots' >"$AUTOMATION_TRACE_SUMMARY_FILE"
  exit 0
fi
DOTFILES="$DOTFILES" bash "$DOTFILES/script/sync-team-skills.sh" --check "${projects[@]}" \
  || printf 'drift or check failure (exit %s)\n' "$?"
