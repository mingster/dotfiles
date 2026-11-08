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
  local wf=$root/.github/workflows/checks.yml
  grep -q 'runs-on: ubuntu-latest' "$wf" || fail "case2 missing ubuntu-latest"
  grep -Eq 'self-hosted|runs-on:.*\[.*self' "$wf" && fail "case2 must not use self-hosted runners"
  grep -q 'script-tests:' "$wf" || fail "case2 missing script-tests job"
  grep -q 'shellcheck:' "$wf" || fail "case2 missing shellcheck job"
  ok "case2 Checks workflow uses github hosted ubuntu runners only"
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

case6_pr_review() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/pr-review.sh 2>&1)
  grep -Fq 'Selected: script/tests/pr-review.test.sh' <<<"$out" \
    || fail "case6 must select pr-review.test.sh"
  ok "case6 pr-review maps its shell test"
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
  local out count want f
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/agent-team.sh 2>&1)
  grep -Fq 'Selected: script/agent-team.test.sh' <<<"$out" \
    || fail "case9 must select agent-team.test.sh for agent-team.sh"
  grep -Fq 'Selected: script/tests/release-guard-rules.test.sh' <<<"$out" \
    || fail "case9 must select release-guard-rules.test.sh for agent-team.sh"
  grep -Fq 'Selected: script/tests/agent-team-guard-migration.test.sh' <<<"$out" \
    || fail "case9 must select agent-team-guard-migration.test.sh for agent-team.sh"
  grep -Fq 'Selected: script/tests/agent-team-project-gaps.test.sh' <<<"$out" \
    || fail "case9 must select agent-team-project-gaps.test.sh for agent-team.sh"
  # agent-team.test.sh + release-guard-rules.test.sh + the agent-team-*.test.sh prefix family
  want=2
  for f in "$root"/script/tests/agent-team-*.test.sh; do
    [ -e "$f" ] || continue
    grep -Fq "Selected: script/tests/$(basename "$f")" <<<"$out" \
      || fail "case9 must select $(basename "$f") for agent-team.sh"
    want=$((want + 1))
  done
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq "$want" ] || fail "case9 want Script tests: $want got ${count:-0}"
  ok "case9 agent-team maps agent-team, release-guard-rules and the agent-team-* family"
}

case10_script_plus_already_selected_test() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/lead-merge.sh script/tests/lead-merge.test.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 must not fall back when test path is already selected"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 7 ] || fail "case10 want Script tests: 7 got ${count:-0}"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/pr-review.sh script/tests/pr-review.test.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 pr-review mix must not fall back"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 2 ] || fail "case10 pr-review want Script tests: 2 got ${count:-0}"
  ok "case10 script plus already-selected test avoids full-suite fallback"
}

case_fleet_watch_config_example() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP="$root/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/fleet-watch.config.example.json 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "fleet-watch config example must not fall back to full suite"
  grep -Fq 'Selected: script/tests/test_fleet_watch_scan.py' <<<"$out" \
    || fail "fleet-watch config must select test_fleet_watch_scan.py"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -lt 50 ] || fail "fleet-watch config want scoped suite got ${count:-0}"
  ok "fleet-watch config example maps to fleet-watch tests"
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

list_selector_output() {
  SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only "$@" 2>&1
}

script_tests_count_from_output() {
  grep -E '^Script tests: [0-9]+$' | awk '{print $3}'
}

case11_table_driven_mapped_paths() {
  local path rel out alone combo count partner other
  local -a mapped_paths=()
  local -a candidates=()
  partner='script/agent-team.sh'
  other='templates/agent-team/changelog.d/README.md'

  while IFS= read -r rel; do
    candidates+=("$rel")
  done < <(find "$root/script" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) \
    | sed "s|^$root/||" | LC_ALL=C sort -u)

  candidates+=(
    'templates/agent-team/changelog.d/README.md'
    'templates/agent-team/bin/changelog-compile.sh'
    'script/usage-gate.py'
    'script/usage-gate-hook.py'
  )
  while IFS= read -r rel; do
    candidates+=("$rel")
  done < <(find "$root/.agents/skills/orca-team" -type f 2>/dev/null | sed "s|^$root/||" | LC_ALL=C sort | head -3)

  while IFS= read -r rel; do
    candidates+=("$rel")
  done < <(find "$root/script/tests" -maxdepth 1 -type f \( -name '*.test.sh' -o -name '*.test.py' -o -name 'test_*.py' \) \
    | sed "s|^$root/||" | LC_ALL=C sort | head -5)

  for path in "${candidates[@]}"; do
    [ -e "$root/$path" ] || continue
    out=$(list_selector_output "$path")
    if grep -Fq 'Fallback:' <<<"$out"; then
      continue
    fi
    count=$(script_tests_count_from_output <<<"$out")
    [ "${count:-0}" -gt 0 ] || continue
    mapped_paths+=("$path")
  done
  [ "${#mapped_paths[@]}" -gt 0 ] || fail "case11 discovered zero mapped paths"

  for path in "${mapped_paths[@]}"; do
    if [ "$path" = "$partner" ]; then
      combo=$(list_selector_output "$path" "$other")
    else
      combo=$(list_selector_output "$path" "$partner")
    fi
    grep -Fq 'Fallback:' <<<"$combo" \
      && fail "case11b mapped path plus another mapped path must not fallback: $path"
    count=$(script_tests_count_from_output <<<"$combo")
    [ "${count:-0}" -lt 50 ] || fail "case11b combo looks like full suite ($count): $path"
  done

  out=$(list_selector_output script/usage-gate.py script/usage-gate-hook.py)
  grep -Fq 'Fallback:' <<<"$out" && fail "case11 usage-gate pair must not fallback"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -eq 2 ] || fail "case11 usage-gate pair want Script tests: 2 got ${count:-0}"

  out=$(list_selector_output templates/agent-team/changelog.d/README.md templates/agent-team/bin/changelog-compile.sh)
  grep -Fq 'Fallback:' <<<"$out" && fail "case11 agent-team pair must not fallback"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -eq 2 ] || fail "case11 agent-team pair want Script tests: 2 got ${count:-0}"

  out=$(list_selector_output script/unmapped-helper.sh)
  grep -Fq 'Fallback: script/unmapped-helper.sh -> full suite' <<<"$out" \
    || fail "case11c unmapped must fallback"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -gt 50 ] || fail "case11c unmapped want full suite size got ${count:-0}"

  out=$(list_selector_output script/head-checks-tsc.sh)
  grep -Fq 'Fallback: script/head-checks-tsc.sh -> full suite' <<<"$out" \
    || fail "case11c head-checks-tsc must fallback when unmapped"

  ok "case11 table-driven mapped paths avoid duplicate-selection fallback"
}

case1
case2
case3
case3_skip_reasons
case4_test_py
case5_py_runner
case6_pr_review
case7_lead_merge_prefix
case_fleet_watch_config_example
case8_full_suite_fallback
case9_sync_team_skills_agent_team
case10_script_plus_already_selected_test
case11_table_driven_mapped_paths
echo 'PASS: 13 acceptance cases'
