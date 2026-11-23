#!/usr/bin/env bash
# head-checks, coordinator-publication, live-check-server and doc-fact-check print "<script>: <flag> needs a value" on stderr and exit 2 when a flag is the last argument.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
check() {
  local script="$1" flag="$2" rc=0 err
  err="$(bash "$ROOT/script/$script.sh" "$flag" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$err" = "$script: $flag needs a value" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $script $flag rc=$rc err=$err"
  fi
}
check head-checks --repo
check head-checks --config
check coordinator-publication --repo
check coordinator-publication --body-file
check live-check-server --repo
check live-check-server --port
check doc-fact-check --repo
check doc-fact-check --head
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
