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

case3_skip_reasons() {
  local fixture=$tmp/case3b
  mkdir -p "$fixture/script/tests"
  printf '#!/usr/bin/env bash\n' >"$fixture/script/bare.sh"
  printf '#!/usr/bin/env bash\n' >"$fixture/script/tests/bare.test.sh"
  chmod +x "$fixture/script/tests/bare.test.sh"
  printf '%s\n' 'script/tests/bare.test.sh' >"$fixture/script/script-test-skip.list"
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP="$fixture/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/bare.sh 2>&1)
  grep -Fq 'UNCHECKED: script/tests/bare.test.sh skipped on hosted runner' <<<"$out" \
    || fail "case3b bare skip must use default reason without stray brace"
  grep -Fq 'UNCHECKED: script/tests/bare.test.sh }' <<<"$out" && fail "case3b must not append stray brace"
  printf '%s\n' \
    'script/tests/bare.test.sh needs coordinator host' \
    >"$fixture/script/script-test-skip.list"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP="$fixture/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/bare.sh 2>&1)
  grep -Fq 'UNCHECKED: script/tests/bare.test.sh needs coordinator host' <<<"$out" \
    || fail "case3b named skip reason missing or mangled"
  grep -Eq 'needs coordinator host\}' <<<"$out" && fail "case3b reason must not end with stray brace"
  ok "case3b skip reasons default and explicit without stray brace"
}

case4_test_py() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" bash "$root/script/select-changed-script-tests.sh" --list-only \
    script/tests/audit-guards.test.py 2>&1)
  grep -Fq 'Selected: script/tests/audit-guards.test.py' <<<"$out" || fail "case4 must select *.test.py on direct touch"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" bash "$root/script/select-changed-script-tests.sh" --list-only \
    script/start-cursor-worker.sh 2>&1)
  grep -Fq 'Selected: script/start-cursor-worker.test.sh' <<<"$out" || fail "case4 must select co-located script/*.test.sh"
  grep -Fq 'Selected: script/tests/start-cursor-worker.test.sh' <<<"$out" \
    && fail "case4 must not select removed duplicate tests path"
  ok "case4 selects script/tests/*.test.py and co-located script/*.test.sh"
}

case5_py_runner() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" bash "$root/script/select-changed-script-tests.sh" --list-only \
    script/run-scoped-tests.py 2>&1)
  grep -Fq 'Selected: script/tests/run-scoped-tests.test.py' <<<"$out" \
    || fail "case5 script/run-scoped-tests.py must select its *.test.py"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" bash "$root/script/select-changed-script-tests.sh" \
    script/tests/audit-guards.test.py 2>&1) || fail "case5 *.test.py must run and pass: $out"
  grep -Eq 'Ran [1-9][0-9]* tests?' <<<"$out" || fail "case5 *.test.py must run at least one test"
  ok "case5 runs *.test.py files directly and maps script/*.py to them"
}

case6_on_worker_done() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/on-worker-done.sh 2>&1)
  grep -Fq 'Selected: script/tests/on-worker-done.test.sh' <<<"$out" \
    || fail "case6 must select on-worker-done.test.sh"
  grep -Fq 'Selected: script/tests/test_on_worker_done.py' <<<"$out" \
    || fail "case6 must select test_on_worker_done.py"
  ok "case6 on-worker-done maps shell and python tests"
}

case7_lead_merge_prefix() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/lead-merge.sh 2>&1)
  grep -Fq 'Selected: script/tests/lead-merge.test.sh' <<<"$out" \
    || fail "case7 must select lead-merge.test.sh"
  grep -Fq 'Selected: script/tests/lead-merge-batch.test.sh' <<<"$out" \
    || fail "case7 must select lead-merge-batch.test.sh"
  ok "case7 lead-merge maps base and prefix family tests"
}

case9_sync_team_skills_agent_team() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/sync-team-skills.sh 2>&1)
  grep -Fq 'Selected: script/tests/sync-team-skills.test.sh' <<<"$out" \
    || fail "case9 must select script/tests/sync-team-skills.test.sh for sync-team-skills.sh"
  grep -Fq 'Selected: script/agent-team.test.sh' <<<"$out" \
    || fail "case9 must select agent-team.test.sh for sync-team-skills.sh"
  grep -Fq 'Selected: script/tests/release-guard-rules.test.sh' <<<"$out" \
    || fail "case9 must select release-guard-rules.test.sh for sync-team-skills.sh"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 3 ] || fail "case9 want Script tests: 3 got ${count:-0}"
  ok "case9 sync-team-skills maps base test plus agent-team and release-guard-rules"
}

case10_script_plus_already_selected_test() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/lead-merge.sh script/tests/lead-merge.test.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 must not fall back when test path is already selected"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 7 ] || fail "case10 want Script tests: 7 got ${count:-0}"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/on-worker-done.sh script/tests/test_on_worker_done.py 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 on-worker-done mix must not fall back"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 2 ] || fail "case10 on-worker-done want Script tests: 2 got ${count:-0}"
  ok "case10 script plus already-selected test avoids full-suite fallback"
}

case8_full_suite_fallback() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/unmapped-helper.sh 2>&1)
  grep -Fq 'Fallback: script/unmapped-helper.sh -> full suite' <<<"$out" \
    || fail "case8 missing fallback line"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -gt 1 ] || fail "case8 want Script tests > 1 got ${count:-0}"
  grep -Fq 'Script tests: 0' <<<"$out" && fail "case8 must never report zero script tests"
  ok "case8 unmapped script falls back to full suite"
}

case1
case2
case3
case3_skip_reasons
case4_test_py
case5_py_runner
case6_on_worker_done
case7_lead_merge_prefix
case8_full_suite_fallback
case9_sync_team_skills_agent_team
case10_script_plus_already_selected_test
echo 'PASS: 11 acceptance cases'
