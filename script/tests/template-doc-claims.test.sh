#!/usr/bin/env bash
# Guards three doc and config claims: team.md names the real Strikes enforcer (#1540), the engineering
# doc names no check script that does not exist (#1501), and the tracked Claude settings keep the four
# fleet display keys (#1409).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
docs="$ROOT/templates/agent-team/docs"

if grep -rn '\.claude/hooks/strikes\.py' "$docs"; then
  echo 'FAIL: a template doc still names .claude/hooks/strikes.py'; exit 1
fi
grep -F '`strikes.py` and `worker-budget.py` in `$HOME/.claude/hooks`' "$docs/agents/team.md" | grep -q 'Strikes'
echo 'PASS: Strikes row names the hooks in $HOME/.claude/hooks'

# Every bin/*.py or bin/*.sh a template doc runs must exist in bin/, script/ or the template.
missing=0
while IFS= read -r ref; do
  name=${ref##*/}
  if [ -z "$(find "$ROOT/bin" "$ROOT/script" "$ROOT/templates/agent-team" -name "$name" -print -quit)" ]; then
    echo "FAIL: docs name $ref but no $name exists"; missing=1
  fi
done < <(grep -rhoE '(python3|bash) bin/[A-Za-z0-9._-]+\.(py|sh)' "$docs" | awk '{print $2}' | sort -u)
[ "$missing" -eq 0 ]
if grep -n 'check-intent-roots' "$docs/agents/engineering-integration.md"; then
  echo 'FAIL: engineering-integration.md claims a missing intent root check'; exit 1
fi
echo 'PASS: template docs name no missing bin check script'

python3 - "$ROOT/.agents/claude/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
want = {"verbose": False, "spinnerTipsEnabled": False, "prefersReducedMotion": True, "tui": "fullscreen"}
bad = {k: s.get(k) for k, v in want.items() if s.get(k) != v}
sys.exit(f"FAIL: display keys differ: {bad}") if bad else None
PY
echo 'PASS: tracked Claude settings keep the four fleet display keys'
