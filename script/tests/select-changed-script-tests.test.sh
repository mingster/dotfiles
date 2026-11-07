#!/usr/bin/env bash
# Acceptance cases 1 to 3 for issue script test checks on hosted runners.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $*"; }

case1() {
  local fixture=$tmp/case1
  mkdir -p "$fixture/script/tests"
  printf '#!/usr/bin/env bash\necho "case1-touch"\n' >"$fixture/script/touched.sh"
  printf '#!/usr/bin/env bash\necho "FAIL: expected red line"\necho "FAIL: expected red line" >&2\nexit 9\n' >"$fixture/script/tests/touched.test.sh"
  chmod +x "$fixture/script/tests/touched.test.sh"
  local out rc=0
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" bash "$root/script/select-changed-script-tests.sh" script/touched.sh 2>&1) || rc=$?
  [ "$rc" -eq 9 ] || fail "case1 exit want 9 got $rc"
  grep -Fq 'Selected: script/tests/touched.test.sh' <<<"$out" || fail "case1 missing selected path"
  grep -Fq 'FAIL: expected red line' <<<"$out" || fail "case1 missing failing line"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" bash "$root/script/select-changed-script-tests.sh" --list-only script/tests/touched.test.sh 2>&1)
  grep -Fq 'Selected: script/tests/touched.test.sh' <<<"$out" || fail "case1 direct test touch"
  ok "case1 touch runs mapped test and surfaces failing line"
}

case2() {
  local wf=$root/.github/workflows/script-tests.yml
  grep -q 'runs-on: ubuntu-latest' "$wf" || fail "case2 missing ubuntu-latest"
  grep -Eq 'self-hosted|runs-on:.*\[.*self' "$wf" && fail "case2 must not use self-hosted runners"
  ok "case2 workflow uses github hosted ubuntu runners only"
}

case3() {
  local fixture=$tmp/case3
  mkdir -p "$fixture/script/tests"
  printf '#!/usr/bin/env bash\n' >"$fixture/script/heavy-gate.sh"
  printf '#!/usr/bin/env bash\necho "would lock host"\n' >"$fixture/script/tests/heavy-gate.test.sh"
  chmod +x "$fixture/script/tests/heavy-gate.test.sh"
  printf '%s\n' \
    'script/tests/heavy-gate.test.sh uses heavy-gate host lock; rerun on coordinator host' \
    >"$fixture/script/script-test-skip.list"
  local out rc=0
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP="$fixture/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/heavy-gate.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "case3 exit want 0 got $rc"
  grep -Fq 'UNCHECKED: script/tests/heavy-gate.test.sh uses heavy-gate host lock; rerun on coordinator host' <<<"$out" \
    || fail "case3 missing UNCHECKED line"
  grep -Fq 'Skipped: script/tests/heavy-gate.test.sh' <<<"$out" || fail "case3 missing Skipped line"
  grep -Fq 'Selected: script/tests/heavy-gate.test.sh' <<<"$out" && fail "case3 must not mark skipped test selected"
  ok "case3 skip list prints UNCHECKED and does not select the test"
}

case1
case2
case3
echo 'PASS: 3 acceptance cases'
