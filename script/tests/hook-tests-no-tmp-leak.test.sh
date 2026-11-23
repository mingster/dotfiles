#!/usr/bin/env bash
# The five agent-team hook test files that build a temp home remove it after each test (#1632).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tmpdir"
tests="$ROOT/templates/agent-team/.claude/hooks/tests"
fail=0
for t in test_guard_bash test_team_gates test_worker_budget test_owner_decisions_stop test_strikes; do
  out=$(cd "$tests" && TMPDIR="$TMP/tmpdir" python3 -m unittest "$t" 2>&1) || { echo "FAIL $t does not pass: $(printf '%s' "$out" | tail -3)"; fail=1; continue; }
  left=$(ls -A "$TMP/tmpdir" | head -3 | tr '\n' ' ')
  if [ -z "$left" ]; then echo "ok   $t leaves TMPDIR empty"; else echo "FAIL $t left temp folders: $left"; fail=1; fi
  find "$TMP/tmpdir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
done
[ "$fail" = 0 ]
