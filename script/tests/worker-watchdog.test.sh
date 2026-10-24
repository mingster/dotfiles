#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ORCA_CLI_COMMAND=orca HOME="$tmp/home" PATH="$tmp/bin:$PATH" WATCHDOG_TEST_ACTIONS="$tmp/actions" WATCHDOG_TEST_MODE=idle
mkdir -p "$HOME" "$tmp/bin"
cat > "$tmp/bin/orca" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]; mode=os.environ['WATCHDOG_TEST_MODE']
def output(result): print(json.dumps({'ok': True, 'result':result}))
if args[:2] == ['orchestration','run-show']:
    rid=args[args.index('--id')+1]
    output({'run':{'coordinator_handle':'coord_'+rid if os.environ.get('WATCHDOG_TEST_PER_RUN') else 'term_coord'}})
elif args[:2] == ['orchestration','run-list']:
    output({'runs':[{'id':r} for r in os.environ.get('WATCHDOG_TEST_RUNS','').split()]})
elif args[:2] == ['orchestration','inbox']:
    output({'messages':json.load(open(os.environ['WATCHDOG_TEST_INBOX'])) if os.environ.get('WATCHDOG_TEST_INBOX') else []})
elif args[:2] == ['orchestration','worker-list']:
    if mode=='failed-list': sys.exit(1)
    run=args[args.index('--run')+1] if '--run' in args else 'run_live'
    workers=[] if mode in ('empty','emptyidle') else [{'runId':run,'agentTerminalHandle':'term_worker','terminalState':'retained',
        'dispatchStatus':'dispatched','projection':{'liveness':{'verdict':'live'},'provider':os.environ.get('WATCHDOG_TEST_PROVIDER')}}]
    if mode=='paginated' and '--cursor' not in args:
        output({'workers':[], 'page':{'hasMore':True,'nextCursor':'page2'}})
    else: output({'workers':workers, 'page':{'hasMore':False}})
elif args[:2] == ['terminal','read']:
    if mode=='failed-read': sys.exit(1)
    if mode in ('paginated', 'failed-list'): mode='idle'
    text={'idle':'› Ask Codex to do anything', 'working':'Working (esc to interrupt)\n› Ask Codex to do anything',
          'stopped':"You've hit your usage limit", 'capacity':'No capacity available',
          'rate':'Rate limit reached', 'quota':'Quota exhausted', 'claude':'❯ ', 'empty':'Working (esc to interrupt)',
          'bgshell':'› Ask Codex to do anything\n  ⏵⏵ bypass permissions on · 1 shell', 'monitor':'❯ \n  · 1 monitor still running',
          'unavailable':'› Ask Codex to do anything', 'emptyidle':'› Ask Codex to do anything',
          'banner':'Gemini 3 Pro\nModel quota reached for Gemini. Resets in 94h29m\n› '}[mode]
    output({'terminal':{'tail':text.splitlines(),'source':'screen-unavailable' if mode=='unavailable' else 'screen'}})
elif args[:2] == ['orchestration','task-list']:
    output({'tasks':[] if os.environ.get('WATCHDOG_TEST_TASKS')=='none' else [{'status':'pending'}]})
elif args[:2] in (['terminal','send'], ['orchestration','send']):
    with open(os.environ['WATCHDOG_TEST_ACTIONS'],'a') as f: f.write(json.dumps(args)+'\n')
    if os.environ.get('WATCHDOG_TEST_SEND_FAIL') and args[0]=='orchestration': sys.exit(1)
    if args[0]=='orchestration' and args[args.index('--to')+1]==os.environ.get('WATCHDOG_TEST_FAIL_TO'): sys.exit(1)
    output({})
else: sys.exit(1)
PY
cat > "$tmp/bin/ps" <<'SH'
#!/bin/sh
[ -n "${WATCHDOG_TEST_PS:-}" ] && { printf '%s\n' "$WATCHDOG_TEST_PS"; exit 0; }
exec /bin/ps "$@"
SH
chmod +x "$tmp/bin/orca" "$tmp/bin/ps"
run_case() {
  rm -rf "$HOME/.orca"; : > "$tmp/actions"
  WATCHDOG_TEST_MODE=$1 bash "$root/script/worker-watchdog.sh" --run run_test --notify term_owner --notify-run run_owner --interval 0 --checks "$2"
}
pass=0 fail=0
# check ACTUAL EXPECTED [LABEL]: a failed bare [[ ]] does not trip set -e in bash 3.2, so count every assert.
check() {
  if [[ $1 == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL line ${BASH_LINENO[0]}: got '$1', want '$2' ${3:-}" >&2; fi
}
check_empty() { check "$(wc -c < "$1" | tr -d ' ')" 0 "($1 not empty)"; }
count() { python3 - "$tmp/actions" "$1" <<'PY'
import json,sys
print(sum(json.loads(l)[:2] == sys.argv[2].split() for l in open(sys.argv[1])))
PY
}
run_case idle 1
check "$(count 'terminal send')" 0 "terminal send"
run_case idle 8
check "$(count 'terminal send')" 1 "terminal send" # worker once despite cooldown; its coordinator waits on it and is never nudged
check "$(count 'orchestration send')" 1 "orchestration send" # three idle checks after nudge
python3 - "$tmp/actions" <<'PY'
import json,sys
for row in map(json.loads,open(sys.argv[1])):
    if row[:2]==['terminal','send']:
        assert '--enter' in row and 'Resume: read your inbox' in ' '.join(row)
    else:
        assert row[row.index('--to')+1]=='term_owner'
        assert row[row.index('--run')+1]=='run_owner'
PY
# A restart and a screen read failure must retain each terminal's ten-minute cooldown.
WATCHDOG_TEST_MODE=failed-read bash "$root/script/worker-watchdog.sh" --run run_test --notify term_owner --notify-run run_owner --interval 0 --checks 1
WATCHDOG_TEST_MODE=idle bash "$root/script/worker-watchdog.sh" --run run_test --notify term_owner --notify-run run_owner --interval 0 --checks 2
check "$(count 'terminal send')" 1 "terminal send" # worker only; the busy coordinator is never nudged
run_case paginated 3
check "$(count 'terminal send')" 1 "terminal send"; check "$(count 'orchestration send')" 0 "orchestration send"
# Failed worker state is unknown, never evidence for a zero-worker escalation.
run_case failed-list 3
check "$(count 'orchestration send')" 0 "orchestration send"
run_case working 5
check_empty "$tmp/actions"
run_case unavailable 5
check_empty "$tmp/actions"
run_case stopped 3
check "$(count 'terminal send')" 0 "terminal send"; check "$(count 'orchestration send')" 2 "orchestration send"
for stopped_mode in capacity rate quota; do
  run_case "$stopped_mode" 2
  check "$(count 'terminal send')" 0 "terminal send"; check "$(count 'orchestration send')" 2 "orchestration send"
done
run_case claude 2
check "$(count 'terminal send')" 1 "terminal send"
# A coordinator with no live worker really is idle and is still nudged.
run_case emptyidle 2
check "$(count 'terminal send')" 1 "terminal send"
grep -q term_coord "$tmp/actions"
run_case empty 3
check "$(count 'orchestration send')" 1 "orchestration send"
# One escalation per empty episode, even when the send is rejected.
run_case empty 8
check "$(count 'orchestration send')" 1 "orchestration send"
WATCHDOG_TEST_SEND_FAIL=1 run_case empty 8
check "$(count 'orchestration send')" 1 "orchestration send"
# A finished run (no pending or ready tasks) with zero workers is not an alarm.
WATCHDOG_TEST_TASKS=none run_case empty 5
check "$(count 'orchestration send')" 0 "orchestration send"
# A prompt waiting on a background shell or monitor is not idle: no nudge, no idle-after-nudge escalation.
for waiting_mode in bgshell monitor; do
  run_case "$waiting_mode" 8
  check_empty "$tmp/actions"
done
# A coordinator with no live worker but an armed `check --run RUN --wait` waiter is not escalated; an idle one still is.
WATCHDOG_TEST_TASKS=none run_case emptyidle 8
check "$(count 'terminal send')" 1 "terminal send"; check "$(count 'orchestration send')" 1 "orchestration send"
grep -q 'idle-after-nudge term_coord' "$tmp/actions"
WATCHDOG_TEST_PS='orca orchestration check --run run_test --wait --timeout-ms 900000' WATCHDOG_TEST_TASKS=none run_case emptyidle 8
check_empty "$tmp/actions"
WATCHDOG_TEST_PS='orca orchestration check --run run_other --wait' WATCHDOG_TEST_TASKS=none run_case emptyidle 8
check "$(count 'orchestration send')" 1 "orchestration send"
# Repeatable run flags still deduplicate shared terminal handles.
rm -rf "$HOME/.orca"; : > "$tmp/actions"
WATCHDOG_TEST_MODE=idle bash "$root/script/worker-watchdog.sh" --run run_a --run run_b --notify term_owner --notify-run run_owner --interval 0 --checks 2
check "$(count 'terminal send')" 1 "terminal send"
# --all-runs: only runs with a live worker are watched, and each escalates to its own coordinator.
export WATCHDOG_TEST_PER_RUN=1 WATCHDOG_TEST_RUNS='run_live run_dead'
rm -rf "$HOME/.orca"; : > "$tmp/actions"
WATCHDOG_TEST_MODE=idle bash "$root/script/worker-watchdog.sh" --all-runs --interval 0 --checks 8
python3 - "$tmp/actions" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sends=[r for r in rows if r[:2]==['orchestration','send']]
assert len(sends)==1 and all(x[x.index('--to')+1]=='coord_run_live' and x[x.index('--run')+1]=='run_live' for x in sends), rows
assert not any('run_dead' in ' '.join(r) for r in rows), rows
PY
# Unread reports: one escalation per message, only when old, unread and of a report type.
now_old=2020-01-01T00:00:00Z; now_new=$(date -u +%FT%TZ)
python3 - "$tmp/inbox.json" "$now_old" "$now_new" <<'PY'
import json,sys
m=lambda i,t,c,r=0,run='run_live':{'id':i,'run_id':run,'type':t,'read':r,'created_at':c}
json.dump([m('msg_a','worker_done',sys.argv[2]), m('msg_b','escalation',sys.argv[2]), m('msg_new','question',sys.argv[3]),
           m('msg_read','worker_done',sys.argv[2],1), m('msg_status','status',sys.argv[2]), m('msg_other','worker_done',sys.argv[2],0,'run_dead')],open(sys.argv[1],'w'))
PY
export WATCHDOG_TEST_INBOX="$tmp/inbox.json"
rm -rf "$HOME/.orca"; : > "$tmp/actions"
WATCHDOG_TEST_MODE=working bash "$root/script/worker-watchdog.sh" --all-runs --interval 0 --checks 3
check "$(count 'orchestration send')" 2 "orchestration send"
grep -q 'unread-report msg_a' "$tmp/actions" && grep -q 'unread-report msg_b' "$tmp/actions"
! grep -q 'msg_new\|msg_read\|msg_status\|msg_other' "$tmp/actions"
# A failed send lands in alerts.log; the third consecutive failure is flagged.
rm -rf "$HOME/.orca"; : > "$tmp/actions";
WATCHDOG_TEST_SEND_FAIL=1 WATCHDOG_TEST_MODE=working bash "$root/script/worker-watchdog.sh" --all-runs --interval 0 --checks 1
check "$(grep -c 'undelivered (run run_live): unread-report' "$HOME/.orca/state/worker-watchdog/alerts.log")" 2
# An unreachable run coordinator falls back to the --fallback-run mailbox, as an escalation.
rm -rf "$HOME/.orca"; : > "$tmp/actions"
WATCHDOG_TEST_FAIL_TO=coord_run_live WATCHDOG_TEST_MODE=working bash "$root/script/worker-watchdog.sh" --all-runs --fallback-run run_elon --interval 0 --checks 1
check "$(grep -c '"run:run_elon", "--run", "run_elon", "--type", "escalation"' "$tmp/actions")" 2
! grep -q 'undelivered' "$HOME/.orca/state/worker-watchdog/alerts.log"
rm -rf "$HOME/.orca"
python3 - "$tmp/inbox.json" "$now_old" <<'PY'
import json,sys
json.dump([{'id':'msg_%d'%i,'run_id':'run_live','type':'worker_done','read':0,'created_at':sys.argv[2]} for i in range(3)],open(sys.argv[1],'w'))
PY
WATCHDOG_TEST_SEND_FAIL=1 WATCHDOG_TEST_MODE=working bash "$root/script/worker-watchdog.sh" --all-runs --interval 0 --checks 1
grep -q '3 consecutive watchdog sends failed' "$HOME/.orca/state/worker-watchdog/alerts.log"
unset WATCHDOG_TEST_PER_RUN WATCHDOG_TEST_RUNS WATCHDOG_TEST_INBOX
# An Antigravity quota banner blocks its pool until reset; other providers are never fed to the parser.
export USAGE_GATE_BANNER_FILE="$tmp/banner.json"
WATCHDOG_TEST_PROVIDER=codex run_case banner 2
check "$([[ -e $USAGE_GATE_BANNER_FILE ]] && echo exists)" "" "banner file"
WATCHDOG_TEST_PROVIDER=antigravity run_case banner 2
python3 - "$USAGE_GATE_BANNER_FILE" <<'PY'
import json,sys,time
left=json.load(open(sys.argv[1]))['gemini']-time.time()
assert 94*3600+28*60 < left <= 94*3600+29*60, left
PY
WATCHDOG_TEST_PROVIDER=antigravity run_case idle 1
if grep -Eq 'Ask Codex|usage limit|❯' "$HOME/.orca/logs/worker-watchdog.log"; then exit 1; fi
# Without timeout or gtimeout (stock macOS) a hanging command must still be cut off.
nt="$tmp/no-timeout"; mkdir -p "$nt"
for f in /bin/* /usr/bin/* "$(command -v python3)" "$(command -v bash)"; do
  case ${f##*/} in timeout|gtimeout) continue ;; esac
  ln -sf "$f" "$nt/${f##*/}" 2> /dev/null || true
done
cat > "$tmp/bin/orca" <<'SH'
#!/bin/sh
exec sleep 30
SH
rm -rf "$HOME/.orca"; : > "$tmp/actions"
PATH="$nt" env -i HOME="$HOME" PATH="$nt" ORCA_CLI_COMMAND="$tmp/bin/orca" WATCHDOG_BOUND_SECONDS=1 \
  bash -c 'command -v timeout gtimeout && exit 1; exec bash "$0" "$@"' "$root/script/worker-watchdog.sh" \
  --run run_test --notify term_owner --notify-run run_owner --interval 0 --checks 1 &
hang_pid=$!
for _ in $(seq 1 100); do kill -0 "$hang_pid" 2> /dev/null || break; sleep 0.1; done
if kill -0 "$hang_pid" 2> /dev/null; then kill "$hang_pid"; echo 'watchdog hung without timeout binary' >&2; exit 1; fi
wait "$hang_pid"
grep -q 'read-run-failed run_test' "$HOME/.orca/logs/worker-watchdog.log"
echo "worker-watchdog: $pass passed, $fail failed"
[[ $fail == 0 ]] || exit 1
echo 'worker-watchdog: PASS (idle, cooldown, escalation, working, screen unavailable, stopped, Claude, background shell or monitor, armed --wait waiter, empty run, multiple runs, pagination, restart/read-failure cooldown, failed worker query, Antigravity quota banner, no timeout binary, all-runs discovery, unread reports, alerts.log fallback)'
