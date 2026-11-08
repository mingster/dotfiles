#!/usr/bin/env bash
# Behavioral tests for templates/agent-team/.claude/hooks/strikes.py (#732).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/strikes.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run_event() {
  local session="$1" event="$2" cmd="$3" output="${4:-}"
  python3 -c 'import json,sys
print(json.dumps({
  "tool_name": "Bash",
  "hook_event_name": sys.argv[2],
  "session_id": sys.argv[1],
  "tool_input": {"command": sys.argv[3]},
  "tool_response": {"stdout": sys.argv[4]}
}))' "$session" "$event" "$cmd" "$output" | HOME="$TMP" python3 "$HOOK"
}

check_three_strikes() {
  local label="$1" session="$2" cmd="$3" fail_out="$4" pass_out="$5"
  local out1 out2 out3 pre_deny pre_allow

  out1="$(run_event "$session" PostToolUse "$cmd" "$fail_out")"
  out2="$(run_event "$session" PostToolUse "$cmd" "$fail_out")"
  out3="$(run_event "$session" PostToolUse "$cmd" "$fail_out")"
  pre_deny="$(run_event "$session" PreToolUse "$cmd")"

  if grep -qF "Strike 1 of 3" <<<"$out1" \
    && grep -qF "Strike 2 of 3" <<<"$out2" \
    && grep -qF "Strike 3 of 3" <<<"$out3" \
    && grep -qF '"permissionDecision": "deny"' <<<"$pre_deny"; then
    ok "$label trips 3-strike circuit breaker"
  else
    bad "$label failed to trip 3-strike circuit breaker (out1=$out1 out3=$out3 pre=$pre_deny)"
  fi

  run_event "$session" PostToolUse "$cmd" "$pass_out" >/dev/null
  pre_allow="$(run_event "$session" PreToolUse "$cmd")"
  if [ -z "$pre_allow" ]; then
    ok "$label resets strike counter on pass"
  else
    bad "$label did not reset on pass ($pre_allow)"
  fi
}

check_three_strikes "bun test" "s-bun" "bun test a.test.ts" "1 fail" "0 fail"
check_three_strikes "playwright test" "s-pw" "bunx playwright test e2e/a.spec.ts" "1 failed" "1 passed"
check_three_strikes "bun run build" "s-build" "bun run build" "Build error occurred" "Compiled successfully"
check_three_strikes "vitest" "s-vitest" "vitest run src/a.test.ts" "Tests  1 failed (1)" "Tests  1 passed (1)"
check_three_strikes "npx vitest" "s-npx-vitest" "npx vitest run src/b.test.ts" "Tests  2 failed (2)" "Tests  2 passed (2)"
check_three_strikes "mvn test" "s-mvn-test" "mvn test" "Tests run: 3, Failures: 1, Errors: 0" "BUILD SUCCESS"
check_three_strikes "mvn verify" "s-mvn-verify" "mvn -B verify" "BUILD FAILURE" "BUILD SUCCESS"
check_three_strikes "./gradlew test" "s-gradlew-test" "./gradlew test" "FAILURE: Build failed with an exception." "BUILD SUCCESSFUL"
check_three_strikes "gradlew check" "s-gradlew-check" "gradlew check" "FAILURE: Build failed with an exception." "BUILD SUCCESSFUL"

# Tooling failure does not count as a strike
tooling_out="$(run_event "s-tooling" PostToolUse "vitest run src/a.test.ts" "Cannot find module 'zod': 1 failed")"
if grep -qF "tooling failure, not a strike" <<<"$tooling_out"; then
  ok "tooling failure is ignored for vitest"
else
  bad "tooling failure was not recognized ($tooling_out)"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
