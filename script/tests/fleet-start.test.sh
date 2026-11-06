#!/usr/bin/env bash
# Tests for fleet-start.sh: leads write start requests, one locked drain starts them under the coordinator's binding.
# A fake orca, a fake usage gate and a stub guard stand in for the real ones; no real worker is ever started.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../fleet-start.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/proj/.claude/hooks"

cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$1 $2" in
  "orchestration run-list") echo '{"ok":true,"result":{"runs":[{"id":"run_1"}]}}' ;;
  "orchestration worker-list") cat "$FAKE_WORKERS" ;;
  "orchestration worker-start")
    [ -z "${FAKE_START_SLEEP:-}" ] || sleep "$FAKE_START_SLEEP"
    [ -z "${FAKE_START_KILL:-}" ] || kill -9 "$PPID"
    echo '{"ok":true,"result":{"dispatch":{"dispatchId":"ctx_new'"$(grep -c 'orchestration worker-start' "$ORCA_LOG")"'"}}}' ;;
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_probe"}}}' ;;
  "terminal wait") echo '{"ok":true,"result":{"wait":{"satisfied":true,"status":"exited","exitCode":0}}}' ;;
  *) echo '{"ok":true}' ;;
esac
EOS
cat > "$tmp/bin/usage-gate" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$GATE_LOG"
case "$1" in
  pick) echo "$FAKE_PICK"; exit "${FAKE_PICK_RC:-0}" ;;
  check) echo '{"verdict":"allowed"}'; exit "${FAKE_CHECK_RC:-0}" ;;
esac
EOS
cat > "$tmp/proj/.claude/hooks/guard-bash.py" <<'EOS'
import json, os, sys
data = sys.stdin.read()
open(os.environ["GUARD_LOG"], "a").write(data + "\n")
if os.environ.get("FAKE_GUARD_DENY"):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": os.environ["FAKE_GUARD_DENY"]}}))
EOS
chmod +x "$tmp/bin/orca" "$tmp/bin/usage-gate"

root=$(cd "$here/../.." && pwd)
cat > "$tmp/config.json" <<EOF
{"local_host": "host-local", "run": "run_1", "coordinator": "term_coord",
 "placement": {"builder": ["host-local", "host-r"], "reviewer": ["host-r"]},
 "projects": {"owner/repo": "$tmp/proj", "owner/real": "$root/templates/agent-team"}}
EOF
echo '{"runs":[{"id":"run_1","terminal":"term_coord","waiter_pattern":"w"}],"fleet_config":"'"$tmp"'/fleet-config.json"}' > "$tmp/watch.json"
echo "role: fullstack-dev, issue dotfiles#574" > "$tmp/brief.md"

export ORCA_LOG="$tmp/orca.log" GATE_LOG="$tmp/gate.log" GUARD_LOG="$tmp/guard.log"
export ORCA_CLI_COMMAND="$tmp/bin/orca" FLEET_START_USAGE_GATE="$tmp/bin/usage-gate"
export FLEET_START_DIR="$tmp/requests" WORKER_DONE_OWNER_DIR="$tmp/owners"
export FLEET_START_CONFIG="$tmp/config.json" FLEET_WATCH_CONFIG="$tmp/watch.json"
export FAKE_WORKERS="$tmp/workers.json"
export FAKE_PICK='{"selected":{"provider":"claude","model":"opus","effort":"high"},"candidates":[]}'

reset() {
  rm -rf "$FLEET_START_DIR" "$WORKER_DONE_OWNER_DIR"
  : > "$ORCA_LOG"; : > "$GATE_LOG"; : > "$GUARD_LOG"
  echo '{"host_caps":{"host-local":2,"host-r":2}}' > "$tmp/fleet-config.json"
  echo '{"ok":true,"result":{"workers":[]}}' > "$FAKE_WORKERS"
  unset FAKE_START_SLEEP FAKE_START_KILL FAKE_PICK_RC FAKE_CHECK_RC FAKE_GUARD_DENY FLEET_START_NOW
}
req() {
  bash "$script" request --role fullstack-dev --brief "$tmp/brief.md" --ticket 574 --kind builder \
    --from term_lead --repo owner/repo --branch b1 "$@"
}
drain() { bash "$script" drain "$@" > "$tmp/out" 2> "$tmp/err"; echo $? > "$tmp/rc"; }
startline() { tr '\n' ' ' < "$ORCA_LOG" | grep -o 'orchestration worker-start.*' || true; }
starts() { grep -c "orchestration worker-start" "$ORCA_LOG" || true; }
queued() { ls "$FLEET_START_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
occupy() { # host
  echo '{"ok":true,"result":{"workers":[{"dispatchId":"w1","dispatchStatus":"running","projection":{"role":"builder","host":{"id":"'"$1"'"}}}]}}' > "$FAKE_WORKERS"
}

# 1. request validation: nothing is written for an incomplete request, and request never starts anything
reset
req > /dev/null 2>&1; [ "$?" = 0 ] && ok || bad "valid request exits 0"
[ "$(queued)" = 1 ] && ok || bad "one request file"
[ -z "$(ls -A "$FLEET_START_DIR" | grep -v '\.json$' || true)" ] && ok || bad "no temp file left behind"
[ ! -s "$ORCA_LOG" ] && ok || bad "request never calls orca"
reset
for missing in role brief ticket kind from repo; do
  args=(--role fullstack-dev --brief "$tmp/brief.md" --ticket 574 --kind builder --from term_lead --repo owner/repo --branch b1)
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "--$missing" ]; then unset 'args[i]' 'args[i+1]'; break; fi
  done
  bash "$script" request "${args[@]}" > /dev/null 2>&1
  [ "$?" = 2 ] && [ "$(queued)" = 0 ] && ok || bad "missing --$missing is refused at request time"
done
bash "$script" request --role fullstack-dev --brief "$tmp/brief.md" --ticket 574 --kind builder --from term_lead --repo owner/repo > /dev/null 2>&1
[ "$?" = 2 ] && ok || bad "builder without a branch is refused"
bash "$script" request --role qa --brief "$tmp/brief.md" --ticket 574 --kind reviewer --from term_lead --repo owner/repo > /dev/null 2>&1
[ "$?" = 2 ] && ok || bad "reviewer without a pr is refused"
bash "$script" request --role qa --brief "$tmp/brief.md" --ticket 574 --kind tourist --from term_lead --repo owner/repo > /dev/null 2>&1
[ "$?" = 2 ] && ok || bad "unknown kind is refused"
bash "$script" request --role qa --brief "$tmp/nope.md" --ticket 574 --kind builder --from term_lead --repo owner/repo --branch b1 > /dev/null 2>&1
[ "$?" = 2 ] && ok || bad "unreadable brief is refused"
[ "$(queued)" = 0 ] && ok || bad "refused requests leave no file"

# 2. local start: gates run, worker-start carries the coordinator binding, owner record, reply to the lead
reset
req --host host-local > /dev/null
drain
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "drain exits 0: $(cat "$tmp/err")"
[ "$(starts)" = 1 ] && ok || bad "one local start"
line=$(startline)
case "$line" in *"--run run_1"*"--from term_coord"*) ok ;; *) bad "start carries --run and --from the coordinator: $line" ;; esac
case "$line" in *"--agent claude"*"--model opus"*) ok ;; *) bad "start carries the picked agent and model: $line" ;; esac
case "$line" in *"--on "*) bad "local start has no --on" ;; *) ok ;; esac
grep -q "^pick --role fullstack-dev" "$GATE_LOG" && grep -q "^check --provider claude" "$GATE_LOG" && ok || bad "usage gate pick then check ran: $(cat "$GATE_LOG")"
grep -q '"command"' "$GUARD_LOG" && grep -q "orchestration worker-start" "$GUARD_LOG" && ok || bad "guard got the start command as PreToolUse JSON"
[ "$(cat "$WORKER_DONE_OWNER_DIR/ctx_new1" 2>/dev/null)" = "term_lead
kind=builder
repo=owner/repo
branch=b1" ] && ok || bad "owner record: $(cat "$WORKER_DONE_OWNER_DIR/ctx_new1" 2>/dev/null)"
grep -q "orchestration send --to term_lead.*dispatch=ctx_new1 host=host-local" "$ORCA_LOG" && ok || bad "lead gets dispatch id and host"
grep -q -- "--from term_coord" <(grep "orchestration send" "$ORCA_LOG") && ok || bad "reply is sent from the coordinator"
[ "$(starts)" = 1 ] && drain && [ "$(starts)" = 1 ] && ok || bad "a started request is never started again"

# 3. remote start: reviewer goes through start-remote-worker with --on, owner record lists the prs
reset
bash "$script" request --role qa --brief "$tmp/brief.md" --ticket 574 --kind reviewer --from term_lead --repo owner/repo --pr 12 --pr 13 > /dev/null
drain
[ "$(starts)" = 1 ] && ok || bad "one remote start: $(cat "$tmp/err")"
grep -q "terminal create --environment host-r" "$ORCA_LOG" && ok || bad "remote start probes the host first"
line=$(startline)
case "$line" in *"--worktree new-top-level"*"--agent claude"*"--on host-r"*) ok ;; *) bad "remote start flags: $line" ;; esac
case "$line" in *"--run run_1"*"--from term_coord"*) ok ;; *) bad "remote start keeps the coordinator binding: $line" ;; esac
[ "$(cat "$WORKER_DONE_OWNER_DIR/ctx_new1" 2>/dev/null)" = "term_lead
kind=reviewer
repo=owner/repo
pr=12
pr=13" ] && ok || bad "reviewer owner record: $(cat "$WORKER_DONE_OWNER_DIR/ctx_new1" 2>/dev/null)"

# 4. --dry-run: gates run, nothing starts, nothing is recorded
reset
req --host host-local > /dev/null
drain --dry-run
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "dry-run exits 0"
[ "$(starts)" = 0 ] && ok || bad "dry-run starts nothing"
grep -q "worker-start" "$tmp/out" && grep -q "host-local" "$tmp/out" && ok || bad "dry-run prints the planned start: $(cat "$tmp/out")"
[ "$(queued)" = 1 ] && [ -z "$(ls "$FLEET_START_DIR" | grep -v '\.json$' || true)" ] && ok || bad "dry-run writes no marker, seat or reason"
[ ! -e "$WORKER_DONE_OWNER_DIR/ctx_new1" ] && ok || bad "dry-run writes no owner record"
grep -q "orchestration send" "$ORCA_LOG" && bad "dry-run sends no reply" || ok

# 5. placement: no host named, first host in the kind's order that admits
reset
echo '{"host_caps":{"host-local":1,"host-r":2}}' > "$tmp/fleet-config.json"
occupy host-local
req > /dev/null
drain
startline | grep -q -- "--on host-r" && ok || bad "falls through to the next host: $(cat "$tmp/err")"
reset
bash "$script" request --role qa --brief "$tmp/brief.md" --ticket 574 --kind builder --from term_lead --repo owner/repo --branch b1 > /dev/null
python3 - "$tmp/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["placement"].pop("builder"); json.dump(c, open(sys.argv[1] + ".nop", "w"))
PY
FLEET_START_CONFIG="$tmp/config.json.nop" drain
[ "$(starts)" = 0 ] && [ "$(queued)" = 1 ] && ok || bad "no host and no placement stays queued"
grep -rq "placement" "$FLEET_START_DIR"/*.refused && ok || bad "placement refusal has a reason"

# 6. one free seat, two drains start exactly one
reset
echo '{"host_caps":{"host-local":1,"host-r":1}}' > "$tmp/fleet-config.json"
req --host host-local > /dev/null
drain; drain
[ "$(starts)" = 1 ] && ok || bad "second drain on the same request starts nothing"
reset
echo '{"host_caps":{"host-local":1,"host-r":1}}' > "$tmp/fleet-config.json"
req --host host-local > /dev/null
req --host host-local --branch b2 > /dev/null
drain; drain
[ "$(starts)" = 1 ] && ok || bad "two requests, one free seat: one start, got $(starts)"
[ "$(queued)" = 2 ] && ls "$FLEET_START_DIR"/*.refused > /dev/null 2>&1 && ok || bad "the second stays queued with a reason"
grep -rqi "seat\|cap" "$FLEET_START_DIR"/*.refused && ok || bad "reason names the cap"
FLEET_START_NOW=$(( $(date +%s) + 200 )) drain
[ "$(starts)" = 2 ] && ok || bad "the pending seat expires after 120 s"
reset
req --host host-local > /dev/null
FAKE_START_SLEEP=2 bash "$script" drain > /dev/null 2>&1 &
sleep 0.5
bash "$script" drain > "$tmp/out2" 2>&1
wait
[ "$(starts)" = 1 ] && ok || bad "two drains at the same time start exactly one"
grep -qi "running\|locked\|busy" "$tmp/out2" && ok || bad "the second drain says another drain holds the lock: $(cat "$tmp/out2")"

# 7. crash after the marker: never a second start, shown for a person to settle
reset
req --host host-local > /dev/null
(FAKE_START_KILL=1 bash "$script" drain > /dev/null 2>&1) 2> /dev/null
[ "$(starts)" = 1 ] && ok || bad "first drain reached worker-start"
ls "$FLEET_START_DIR"/*.starting > /dev/null 2>&1 && ok || bad "marker is written before the start"
drain
[ "$(starts)" = 1 ] && ok || bad "stale lock is taken over and the request is not started again"
id=$(basename "$(ls "$FLEET_START_DIR"/*.json)" .json)
bash "$script" settle "$id" > /dev/null 2>&1
drain
[ "$(starts)" = 2 ] && ok || bad "settle puts the request back in the queue"

# 8. gate refusals keep the request queued with the reason
refused() { # name substring
  [ "$(starts)" = 0 ] && [ "$(queued)" = 1 ] && grep -rqi "$2" "$FLEET_START_DIR"/*.refused 2>/dev/null && ok \
    || bad "$1: starts=$(starts) queued=$(queued) reasons=$(cat "$FLEET_START_DIR"/*.refused 2>/dev/null)"
  ls "$FLEET_START_DIR"/*.starting > /dev/null 2>&1 && bad "$1: no marker for a refusal" || ok
}
reset; occupy host-local; echo '{"host_caps":{"host-local":1}}' > "$tmp/fleet-config.json"
req --host host-local > /dev/null; drain; refused "admit refusal" "cap"
reset; rm "$tmp/fleet-config.json"
req --host host-local > /dev/null; drain; refused "unreadable fleet config" "fleet config"
reset; FAKE_CHECK_RC=3 req --host host-local > /dev/null; FAKE_CHECK_RC=3 drain; refused "usage check exit 3" "usage"
reset; req --host host-local > /dev/null; FAKE_PICK_RC=3 FAKE_PICK='{"selected":null,"candidates":[]}' drain; refused "usage pick exit 3" "usage"
reset; req --host host-local > /dev/null; FAKE_GUARD_DENY="grill gate: no approval" drain; refused "guard deny" "grill gate"
reset; req --host host-local > /dev/null; FAKE_PICK_RC=4 FAKE_PICK='{"selected":null,"candidates":[]}' drain; refused "no provider picked" "provider"
reset
echo "role: fullstack-dev, no issue named here" > "$tmp/brief2.md"
bash "$script" request --role fullstack-dev --brief "$tmp/brief2.md" --ticket abc --kind builder --from term_lead --repo owner/real --branch b1 --host host-local > /dev/null
drain; refused "real guard, no issue named" "issue"
reset
bash "$script" request --role fullstack-dev --brief "$tmp/brief.md" --ticket 574 --kind builder --from term_lead --repo owner/unknown --branch b1 --host host-local > /dev/null
drain; refused "repo without a guard" "guard"

# a usage exit 3 stops the whole drain, a refusal does not
reset
req --host host-local > /dev/null; req --host host-local --branch b2 > /dev/null
FAKE_PICK_RC=3 FAKE_PICK='{"selected":null,"candidates":[]}' drain
[ "$(grep -c '^pick' "$GATE_LOG")" = 1 ] && [ "$(starts)" = 0 ] && ok || bad "usage exit 3 stops the drain after one pick"
reset
req --host host-local > /dev/null; req --host host-local --branch b2 > /dev/null
FAKE_GUARD_DENY=no drain
[ "$(grep -c '^pick' "$GATE_LOG")" = 2 ] && ok || bad "a refusal moves on to the next request"

# oldest first
reset
req --host host-local --branch first > /dev/null; sleep 0.01; req --host host-local --branch second > /dev/null
echo '{"host_caps":{"host-local":5}}' > "$tmp/fleet-config.json"
drain
[ "$(starts)" = 2 ] && ok || bad "both start"
[ "$(sed -n 4p "$WORKER_DONE_OWNER_DIR/ctx_new1")" = "branch=first" ] && [ "$(sed -n 4p "$WORKER_DONE_OWNER_DIR/ctx_new2")" = "branch=second" ] && ok || bad "oldest request starts first"

# 9. delay summary
reset
for pair in "1000 1010" "2000 2030" "3000 3090"; do
  set -- $pair
  FLEET_START_NOW=$1 req --host host-local > /dev/null
  FLEET_START_NOW=$2 drain
  sleep 0.01
done
bash "$script" delay > "$tmp/out"
grep -q "count=3" "$tmp/out" && grep -q "median=30s" "$tmp/out" && grep -q "max=90s" "$tmp/out" && ok || bad "delay summary: $(cat "$tmp/out")"
reset
bash "$script" delay | grep -q "count=0" && ok || bad "delay with nothing started"

# 10. digest lines in fleet-watch: a refused request and an unknown start, each once
reset
req --host host-local > /dev/null
FAKE_GUARD_DENY="guard said no" drain
python3 - "$here/../fleet-watch.py" <<'PY' && ok || bad "digest lines"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('fleet_watch', sys.argv[1])
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
first = watch.start_notices()
assert len(first) == 1 and 'guard said no' in first[0] and 'queued' in first[0], first
assert watch.start_notices() == [], 'same reason is reported once'
PY
reset
req --host host-local > /dev/null
(FAKE_START_KILL=1 bash "$script" drain > /dev/null 2>&1) 2> /dev/null
python3 - "$here/../fleet-watch.py" <<'PY' && ok || bad "unknown-state digest line"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('fleet_watch', sys.argv[1])
watch = importlib.util.module_from_spec(spec); spec.loader.exec_module(watch)
first = watch.start_notices()
assert len(first) == 1 and 'unknown' in first[0] and 'settle' in first[0], first
assert watch.start_notices() == []
PY

echo "fleet-start: $pass passed, $fail failed"
[ "$fail" = 0 ]
