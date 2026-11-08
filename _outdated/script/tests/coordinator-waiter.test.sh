#!/usr/bin/env bash
# Tests for coordinator waiter and rearm helper (script/coordinator-waiter.sh).
# Verifies delivery receipts, drain-before-rearm, live activation, explicit recovery
# states, and crash/restart absence checks.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: ${2:-}"; }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "exit $2"; fi; }

tmp=$(mktemp -d)
trap 'pkill -P $$ 2>/dev/null || true; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home" "$tmp/state"
export HOME="$tmp/home"
export COORDINATOR_WAITER_STATE_DIR="$tmp/state"
export ORCA_LOG="$tmp/orca.log"
export ORCA_RESPONSES_DIR="$tmp/orca_responses"
mkdir -p "$ORCA_RESPONSES_DIR"

cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "orca $*" >> "$ORCA_LOG"
case "$*" in
  *"orchestration check"*)
    if [ -n "${FAKE_CHECK_FAIL:-}" ]; then
      echo '{"ok":false,"error":"simulated check failure"}'
      exit 1
    fi
    if [ -n "${FAKE_ACK_FAIL:-}" ] && [[ "$*" == *"--ack"* ]]; then
      echo '{"ok":false,"error":"simulated ack failure"}'
      exit 1
    fi

    # Find --run argument
    cur_run=""
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      if [ "${args[i]}" = "--run" ] && [ $((i+1)) -lt ${#args[@]} ]; then
        cur_run="${args[i+1]}"
      fi
    done

    if [ -n "$cur_run" ] && [ -f "$ORCA_RESPONSES_DIR/${cur_run}.json" ]; then
      cat "$ORCA_RESPONSES_DIR/${cur_run}.json"
      [ -n "${KEEP_NEXT_CHECK:-}" ] || rm -f "$ORCA_RESPONSES_DIR/${cur_run}.json"
      exit 0
    fi
    if [ -f "$ORCA_RESPONSES_DIR/next_check.json" ]; then
      cat "$ORCA_RESPONSES_DIR/next_check.json"
      [ -n "${KEEP_NEXT_CHECK:-}" ] || rm -f "$ORCA_RESPONSES_DIR/next_check.json"
      exit 0
    fi
    echo '{"ok":true,"result":{"runId":"run_default","dispatchId":"ctx_default","deliveryId":null,"messages":[],"count":0,"replayed":false,"timedOut":false,"connectionLost":false}}'
    exit 0
    ;;
  *"terminal send"*)
    if [ -n "${FAKE_SEND_FAIL:-}" ]; then
      echo '{"ok":false,"error":"simulated terminal send failure"}'
      exit 1
    fi
    echo '{"ok":true,"result":{"sent":true}}'
    exit 0
    ;;
  *)
    echo '{"ok":true,"result":{}}'
    exit 0
    ;;
esac
EOS
chmod +x "$tmp/bin/orca"

export PATH="$tmp/bin:$PATH"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
script="$root/script/coordinator-waiter.sh"

run_waiter() {
  : > "$ORCA_LOG"
  bash "$script" "$@" >"$tmp/stdout" 2>"$tmp/stderr" || return $?
}

# --- GATE 1 & 2: Live coordinator activation & wake-after-read receipt ---
# Canned delivery 1
cat > "$ORCA_RESPONSES_DIR/run_test_1.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_1",
    "dispatchId": "ctx_worker_1",
    "deliveryId": "del_101",
    "messages": [{"id": "msg_1", "type": "worker_done", "subject": "Task done"}],
    "count": 1,
    "replayed": false,
    "timedOut": false,
    "connectionLost": false
  }
}
JSON

rc=0
run_waiter wait --run run_test_1 --dispatch ctx_worker_1 --terminal term_elon --receipt "$tmp/state/receipt1.json" || rc=$?
check "wait on delivery exits 0" "$rc"
grep -q "terminal send --terminal term_elon --text .*inbox.* --enter" "$ORCA_LOG" && ok "live coordinator activation sent to terminal" || bad "live coordinator activation" "$(cat "$ORCA_LOG")"

[ -f "$tmp/state/receipt1.json" ] && ok "wake-after-read receipt written" || bad "wake-after-read receipt file missing"
r_state=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt1.json')); print(d.get('state'))")
r_run=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt1.json')); print(d.get('runId'))")
r_dispatch=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt1.json')); print(d.get('dispatchId'))")
r_del=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt1.json')); print(d.get('deliveryId'))")
[ "$r_state" = "delivered" ] && ok "receipt state is delivered" || bad "receipt state" "$r_state"
[ "$r_run" = "run_test_1" ] && ok "receipt binds Run ID" || bad "receipt runId" "$r_run"
[ "$r_dispatch" = "ctx_worker_1" ] && ok "receipt binds dispatch ID" || bad "receipt dispatchId" "$r_dispatch"
[ "$r_del" = "del_101" ] && ok "receipt records delivery ID" || bad "receipt deliveryId" "$r_del"

# Gate separation: activation failure does not destroy receipt
cat > "$ORCA_RESPONSES_DIR/run_test_1.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_1",
    "dispatchId": "ctx_worker_1",
    "deliveryId": "del_102",
    "messages": [{"id": "msg_2", "type": "status", "subject": "Progress"}],
    "count": 1,
    "replayed": false,
    "timedOut": false,
    "connectionLost": false
  }
}
JSON
rc=0
FAKE_SEND_FAIL=1 run_waiter wait --run run_test_1 --dispatch ctx_worker_1 --terminal term_elon --receipt "$tmp/state/receipt_act_fail.json" || rc=$?
[ -f "$tmp/state/receipt_act_fail.json" ] && ok "receipt created even when terminal activation fails" || bad "receipt missing on activation failure"
act_del=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_act_fail.json')); print(d.get('deliveryId'))")
[ "$act_del" = "del_102" ] && ok "receipt intact on activation failure" || bad "receipt corrupted on activation failure"

# --- CRITERION 1: Draining subsequent deliveries before rearming ---
# When acking del_101, subsequent delivery del_103 is present in the inbox
cat > "$ORCA_RESPONSES_DIR/run_test_1.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_1",
    "dispatchId": "ctx_worker_2",
    "deliveryId": "del_103",
    "messages": [{"id": "msg_3", "type": "escalation", "subject": "Blocked"}],
    "count": 1,
    "replayed": false,
    "timedOut": false,
    "connectionLost": false
  }
}
JSON
rc=0
run_waiter rearm --run run_test_1 --dispatch ctx_worker_1 --ack del_101 --receipt "$tmp/state/receipt_drain.json" || rc=$?
check "rearm with pending delivery exits 0" "$rc"
grep -q "orchestration check --run run_test_1 --ack del_101" "$ORCA_LOG" && ok "ack del_101 sent" || bad "ack del_101 not sent"
drain_state=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_drain.json')); print(d.get('state'))")
drain_del=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_drain.json')); print(d.get('deliveryId'))")
drain_armed=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_drain.json')); print(d.get('waiterArmed'))")
[ "$drain_state" = "delivered" ] && ok "subsequent delivery captured" || bad "drain state" "$drain_state"
[ "$drain_del" = "del_103" ] && ok "subsequent deliveryId is del_103" || bad "drain delId" "$drain_del"
[ "$drain_armed" = "False" ] && ok "no new waiter armed while deliveries remain undrained" || bad "waiter armed prematurely" "$drain_armed"

# Now ack del_103, inbox is now drained (empty) -> one new waiter is armed
cat > "$ORCA_RESPONSES_DIR/run_test_1.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_1",
    "dispatchId": "ctx_worker_2",
    "deliveryId": null,
    "messages": [],
    "count": 0,
    "replayed": false,
    "timedOut": false,
    "connectionLost": false
  }
}
JSON
rc=0
run_waiter rearm --run run_test_1 --dispatch ctx_worker_2 --ack del_103 --receipt "$tmp/state/receipt_armed.json" || rc=$?
check "rearm on drained inbox exits 0" "$rc"
grep -q "orchestration check --run run_test_1 --ack del_103" "$ORCA_LOG" && ok "ack del_103 sent" || bad "ack del_103 not sent"
rearm_state=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_armed.json')); print(d.get('state'))")
rearm_armed=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_armed.json')); print(d.get('waiterArmed'))")
rearm_run=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_armed.json')); print(d.get('runId'))")
rearm_dispatch=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_armed.json')); print(d.get('dispatchId'))")
[ "$rearm_state" = "armed" ] && ok "rearm state is armed" || bad "rearm state" "$rearm_state"
[ "$rearm_armed" = "True" ] && ok "one new waiter armed after draining" || bad "waiter not armed" "$rearm_armed"
[ "$rearm_run" = "run_test_1" ] && ok "armed receipt binds runId" || bad "armed runId" "$rearm_run"
[ "$rearm_dispatch" = "ctx_worker_2" ] && ok "armed receipt binds dispatchId" || bad "armed dispatchId" "$rearm_dispatch"

# Duplicate arm call does not spawn multiple waiters
run_waiter arm --run run_test_1 --dispatch ctx_worker_2 --receipt "$tmp/state/receipt_dup.json" || true
dup_state=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_dup.json')); print(d.get('state'))")
[ "$dup_state" = "already_armed" ] || [ "$dup_state" = "armed" ] && ok "single waiter preserved" || bad "duplicate arm state" "$dup_state"

# --- CRITERION 2: Explicit recovery states ---
# State 1: empty inbox
cat > "$ORCA_RESPONSES_DIR/run_test_empty.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_empty",
    "dispatchId": "ctx_empty",
    "deliveryId": null,
    "messages": [],
    "count": 0,
    "timedOut": false,
    "connectionLost": false
  }
}
JSON
rc=0
run_waiter wait --run run_test_empty --dispatch ctx_empty --receipt "$tmp/state/receipt_empty.json" || rc=$?
check "empty inbox wait exits 0" "$rc"
s_empty=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_empty.json')); print(d.get('state'))")
[ "$s_empty" = "empty" ] && ok "recovery state empty" || bad "recovery state empty" "$s_empty"
! grep -q -- "--ack" "$ORCA_LOG" && ok "empty inbox acknowledges nothing" || bad "empty inbox acked messages"

# State 2: timeout
cat > "$ORCA_RESPONSES_DIR/run_test_timeout.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_timeout",
    "dispatchId": "ctx_timeout",
    "deliveryId": null,
    "messages": [],
    "count": 0,
    "timedOut": true,
    "connectionLost": false
  }
}
JSON
rc=0
run_waiter wait --run run_test_timeout --dispatch ctx_timeout --receipt "$tmp/state/receipt_timeout.json" || rc=$?
check "timeout wait exits 0" "$rc"
s_timeout=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_timeout.json')); print(d.get('state'))")
[ "$s_timeout" = "timeout" ] && ok "recovery state timeout" || bad "recovery state timeout" "$s_timeout"
! grep -q -- "--ack" "$ORCA_LOG" && ok "timeout acknowledges nothing" || bad "timeout acked messages"

# State 3: read failure
rc=0
FAKE_CHECK_FAIL=1 run_waiter wait --run run_test_rf --dispatch ctx_rf --receipt "$tmp/state/receipt_rf.json" || rc=$?
[ "$rc" -ne 0 ] && ok "read failure exits nonzero" || bad "read failure exit code" "$rc"
s_rf=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_rf.json')); print(d.get('state'))")
[ "$s_rf" = "read_failure" ] && ok "recovery state read_failure" || bad "recovery state read_failure" "$s_rf"

# State 4: ack failure
rc=0
FAKE_ACK_FAIL=1 run_waiter ack --run run_test_af --dispatch ctx_af --ack del_bad --receipt "$tmp/state/receipt_af.json" || rc=$?
[ "$rc" -ne 0 ] && ok "ack failure exits nonzero" || bad "ack failure exit code" "$rc"
s_af=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_af.json')); print(d.get('state'))")
[ "$s_af" = "ack_failure" ] && ok "recovery state ack_failure" || bad "recovery state ack_failure" "$s_af"

# State 5: disconnected waiter
cat > "$ORCA_RESPONSES_DIR/run_test_disc.json" <<'JSON'
{
  "ok": true,
  "result": {
    "runId": "run_test_disc",
    "dispatchId": "ctx_disc",
    "deliveryId": null,
    "messages": [],
    "count": 0,
    "timedOut": false,
    "connectionLost": true
  }
}
JSON
rc=0
run_waiter wait --run run_test_disc --dispatch ctx_disc --receipt "$tmp/state/receipt_disc.json" || rc=$?
[ "$rc" -ne 0 ] && ok "disconnected waiter exits nonzero" || bad "disconnected waiter exit code" "$rc"
s_disc=$(python3 -c "import json; d=json.load(open('$tmp/state/receipt_disc.json')); print(d.get('state'))")
[ "$s_disc" = "disconnected" ] && ok "recovery state disconnected" || bad "recovery state disconnected" "$s_disc"

# --- CRITERION 3: Crash/restart cannot leave consumed waiter recorded as live ---
# Simulate a consumed waiter: waiter consumed delivery del_101 earlier
# Check status of waiter for run_test_1:
run_waiter status --run run_test_1 --dispatch ctx_worker_2 --receipt "$tmp/state/status1.json" || true
live=$(python3 -c "import json; d=json.load(open('$tmp/state/status1.json')); print(d.get('live'))")
if [ "$live" = "False" ]; then ok "consumed waiter is not reported as live"; else bad "consumed waiter reported live" "$live"; fi
# Simulate crash: write a fake PID into state and check status
echo 999999 > "$tmp/state/run_crashed-waiter.pid"
cat > "$tmp/state/run_crashed-waiter.json" <<'JSON'
{"state": "armed", "live": true, "runId": "run_crashed", "dispatchId": "ctx_crashed", "waiterPid": 999999}
JSON
run_waiter status --run run_crashed --dispatch ctx_crashed --receipt "$tmp/state/status_crashed.json" || true
crashed_live=$(python3 -c "import json; d=json.load(open('$tmp/state/status_crashed.json')); print(d.get('live'))")
crashed_state=$(python3 -c "import json; d=json.load(open('$tmp/state/status_crashed.json')); print(d.get('state'))")
[ "$crashed_live" = "False" ] && ok "crashed waiter is not reported as live" || bad "crashed waiter reported live" "$crashed_live"
[ "$crashed_state" = "absent" ] || [ "$crashed_state" = "crashed" ] && ok "crashed waiter state reflects absence" || bad "crashed waiter state" "$crashed_state"

echo "coordinator-waiter tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
exit 0
