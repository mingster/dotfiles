#!/usr/bin/env bash
# agent-team.sh --labels seeds the 20 label set from issue-labels-migrate.py plus the board
# status labels, not the retired Matt Pocock role names (needs-info, ready-for-human, wontfix).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/proj"
git -C "$TMP/proj" init -q -b main
git -C "$TMP/proj" remote add origin "https://github.com/example-org/labels.git"

out="$("$ROOT/script/agent-team.sh" project "$TMP/proj" --dry-run --labels 2>&1)"
pass=0 fail=0
for name in needs-triage ready-for-agent needs-redesign needs-elon P0 P1 P2 P3 size:S size:L \
  role:pm role:qa role:ops role:secops role:growth role:support blocked owner deferred tracking \
  "status:接下來" "status:進行中" "status:等你決定"; do
  if grep -q "^would create label $name (" <<<"$out"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL missing $name"; fi
done
for name in needs-info ready-for-human wontfix; do
  if grep -q "^would create label $name (" <<<"$out"; then fail=$((fail + 1)); echo "FAIL retired $name created"; else pass=$((pass + 1)); fi
done
grep -q "on example-org/labels$" <<<"$out" || { fail=$((fail + 1)); echo "FAIL slug"; }
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
