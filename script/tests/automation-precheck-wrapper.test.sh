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
printf '%s wrap-up-scheduled [999] round failed: repo /tmp/repo-a exit 1\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" >>"$log"
env -u WRAP_UP_SCHEDULED_LOG bash "$wrapper" wrap-up-scheduled "$log" -- true
check 'wrap-up-scheduled failed round in end summary' grep -q 'summary=round failed: repo /tmp/repo-a exit 1' "$log"
check 'wrap-up-scheduled name in trace' grep -q 'automation=wrap-up-scheduled' "$log"
check 'normal run writes exactly one phase=end line' test "$(grep -c 'phase=end' "$log")" -eq 1

# TERM: wrapper writes exactly one phase=end line with exit=143 and stops the child process group.
: >"$log"
cat >"$tmp/hang-term.sh" <<'EOS'
#!/usr/bin/env bash
sleep 3 &
printf '%s\n' "$!" >"$1"
: >"$2"
wait
EOS
chmod +x "$tmp/hang-term.sh"
bash "$wrapper" test-term "$log" -- bash "$tmp/hang-term.sh" "$tmp/grandchild.pid" "$tmp/term.ready" &
wpid=$!
i=0
while [ ! -f "$tmp/term.ready" ] && [ "$i" -lt 200 ]; do
  sleep 0.02
  i=$((i + 1))
done
gpid=$(cat "$tmp/grandchild.pid" 2>/dev/null || true)
kill -TERM "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null
term_rc=$?
pid_dead() { [ -n "$1" ] && ! kill -0 "$1" 2>/dev/null; }
check 'TERM run exits 143' test "$term_rc" -eq 143
check 'TERM run writes start line' grep -q 'phase=start' "$log"
check 'TERM run writes exactly one phase=end line' test "$(grep -c 'phase=end' "$log")" -eq 1
check 'TERM run records exit=143 in phase=end' grep -q 'phase=end exit=143 ' "$log"
check 'TERM stops child process group' pid_dead "$gpid"
[ -n "$gpid" ] && kill -KILL "$gpid" 2>/dev/null || true

# INT: wrapper writes exactly one phase=end line with exit=130.
: >"$log"
cat >"$tmp/hang-int.sh" <<'EOS'
#!/usr/bin/env bash
: >"$1"
sleep 3
EOS
chmod +x "$tmp/hang-int.sh"
set -m
bash "$wrapper" test-int "$log" -- bash "$tmp/hang-int.sh" "$tmp/int.ready" &
wpid=$!
set +m
i=0
while [ ! -f "$tmp/int.ready" ] && [ "$i" -lt 200 ]; do
  sleep 0.02
  i=$((i + 1))
done
kill -INT "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null
int_rc=$?
check 'INT run exits 130' test "$int_rc" -eq 130
check 'INT run writes exactly one phase=end line' test "$(grep -c 'phase=end' "$log")" -eq 1
check 'INT run records exit=130 in phase=end' grep -q 'phase=end exit=130 ' "$log"
pkill -P "$wpid" 2>/dev/null || true

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
