#!/usr/bin/env bash
# Tests for coordinator-drain.sh: the coordinator's inbox check, minus lead stop escalations and relayed worker_done.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../coordinator-drain.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/owners"
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
cat "$FAKE_CHECK"
exit "${FAKE_RC:-0}"
EOS
chmod +x "$tmp/bin/orca"
export ORCA_LOG="$tmp/orca.log" ORCA_CLI_COMMAND="$tmp/bin/orca" WORKER_DONE_OWNER_DIR="$tmp/owners" FAKE_CHECK="$tmp/check.json"
export FLEET_WATCH_CONFIG="$tmp/config.json" COORDINATOR_DRAIN_STATE="$tmp/drain-state.json"
echo '{"runs":[],"leads":[{"name":"L","terminal":"term_lead"}]}' > "$FLEET_WATCH_CONFIG"

python3 - "$tmp/check.json" <<'PY'
import json, sys
def msg(i, type_, subject, payload, frm='term_x'):
    return {'id': i, 'type': type_, 'subject': subject, 'from_handle': frm, 'sequence': 1,
            'payload': json.dumps(payload) if payload is not None else None}
stop = 'Worker stopped without reporting'
messages = [
    msg('lead_stop', 'escalation', stop, {'dispatchId': 'ctx_lead', 'handle': 'term_lead'}, 'term_lead'),
    msg('worker_stop', 'escalation', stop, {'dispatchId': 'ctx_w', 'handle': 'term_worker'}, 'term_worker'),
    msg('other_esc', 'escalation', 'Blocked: x', {'dispatchId': 'ctx_lead', 'handle': 'term_lead'}, 'term_lead'),
    msg('relayed_done', 'worker_done', 'done', {'dispatchId': 'ctx_r', 'taskId': 't'}),
    msg('plain_done', 'worker_done', 'done', {'dispatchId': 'ctx_p', 'taskId': 't'}),
    msg('odd_stop', 'escalation', stop, None, 'term_x'),
    msg('lead_stop_no_payload', 'escalation', stop, None, 'term_lead'),
]
json.dump({'ok': True, 'result': {'messages': messages, 'extra': 7}}, open(sys.argv[1], 'w'))
PY
: > "$tmp/owners/ctx_r.relayed"
run() { : > "$ORCA_LOG"; bash "$script" "$@" >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }
ids() { python3 -c "import json,sys; print(' '.join(m['id'] for m in json.load(open(sys.argv[1]))['result']['messages']))" "$tmp/out"; }

run --run run_1 --wait
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "exit 0"
grep -q -- "orchestration check --run run_1 --wait" "$ORCA_LOG" && ok || bad "arguments pass through to check"
grep -q -- "--json" "$ORCA_LOG" && ok || bad "json is requested"
[ "$(ids)" = "worker_stop other_esc plain_done odd_stop" ] && ok || bad "kept messages: $(ids)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['ok'] is True and d['result']['extra']==7 else 1)" "$tmp/out" && ok || bad "other fields keep their shape"
grep -q "dropped 3 (lead stops 2, relayed worker_done 1)" "$tmp/err" && ok || bad "drop count is logged: $(cat "$tmp/err")"

# the same messages in the bare shape
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); json.dump({'messages': d['result']['messages']}, open(sys.argv[1],'w'))" "$FAKE_CHECK"
rm -f "$COORDINATOR_DRAIN_STATE"
run --run run_1
python3 -c "import json,sys; print(' '.join(m['id'] for m in json.load(open(sys.argv[1]))['messages']))" "$tmp/out" | grep -qx "worker_stop other_esc plain_done odd_stop" && ok || bad "bare messages shape filtered"

# no leads configured: every stop passes
echo '{"runs":[]}' > "$FLEET_WATCH_CONFIG"
rm -f "$COORDINATOR_DRAIN_STATE"
run --run run_1
grep -q lead_stop_no_payload "$tmp/out" && ok || bad "no leads configured keeps every stop"
echo '{"runs":[],"leads":[{"name":"L","terminal":"term_lead"},{"name":"M","terminal":"term_lead_m"}]}' > "$FLEET_WATCH_CONFIG"

# every lead stop is dropped and counted per lead; a worker's stop always passes
stop_for() {
  python3 - "$FAKE_CHECK" "$@" <<'PY'
import json, sys
path, *pairs = sys.argv[1:]
messages = []
for pair in pairs:
    handle, ident = pair.split(':')
    messages.append({'id': ident, 'type': 'escalation', 'subject': 'Worker stopped without reporting', 'from_handle': handle,
                     'payload': json.dumps({'dispatchId': 'ctx_' + ident, 'handle': handle})})
json.dump({'ok': True, 'result': {'messages': messages}}, open(path, 'w'))
PY
}
counts() { sort "$COORDINATOR_DRAIN_STATE" | uniq -c | awk '{printf "%s%s=%s", sep, $2, $1; sep=" "}'; }
rm -f "$COORDINATOR_DRAIN_STATE"
stop_for term_lead:a1 term_lead:a2 term_lead_m:m1 term_worker:w1
run --run run_1
[ "$(ids)" = "w1" ] && ok || bad "only the worker stop passes: $(ids)"
[ "$(counts)" = "term_lead=2 term_lead_m=1" ] && ok || bad "counts per lead: $(counts)"
stop_for term_lead:a3
run --run run_1
[ "$(ids)" = "" ] && ok || bad "a repeat much later is still dropped"
[ "$(counts)" = "term_lead=3 term_lead_m=1" ] && ok || bad "counts accumulate until the digest takes them: $(counts)"
grep -q "dropped 1" "$tmp/err" && ok || bad "drop is logged"
stop_for term_worker:w2
run --run run_1
[ "$(ids)" = "w2" ] && ok || bad "worker stop passes again"
[ "$(counts)" = "term_lead=3 term_lead_m=1" ] && ok || bad "a worker stop changes no count"

# orca failure: exit code passes through
FAKE_RC=3 run --run run_1
[ "$(cat "$tmp/rc")" = 3 ] && ok || bad "check exit code passes through"

# output that is not JSON passes through unchanged
echo 'not json' > "$FAKE_CHECK"
run --run run_1
[ "$(cat "$tmp/out")" = "not json" ] && ok || bad "non JSON output is untouched"

echo "coordinator-drain: $pass passed, $fail failed"
[ "$fail" = 0 ]
