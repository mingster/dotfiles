#!/usr/bin/env bash
# Doc check (#1298): the PM and coordinator role files carry the owner decisions rule.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
pm=$root/templates/agent-team/.claude/agents/architect-pm.md
elon=$root/templates/agent-team/.claude/agents/elon.md
fail=0
chk() { if grep -qE "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3"; fail=1; fi; }
chk "$pm" 'owner-decisions\.sh' "architect-pm runs owner-decisions.sh"
chk "$pm" 'Owner decision' "architect-pm reads Owner decision comments"
chk "$pm" 'do not ask' "architect-pm does not ask when answered"
chk "$elon" 'owner-decisions\.sh' "elon runs owner-decisions.sh before relaying"
chk "$elon" 'Recheck decisions' "elon checks again before relaying"
exit "$fail"
