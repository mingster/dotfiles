#!/usr/bin/env bash
# Every merge pipeline test is a head-checks command, and no two test files share a basename.
here=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
bad() { echo "FAIL: $1"; fail=1; }

for name in lead-merge lead-merge-carry lead-merge-batch merge-cleanup worker-finish head-checks heavy-gate wrap-up-cleanup post-verdict merge-fixture no-pgrep-wait pipeline-wiring; do
  [ -f "$here/script/tests/$name.test.sh" ] || continue
  grep -qxF "bash script/tests/$name.test.sh" "$here/.agents/head-checks.conf" || bad "$name.test.sh is not a command in head-checks.conf"
done

dupes=$(find "$here/script" -name '*.test.sh' -exec basename {} \; | sort | uniq -d)
[ -z "$dupes" ] || bad "shared test basenames: $dupes"

[ "$fail" -eq 0 ] && echo "pipeline-wiring: PASS"
exit "$fail"
