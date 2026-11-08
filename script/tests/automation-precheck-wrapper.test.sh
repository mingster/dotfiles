#!/usr/bin/env bash
# automation-precheck-wrapper.sh: traceable start and end lines for failed and skipped runs.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
wrapper="$root/script/automation-precheck-wrapper.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log="$tmp/run.log"
passed=0
failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed + 1)); else printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); fi; }
line_count() { [ -f "$log" ] && wc -l <"$log" | tr -d ' ' || echo 0; }

# Failing inner command still leaves start and end trace lines.
: >"$log"
WRAP_UP_SCHEDULED_LOG="$log" bash "$wrapper" test-fail "$log" -- false
rc=$?
check 'wrapper exits 1 for Orca precheck contract' test "$rc" -eq 1
check 'failed run has a start line' grep -q 'phase=start' "$log"
check 'failed run has an end line' grep -q 'phase=end exit=1' "$log"
check 'failed run end names exit code' grep -q 'summary=failed inner exit 1' "$log"
check 'trace line includes automation name' grep -q 'automation=test-fail' "$log"

# Skipped inner run sets summary via AUTOMATION_TRACE_SUMMARY.
: >"$log"
skip_body='#!/usr/bin/env bash
printf "skip body\n"
[ -n "${AUTOMATION_TRACE_SUMMARY_FILE:-}" ] && printf "%s\n" "skip: dry run only" >"$AUTOMATION_TRACE_SUMMARY_FILE"
exit 0'
printf '%s\n' "$skip_body" >"$tmp/skip.sh"
chmod +x "$tmp/skip.sh"
bash "$wrapper" test-skip "$log" -- bash "$tmp/skip.sh"
check 'skipped run has start and end' test "$(line_count)" -ge 2
check 'skipped summary is traced' grep -q 'summary=skip: dry run only' "$log"

# wrap-up-scheduled: a failed round line in the log path must reach the trace end summary even when
# WRAP_UP_SCHEDULED_LOG is not exported on the wrapper (only on the inner env, as install-fleet does).
: >"$log"
printf '%s wrap-up-scheduled [999] round failed: repo /tmp/riben exit 1\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$log"
env -u WRAP_UP_SCHEDULED_LOG bash "$wrapper" wrap-up-scheduled "$log" -- true
check 'wrap-up-scheduled failed round in end summary' grep -q 'summary=round failed: repo /tmp/riben exit 1' "$log"
check 'wrap-up-scheduled name in trace' grep -q 'automation=wrap-up-scheduled' "$log"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
