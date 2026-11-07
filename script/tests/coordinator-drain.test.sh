#!/usr/bin/env bash
# Tests for coordinator-drain.sh: the coordinator's inbox check, minus lead stop escalations and relayed worker_done.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
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
n=$(grep -c . "$ORCA_LOG")
if [ -f "$FAKE_CHECK.$n" ]; then cat "$FAKE_CHECK.$n"; else cat "$FAKE_CHECK"; fi
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
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
printf sent > "$tmp/owners/ctx_r.relayed"
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

# a real "Worker stopped without reporting" message from the orca inbox history (task title shortened):
# fields are from/to/priority/handled, the payload is an object (taskId, dispatchId, and handle and stopReason in the real inbox)
cat > "$tmp/real-stop.json" <<'EOF'
{"ok": true, "result": {"messages": [{"id": "msg_stop_99abc148847c07b338443838", "type": "escalation", "from": "term_bbf7aacf-877a-4e75-a645-48930ae14b15", "to": "run:run_e7d1ee648485", "subject": "Worker stopped without reporting", "priority": "high", "handled": true, "body": "Worker term_bbf7aacf-877a-4e75-a645-48930ae14b15 ended its turn without sending worker_done for task \"lead lane\" (task_aabff3336d2a).\nThe Dispatch is still open. Answer it wi\u2026 (truncated; --full)", "payload": {"taskId": "task_aabff3336d2a", "dispatchId": "ctx_0ce3068d6d5d"}}]}}
EOF
echo '{"runs":[],"leads":[{"name":"L","terminal":"term_bbf7aacf-877a-4e75-a645-48930ae14b15"}]}' > "$FLEET_WATCH_CONFIG"
rm -f "$COORDINATOR_DRAIN_STATE"
cp "$tmp/real-stop.json" "$FAKE_CHECK"
run --run run_1
[ "$(ids)" = "" ] && ok || bad "real lead stop is dropped: $(ids)"
[ "$(counts)" = "term_bbf7aacf-877a-4e75-a645-48930ae14b15=1" ] && ok || bad "real lead stop is counted: $(counts)"
echo '{"runs":[],"leads":[{"name":"L","terminal":"term_other"}]}' > "$FLEET_WATCH_CONFIG"
run --run run_1
[ "$(ids)" = "msg_stop_99abc148847c07b338443838" ] && ok || bad "the same real stop from a worker passes"


# an empty or half written .relayed marker is not "sent": the message is kept
printf '' > "$tmp/owners/ctx_p.relayed"
echo '{"runs":[],"leads":[{"name":"L","terminal":"term_lead"}]}' > "$FLEET_WATCH_CONFIG"
python3 - "$FAKE_CHECK" <<'PY'
import json, sys
json.dump({'ok': True, 'result': {'messages': [{'id': 'plain_done', 'type': 'worker_done', 'subject': 'done', 'from_handle': 'term_x', 'payload': json.dumps({'dispatchId': 'ctx_p'})}]}}, open(sys.argv[1], 'w'))
PY
run --run run_1
[ "$(ids)" = "plain_done" ] && ok || bad "an empty marker is not sent: $(ids)"
printf 'sen' > "$tmp/owners/ctx_p.relayed"
run --run run_1
[ "$(ids)" = "plain_done" ] && ok || bad "a half written marker is not sent: $(ids)"
# the drain is not a writer: the sweep is the only one that writes <dispatch>.done.json
printf 'term_lead\nkind=builder\nrepo=o/n\nbranch=b\n' > "$tmp/owners/ctx_p"
rm -f "$tmp/owners/ctx_p.relayed"
run --run run_1
[ "$(ids)" = "plain_done" ] && [ ! -e "$tmp/owners/ctx_p.done.json" ] && ok || bad "drain leaves no done.json"
grep -q 'done.json\|def save' "$script" && bad "drain script must not mention done.json or save" || ok

# --wait: a pass where every message is dropped checks again instead of returning empty
stop_for term_lead:a1 term_lead:a2
cp "$FAKE_CHECK" "$FAKE_CHECK.1"
python3 - "$FAKE_CHECK" <<'PY'
import json, sys
json.dump({'ok': True, 'result': {'messages': [{'id': 'w_real', 'type': 'worker_done', 'subject': 'done', 'from_handle': 'term_x', 'payload': json.dumps({'dispatchId': 'ctx_zz'})}]}}, open(sys.argv[1], 'w'))
PY
run --run run_1 --wait
[ "$(ids)" = "w_real" ] && [ "$(grep -c 'orchestration check' "$ORCA_LOG")" = 2 ] && ok || bad "all dropped with --wait: checks again and returns the next batch: $(ids) / $(cat "$ORCA_LOG")"
echo '{"ok":true,"result":{"messages":[]}}' > "$FAKE_CHECK"
stop_for term_lead:a3; cp "$FAKE_CHECK" "$FAKE_CHECK.1"
echo '{"ok":true,"result":{"messages":[]}}' > "$FAKE_CHECK"
run --run run_1 --wait
[ "$(ids)" = "" ] && [ "$(cat "$tmp/rc")" = 0 ] && [ "$(grep -c 'orchestration check' "$ORCA_LOG")" = 2 ] && ok || bad "all dropped, then the wait times out empty: returns empty"
stop_for term_lead:a4
run --run run_1
[ "$(ids)" = "" ] && [ "$(grep -c 'orchestration check' "$ORCA_LOG")" = 1 ] && ok || bad "without --wait an all dropped batch returns at once"
rm -f "$FAKE_CHECK".[0-9]
FAKE_RC=3 run --run run_1 --wait
[ "$(cat "$tmp/rc")" = 3 ] && [ "$(grep -c 'orchestration check' "$ORCA_LOG")" = 1 ] && ok || bad "a failing check is not retried"

# fleet-watch finds the waiter with pgrep -f <waiter_pattern>; with the drain as parent the pattern still matches
echo '{"ok":true,"result":{"messages":[]}}' > "$FAKE_CHECK"
FAKE_SLEEP=3 bash "$script" --run run_pat --wait > /dev/null 2>&1 &
drain_pid=$!
sleep 1
pgrep -f 'orchestration check --run run_pat' > /dev/null && ok || bad "waiter_pattern 'orchestration check --run <run>' matches while the drain waits"
pgrep -f 'coordinator-drain.sh --run run_pat' > /dev/null && ok || bad "waiter_pattern 'coordinator-drain.sh --run <run>' matches the drain"
wait "$drain_pid"

# orca failure: exit code passes through
FAKE_RC=3 run --run run_1
[ "$(cat "$tmp/rc")" = 3 ] && ok || bad "check exit code passes through"

# output that is not JSON passes through unchanged
echo 'not json' > "$FAKE_CHECK"
run --run run_1
[ "$(cat "$tmp/out")" = "not json" ] && ok || bad "non JSON output is untouched"

# default path: FLEET_WATCH_CONFIG unset reads $HOME/.config/fleet-watch/config.json. A config there with no leads key
# (the coordinator's own file) must say so on stderr instead of letting every lead stop through quietly
# HOME changes below, and a version manager's python3 shim needs the real HOME, so put the real interpreter first on PATH
mkdir -p "$tmp/home/.config/fleet-watch"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/bin/python3"
echo '{"local_host":"h","host_caps":{}}' > "$tmp/home/.config/fleet-watch/config.json"
rm -f "$FAKE_CHECK".* "$COORDINATOR_DRAIN_STATE"
cp "$tmp/real-stop.json" "$FAKE_CHECK"
env -u FLEET_WATCH_CONFIG HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c ': > "$ORCA_LOG"; bash "$0" --run run_1 >"$1/out" 2>"$1/err"' "$script" "$tmp"
grep -q "no leads" "$tmp/err" && ok || bad "default config without a leads key says so on stderr: $(cat "$tmp/err")"
grep -q "$tmp/home/.config/fleet-watch/config.json" "$tmp/err" && ok || bad "the warning names the config it read: $(cat "$tmp/err")"
[ "$(ids)" = "msg_stop_99abc148847c07b338443838" ] && ok || bad "without leads the stop still passes: $(ids)"
echo '{"leads":[{"name":"L","terminal":"term_bbf7aacf-877a-4e75-a645-48930ae14b15"}]}' > "$tmp/home/.config/fleet-watch/config.json"
env -u FLEET_WATCH_CONFIG HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash -c ': > "$ORCA_LOG"; bash "$0" --run run_1 >"$1/out" 2>"$1/err"' "$script" "$tmp"
[ "$(ids)" = "" ] && ok || bad "default config with leads drops the lead stop: $(ids)"
grep -q "no leads" "$tmp/err" && bad "no warning when the config has leads" || ok

echo "coordinator-drain: $pass passed, $fail failed"
[ "$fail" = 0 ]
