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

case7_ship_maps_its_test() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/ship.sh 2>&1)
  grep -Fq 'Selected: script/tests/ship.test.sh' <<<"$out" \
    || fail "case7 must select ship.test.sh"
  ok "case7 ship maps its test"
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
  # agent-team.test.sh + release-guard-rules.test.sh + the agent-team-*.test.sh prefix family + the always-run no-project-names guard
  want=3
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
    bash "$root/script/select-changed-script-tests.sh" --list-only script/ship.sh script/tests/ship.test.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 must not fall back when test path is already selected"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 2 ] || fail "case10 want Script tests: 2 got ${count:-0}"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/pr-review.sh script/tests/pr-review.test.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "case10 pr-review mix must not fall back"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -eq 3 ] || fail "case10 pr-review want Script tests: 3 got ${count:-0}"
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
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP="$root/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only \
    script/tests/fixtures/fleet-watch/orca-1.4.258/stall-worker-start-ok.json 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "fleet-watch stall fixture must not fall back to full suite"
  grep -Fq 'Selected: script/tests/test_fleet_watch_own_workers.py' <<<"$out" \
    || fail "fleet-watch stall fixture must select test_fleet_watch_own_workers.py"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -lt 50 ] || fail "fleet-watch stall fixture want scoped suite got ${count:-0}"
  ok "fleet-watch config example maps to fleet-watch tests"
}

case_fleet_watch_recorded_replies() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP="$root/script/script-test-skip.list" \
    bash "$root/script/select-changed-script-tests.sh" --list-only \
    script/tests/fixtures/fleet-watch/orca-1.4.258/run-list.json 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "recorded fleet-watch replies must not fall back to full suite"
  grep -Fq 'Selected: script/tests/test_fleet_watch_scan.py' <<<"$out" \
    || fail "recorded replies must select fleet-watch tests"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -lt 50 ] || fail "recorded replies want scoped suite got ${count:-0}"
  ok "recorded fleet-watch replies map to fleet-watch tests"
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
  [ "${count:-0}" -eq 3 ] || fail "case11 usage-gate pair want Script tests: 3 got ${count:-0}"

  out=$(list_selector_output templates/agent-team/changelog.d/README.md templates/agent-team/bin/changelog-compile.sh)
  grep -Fq 'Fallback:' <<<"$out" && fail "case11 agent-team pair must not fallback"
  count=$(script_tests_count_from_output <<<"$out")
  [ "${count:-0}" -eq 4 ] || fail "case11 agent-team pair want Script tests: 4 got ${count:-0}"

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

case13_lib_maps_referencing_tests() {
  local out count
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/lib/automation-path.sh 2>&1)
  grep -Fq 'Fallback:' <<<"$out" && fail "lib helper must not fall back to the full suite"
  grep -Fq 'Selected: script/tests/worker-startup.test.sh' <<<"$out" \
    || fail "lib helper must select worker-startup tests"
  grep -Fq 'Selected: script/tests/install-fleet-automations.test.sh' <<<"$out" \
    || fail "lib helper must select installer tests"
  count=$(grep -E '^Script tests: [0-9]+$' <<<"$out" | awk '{print $3}')
  [ "${count:-0}" -lt 20 ] || fail "lib helper suite too wide (${count:-0})"
  ok "case13 script/lib maps tests that reference the helper"
}

case12_no_project_names_always_selected() {
  local out path
  for path in script/tests/select-changed-script-tests.test.sh README.md; do
    out=$(SELECT_SCRIPT_TESTS_ROOT="$root" bash "$root/script/select-changed-script-tests.sh" --list-only "$path" 2>&1)
    grep -Fxq 'Selected: script/tests/no-project-names.test.sh' <<<"$out" \
      || fail "case12 no-project-names must be selected for $path"
  done
  ok "case12 no-project-names is selected for unrelated changes"
}

case1
case2
case3
case3_skip_reasons
case4_test_py
case5_py_runner
case6_pr_review
case7_ship_maps_its_test
case_fleet_watch_config_example
case_fleet_watch_recorded_replies
case8_full_suite_fallback
case9_sync_team_skills_agent_team
case10_script_plus_already_selected_test
case11_table_driven_mapped_paths
case12_no_project_names_always_selected
case13_lib_maps_referencing_tests

case14_worker_start_check() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only \
    .agents/skills/orca-team/worker-start-check.sh 2>&1)
  grep -Fq 'Selected: .agents/skills/orca-team/worker-start-check.test.sh' <<<"$out" \
    || fail "case14 must select worker-start-check.test.sh"
  grep -Fq 'Fallback:' <<<"$out" && fail "case14 must not fall back to the full suite"
  ok "case14 worker-start-check maps its test"
}

case14_worker_start_check

# #1037: a template role file change must select role-word-budget, which checks its guard sentences.
case16_template_role_file_selects_role_word_budget() {
  local out
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only \
    templates/agent-team/.claude/agents/release-manager.md 2>&1)
  grep -Fxq 'Selected: script/tests/role-word-budget.test.sh' <<<"$out" \
    || fail "case16 release-manager.md must select role-word-budget.test.sh"
  grep -Fq 'Fallback:' <<<"$out" && fail "case16 must not fall back to the full suite"
  ok "case16 template role file selects role-word-budget"
}

case16_template_role_file_selects_role_word_budget

case17_new_routing_scripts_stay_scoped() {
  local path out count
  for path in script/pr-body-gate.py script/worker-preamble.py script/setup-agent-skills.sh; do
    out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
      bash "$root/script/select-changed-script-tests.sh" --list-only "$path" 2>&1)
    grep -Fq 'Fallback:' <<<"$out" && fail "case17 $path must not fall back to the full suite"
    count=$(script_tests_count_from_output <<<"$out")
    [ "${count:-0}" -gt 0 ] || fail "case17 $path selected nothing"
    [ "${count:-0}" -lt 20 ] || fail "case17 $path suite too wide (${count:-0})"
  done
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/pr-body-gate.py 2>&1)
  grep -Fxq 'Selected: script/tests/ship.test.sh' <<<"$out" \
    || fail "case17 pr-body-gate must select ship.test.sh"
  out=$(SELECT_SCRIPT_TESTS_ROOT="$root" SELECT_SCRIPT_TESTS_SKIP=/dev/null \
    bash "$root/script/select-changed-script-tests.sh" --list-only script/setup-agent-skills.sh 2>&1)
  grep -Fxq 'Selected: script/tests/setup-user-level-team.test.sh' <<<"$out" \
    || fail "case17 setup-agent-skills must select setup-user-level-team.test.sh"
  ok "case17 routing scripts map to their tests"
}

case17_new_routing_scripts_stay_scoped

case15_parallel_jobs() {
  local fixture=$tmp/case15 out rc
  mkdir -p "$fixture/script/tests"
  printf '#!/usr/bin/env bash\necho pass-a\n' >"$fixture/script/tests/a.test.sh"
  printf '#!/usr/bin/env bash\necho pass-b\n' >"$fixture/script/tests/b.test.sh"
  printf '#!/usr/bin/env bash\necho fail-c >&2\nexit 7\n' >"$fixture/script/tests/c.test.sh"
  chmod +x "$fixture/script/tests/"*.test.sh
  rc=0
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP=/dev/null SELECT_SCRIPT_TESTS_JOBS=2 \
    bash "$root/script/select-changed-script-tests.sh" script/tests/a.test.sh script/tests/b.test.sh 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "case15 passing pair exit $rc: $out"
  grep -Fq 'pass-a' <<<"$out" && grep -Fq 'pass-b' <<<"$out" || fail "case15 missing pass lines: $out"
  rc=0
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP=/dev/null SELECT_SCRIPT_TESTS_JOBS=2 \
    bash "$root/script/select-changed-script-tests.sh" script/tests/a.test.sh script/tests/c.test.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "case15 a failing test must fail the run: $out"
  grep -Fq 'fail-c' <<<"$out" || fail "case15 missing the failing line: $out"
  ok "case15 overlapping tests keep a failing exit"
}

case15_parallel_jobs

case18_first_tests_start_first() {
  local fixture=$tmp/case18 out
  mkdir -p "$fixture/script/tests"
  for n in a b z; do printf '#!/usr/bin/env bash\necho pass-%s\n' "$n" >"$fixture/script/tests/$n.test.sh"; done
  out=$(SELECT_SCRIPT_TESTS_ROOT="$fixture" SELECT_SCRIPT_TESTS_SKIP=/dev/null SELECT_SCRIPT_TESTS_JOBS=2 \
    SELECT_SCRIPT_TESTS_FIRST='script/tests/z.* script/tests/nothing.test.sh' \
    bash "$root/script/select-changed-script-tests.sh" script/tests/a.test.sh script/tests/b.test.sh script/tests/z.test.sh 2>&1) \
    || fail "case18 run failed: $out"
  grep -Fxq 'Pool order (2 jobs): script/tests/z.test.sh script/tests/a.test.sh script/tests/b.test.sh' <<<"$out" \
    || fail "case18 z must start first: $out"
  grep -Fq 'pass-a' <<<"$out" && grep -Fq 'pass-b' <<<"$out" && grep -Fq 'pass-z' <<<"$out" || fail "case18 every test must run: $out"
  grep -Eq '^Timed script/tests/z.test.sh: [0-9]+s, exit 0$' <<<"$out" || fail "case18 each pooled test reports its time: $out"
  ok "case18 SELECT_SCRIPT_TESTS_FIRST starts its tests first"
}

case18_first_tests_start_first
echo 'PASS: 21 acceptance cases'
