#!/usr/bin/env bash
# Tests for lead-send.sh with a fake orca (no live Orca). bash 3.2 compatible.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/calls.log"
case "$*" in
  "orchestration run-list --limit 100 --cursor c2"*)
    echo '{"result":{"runs":[{"id":"run_new","coordinator_handle":"term_lead","created_at":"2026-10-21T01:00:00Z"}]}}' ;;
  "orchestration run-list"*)
    if [ -n "$FAKE_EMPTY" ]; then echo '{"result":{"runs":[]}}'; exit 0; fi
    echo '{"result":{"runs":[{"id":"run_elon","coordinator_handle":null,"created_at":"2026-10-21T02:00:00Z"},{"id":"run_old","coordinator_handle":"term_lead","created_at":"2026-10-20T13:00:00Z"}],"nextCursor":"c2"}}' ;;
  "orchestration send"*) [ -z "$FAKE_SEND_FAIL" ] || exit 1; echo '{"ok":true,"result":{"message":{"id":"msg_1"}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp" ORCA_TERMINAL_HANDLE=term_elon
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

out=$("$here/lead-send.sh" --lead term_lead --subject "go" --body "details" 2>&1); rc=$?
check "sends to the newest Run the lead coordinates, across pages" "$([ $rc = 0 ] && [ "$out" = "run_new msg_1" ]; echo $?)"
check "send goes to run:<id> as status with --from" "$(grep 'orchestration send' "$tmp/calls.log" | grep -q -- '--to run:run_new --type status --subject go --body details --from term_elon'; echo $?)"

: > "$tmp/calls.log"
"$here/lead-send.sh" --lead term_lead --subject s --type decision_gate --from term_x >/dev/null 2>&1
check "--type and --from override the defaults" "$(grep 'orchestration send' "$tmp/calls.log" | grep -q -- '--type decision_gate --subject s --from term_x'; echo $?)"

: > "$tmp/calls.log"
FAKE_EMPTY=1 "$here/lead-send.sh" --lead term_lead --subject s >/dev/null 2>&1; rc=$?
check "a lead with no Run exits 1 and sends nothing" "$([ $rc = 1 ] && ! grep -q 'orchestration send' "$tmp/calls.log"; echo $?)"

FAKE_SEND_FAIL=1 "$here/lead-send.sh" --lead term_lead --subject s >/dev/null 2>&1
check "a failed send exits 1" "$([ $? = 1 ]; echo $?)"

: > "$tmp/calls.log"
"$here/lead-send.sh" --subject s >/dev/null 2>&1; rc=$?
check "missing --lead exits 2 with no orca call" "$([ $rc = 2 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"

echo "lead-send: $pass passed, $fail failed"
[ "$fail" = 0 ]
