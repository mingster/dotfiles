#!/usr/bin/env bash
# head-checks wires select-changed-script-tests; merge pipeline scripts map to tests; no duplicate basenames.
here=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
bad() { echo "FAIL: $1"; fail=1; }

grep -q 'SELECT_SCRIPT_TESTS_SKIP=/dev/null bash script/select-changed-script-tests.sh {files}' \
  "$here/.agents/head-checks.conf" \
  || bad "head-checks.conf must invoke select-changed-script-tests.sh with {files} and SELECT_SCRIPT_TESTS_SKIP=/dev/null"

check_maps() {
  local script_path=$1 min_count=${2:-1} out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$here" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$here/script/select-changed-script-tests.sh" --list-only "$script_path" 2>&1)
  count=$(grep -c '^Selected: ' <<<"$out" || true)
  [ "$count" -ge "$min_count" ] || bad "$script_path maps to $count test(s), want >= $min_count"
}

check_maps script/lead-merge.sh 2
check_maps script/wrap-up.sh 1
check_maps script/head-checks.sh 1
check_maps script/heavy-gate.py 1
check_maps script/post-verdict.sh 1
check_maps script/coordinator-publication.sh 1
check_maps script/on-worker-done.sh 2
check_maps script/fleet-watch.py 1

dupes=$(find "$here/script" -name '*.test.sh' -exec basename {} \; | sort | uniq -d)
[ -z "$dupes" ] || bad "shared test basenames: $dupes"

[ "$fail" -eq 0 ] && echo "pipeline-wiring: PASS"
exit "$fail"
