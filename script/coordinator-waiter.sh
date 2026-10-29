#!/usr/bin/env bash
# Coordinator waiter and rearm helper: drain subsequent deliveries before rearming,
# bind Run and dispatch in receipts, explicit recovery states, and crash/restart absence checks.
# Usage:
#   coordinator-waiter.sh wait --run <run> --dispatch <dispatch> [--terminal <handle>] [--timeout-ms <n>] [--types <t>] [--receipt <path>]
#   coordinator-waiter.sh ack --run <run> --dispatch <dispatch> --ack <delivery_id> [--receipt <path>]
#   coordinator-waiter.sh drain --run <run> --dispatch <dispatch> [--receipt <path>]
#   coordinator-waiter.sh arm --run <run> --dispatch <dispatch> [--terminal <handle>] [--timeout-ms <n>] [--types <t>] [--receipt <path>]
#   coordinator-waiter.sh rearm --run <run> --dispatch <dispatch> [--ack <delivery_id>] [--terminal <handle>] [--timeout-ms <n>] [--types <t>] [--receipt <path>]
#   coordinator-waiter.sh status --run <run> --dispatch <dispatch> [--receipt <path>]
set -euo pipefail

orca_cli=${ORCA_CLI_COMMAND:-orca}
state_dir=${COORDINATOR_WAITER_STATE_DIR:-${HOME:-/tmp}/.local/state/agent-team}
mkdir -p "$state_dir"

action=""
run=""
dispatch=""
terminal=""
delivery_id=""
timeout_ms=600000
types="worker_done,escalation,status,question,decision_gate"
receipt_path=""
no_activate=0

# Parse action if first argument is a command
if [ $# -gt 0 ]; then
  case "$1" in
    wait|ack|drain|arm|rearm|status)
      action="$1"; shift ;;
    --wait) action="wait"; shift ;;
    --ack) action="ack"; shift ;;
    --drain) action="drain"; shift ;;
    --arm) action="arm"; shift ;;
    --rearm) action="rearm"; shift ;;
    --status) action="status"; shift ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo "coordinator-waiter: --run needs a value" >&2; exit 2; }; run=$2; shift 2 ;;
    --dispatch|--dispatch-id) [ $# -ge 2 ] || { echo "coordinator-waiter: --dispatch needs a value" >&2; exit 2; }; dispatch=$2; shift 2 ;;
    --terminal) [ $# -ge 2 ] || { echo "coordinator-waiter: --terminal needs a value" >&2; exit 2; }; terminal=$2; shift 2 ;;
    --ack|--delivery) [ $# -ge 2 ] || { echo "coordinator-waiter: $1 needs a value" >&2; exit 2; }; delivery_id=$2; shift 2 ;;
    --timeout-ms) [ $# -ge 2 ] || { echo "coordinator-waiter: --timeout-ms needs a value" >&2; exit 2; }; timeout_ms=$2; shift 2 ;;
    --types) [ $# -ge 2 ] || { echo "coordinator-waiter: --types needs a value" >&2; exit 2; }; types=$2; shift 2 ;;
    --receipt) [ $# -ge 2 ] || { echo "coordinator-waiter: --receipt needs a value" >&2; exit 2; }; receipt_path=$2; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || { echo "coordinator-waiter: --state-dir needs a value" >&2; exit 2; }; state_dir=$2; shift 2 ;;
    --no-activate) no_activate=1; shift ;;
    *) echo "coordinator-waiter: unknown argument $1" >&2; exit 2 ;;
  esac
done

[ -n "$action" ] || action="wait"
[ -n "$run" ] || { echo "coordinator-waiter: --run is required" >&2; exit 2; }
[ -n "$dispatch" ] || { echo "coordinator-waiter: --dispatch is required" >&2; exit 2; }

[ -n "$receipt_path" ] || receipt_path="$state_dir/${run}-waiter-receipt.json"
mkdir -p "$(dirname "$receipt_path")"

pid_file="$state_dir/${run}-waiter.pid"

write_receipt() {
  local state=$1
  local del_id=${2:-}
  local count=${3:-0}
  local messages_json=${4:-"[]"}
  local waiter_armed=${5:-false}
  local waiter_pid=${6:-null}
  local drained=${7:-false}
  local live=${8:-false}

  python3 -c "
import json, sys, time

receipt = {
    'state': '$state',
    'runId': '$run',
    'dispatchId': '$dispatch',
    'deliveryId': None if '$del_id' in ('', 'null', 'None') else '$del_id',
    'count': int('$count'),
    'messages': json.loads('''$messages_json'''),
    'waiterArmed': True if '$waiter_armed'.lower() == 'true' else False,
    'waiterPid': None if '$waiter_pid' in ('', 'null', 'None') else int('$waiter_pid'),
    'drained': True if '$drained'.lower() == 'true' else False,
    'live': True if '$live'.lower() == 'true' else False,
    'timestamp': int(time.time())
}

with open('$receipt_path', 'w') as f:
    json.dump(receipt, f, indent=2)

print(json.dumps(receipt))
"
}

case "$action" in
  wait)
    # Check orca with wait
    out=""
    rc=0
    out=$("$orca_cli" orchestration check --run "$run" --wait --types "$types" --timeout-ms "$timeout_ms" --json 2>/dev/null) || rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      write_receipt "read_failure" "null" 0 "[]" false null false false
      exit 1
    fi

    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads('''$out''')
    if not data.get('ok'):
        sys.exit(2)
    res = data.get('result', {})
    state = 'delivered'
    if res.get('connectionLost') or res.get('cancelled'):
        state = 'disconnected'
    elif res.get('timedOut'):
        state = 'timeout'
    elif not res.get('deliveryId') and (res.get('count', 0) == 0 or not res.get('messages')):
        state = 'empty'

    del_id = res.get('deliveryId') or 'null'
    count = res.get('count', len(res.get('messages', [])))
    msgs = json.dumps(res.get('messages', []))
    print(f'{state}\t{del_id}\t{count}\t{msgs}')
except Exception:
    sys.exit(3)
" 2>/dev/null) || parsed=""

    if [ -z "$parsed" ]; then
      write_receipt "read_failure" "null" 0 "[]" false null false false
      exit 1
    fi

    IFS=$'\t' read -r parsed_state parsed_del parsed_count parsed_msgs <<< "$parsed"

    # Any delivery consumes the waiter; update state
    rm -f "$pid_file"
    write_receipt "$parsed_state" "$parsed_del" "$parsed_count" "$parsed_msgs" false null false false

    case "$parsed_state" in
      delivered)
        # Gate 1 (wake receipt) already written. Gate 2: live coordinator activation
        if [ -n "$terminal" ] && [ "$no_activate" -eq 0 ]; then
          "$orca_cli" terminal send --terminal "$terminal" --text "check your inbox" --enter --json >/dev/null 2>&1 || {
            echo "coordinator-waiter: live coordinator activation to $terminal failed" >&2
          }
        fi
        exit 0
        ;;
      empty|timeout)
        exit 0
        ;;
      disconnected)
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    ;;

  ack)
    [ -n "$delivery_id" ] || { echo "coordinator-waiter: --ack <delivery_id> is required for ack" >&2; exit 2; }
    out=""
    rc=0
    out=$("$orca_cli" orchestration check --run "$run" --ack "$delivery_id" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      write_receipt "ack_failure" "$delivery_id" 0 "[]" false null false false
      exit 1
    fi

    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads('''$out''')
    if not data.get('ok'):
        sys.exit(2)
    res = data.get('result', {})
    del_id = res.get('deliveryId') or 'null'
    count = res.get('count', len(res.get('messages', [])))
    msgs = json.dumps(res.get('messages', []))
    state = 'delivered' if del_id and count > 0 else 'empty'
    print(f'{state}\t{del_id}\t{count}\t{msgs}')
except Exception:
    sys.exit(3)
" 2>/dev/null) || parsed=""

    if [ -z "$parsed" ]; then
      write_receipt "ack_failure" "$delivery_id" 0 "[]" false null false false
      exit 1
    fi

    IFS=$'\t' read -r parsed_state parsed_del parsed_count parsed_msgs <<< "$parsed"
    write_receipt "$parsed_state" "$parsed_del" "$parsed_count" "$parsed_msgs" false null false false
    exit 0
    ;;

  drain)
    out=""
    rc=0
    out=$("$orca_cli" orchestration check --run "$run" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      write_receipt "read_failure" "null" 0 "[]" false null false false
      exit 1
    fi

    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads('''$out''')
    if not data.get('ok'):
        sys.exit(2)
    res = data.get('result', {})
    del_id = res.get('deliveryId') or 'null'
    count = res.get('count', len(res.get('messages', [])))
    msgs = json.dumps(res.get('messages', []))
    state = 'delivered' if del_id and count > 0 else 'empty'
    print(f'{state}\t{del_id}\t{count}\t{msgs}')
except Exception:
    sys.exit(3)
" 2>/dev/null) || parsed=""

    if [ -z "$parsed" ]; then
      write_receipt "read_failure" "null" 0 "[]" false null false false
      exit 1
    fi

    IFS=$'\t' read -r parsed_state parsed_del parsed_count parsed_msgs <<< "$parsed"
    write_receipt "$parsed_state" "$parsed_del" "$parsed_count" "$parsed_msgs" false null false false
    exit 0
    ;;

  arm)
    # Check if existing waiter is already live
    if [ -f "$pid_file" ]; then
      old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        write_receipt "already_armed" "null" 0 "[]" true "$old_pid" true true
        exit 0
      fi
    fi

    # Spawn one waiter process in background
    nohup "$0" wait --run "$run" --dispatch "$dispatch" \
      ${terminal:+--terminal "$terminal"} \
      --timeout-ms "$timeout_ms" \
      --types "$types" \
      --receipt "$state_dir/${run}-waiter.json" >/dev/null 2>&1 &
    new_pid=$!
    echo "$new_pid" > "$pid_file"
    write_receipt "armed" "null" 0 "[]" true "$new_pid" true true
    exit 0
    ;;

  rearm)
    # 1. If ack given, execute ack first
    check_args=(--run "$run" --json)
    if [ -n "$delivery_id" ]; then
      check_args=(--run "$run" --ack "$delivery_id" --json)
    fi

    out=""
    rc=0
    out=$("$orca_cli" orchestration check "${check_args[@]}" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      if [ -n "$delivery_id" ]; then
        write_receipt "ack_failure" "$delivery_id" 0 "[]" false null false false
      else
        write_receipt "read_failure" "null" 0 "[]" false null false false
      fi
      exit 1
    fi

    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads('''$out''')
    if not data.get('ok'):
        sys.exit(2)
    res = data.get('result', {})
    del_id = res.get('deliveryId') or 'null'
    count = res.get('count', len(res.get('messages', [])))
    msgs = json.dumps(res.get('messages', []))
    state = 'delivered' if del_id != 'null' and count > 0 else 'empty'
    print(f'{state}\t{del_id}\t{count}\t{msgs}')
except Exception:
    sys.exit(3)
" 2>/dev/null) || parsed=""

    if [ -z "$parsed" ]; then
      if [ -n "$delivery_id" ]; then
        write_receipt "ack_failure" "$delivery_id" 0 "[]" false null false false
      else
        write_receipt "read_failure" "null" 0 "[]" false null false false
      fi
      exit 1
    fi

    IFS=$'\t' read -r parsed_state parsed_del parsed_count parsed_msgs <<< "$parsed"

    # If subsequent deliveries exist, drain them: return receipt WITHOUT arming a waiter
    if [ "$parsed_state" = "delivered" ] && [ "$parsed_del" != "null" ]; then
      rm -f "$pid_file"
      write_receipt "delivered" "$parsed_del" "$parsed_count" "$parsed_msgs" false null false false
      exit 0
    fi

    # Inbox is drained! Now arm exactly one new waiter
    if [ -f "$pid_file" ]; then
      old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        write_receipt "already_armed" "null" 0 "[]" true "$old_pid" true true
        exit 0
      fi
    fi

    nohup "$0" wait --run "$run" --dispatch "$dispatch" \
      ${terminal:+--terminal "$terminal"} \
      --timeout-ms "$timeout_ms" \
      --types "$types" \
      --receipt "$state_dir/${run}-waiter.json" >/dev/null 2>&1 &
    new_pid=$!
    echo "$new_pid" > "$pid_file"
    write_receipt "armed" "null" 0 "[]" true "$new_pid" true true
    exit 0
    ;;

  status)
    if [ -f "$pid_file" ]; then
      old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        write_receipt "armed" "null" 0 "[]" true "$old_pid" false true
        exit 0
      fi
    fi
    # If pid dead or file absent, clean up and report absent
    rm -f "$pid_file"
    write_receipt "absent" "null" 0 "[]" false null false false
    exit 0
    ;;

  *)
    echo "coordinator-waiter: unknown action: $action" >&2
    exit 2
    ;;
esac
