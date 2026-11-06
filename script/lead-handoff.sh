#!/usr/bin/env bash
# Append one handoff line (time, branch, head, remainder, dispatch ids) to the lead handoff log.
# Usage: lead-handoff.sh --branch B --head H --remainder R --dispatch-ids IDS
# Log: ${LEAD_HANDOFFS_FILE:-~/.claude/state/lead-handoffs}. Any missing or empty field exits 1 and writes nothing.
set -euo pipefail
branch= head= remainder= ids=
while [ $# -gt 0 ]; do
  case $1 in
    --branch) branch=${2-} ;; --head) head=${2-} ;; --remainder) remainder=${2-} ;; --dispatch-ids) ids=${2-} ;;
    *) echo "lead-handoff: unknown argument $1" >&2; exit 2 ;;
  esac
  shift 2 || { echo "lead-handoff: missing value" >&2; exit 2; }
done
for f in branch head remainder ids; do [ -n "${!f}" ] || { echo "lead-handoff: $f is required" >&2; exit 1; }; done
log=${LEAD_HANDOFFS_FILE:-$HOME/.claude/state/lead-handoffs}
mkdir -p "$(dirname "$log")"
line=$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$head" "$remainder" "$ids" | tr '\n' ' ')
printf '%s\n' "$line" >>"$log"
