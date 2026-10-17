#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" WATCHDOG_TEST_ACTIONS="$tmp/actions" WATCHDOG_TEST_MODE=idle
mkdir -p "$HOME" "$tmp/bin"
cat > "$tmp/bin/orca" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]; mode=os.environ['WATCHDOG_TEST_MODE']
def output(result): print(json.dumps({'ok': True, 'result':result}))
if args[:2] == ['orchestration','run-show']:
    output({'run':{'coordinator_handle':'term_coord'}})
elif args[:2] == ['orchestration','worker-list']:
    if mode=='failed-list': sys.exit(1)
    workers=[] if mode=='empty' else [{'agentTerminalHandle':'term_worker','terminalState':'retained',
        'dispatchStatus':'dispatched','projection':{'liveness':{'verdict':'live'}}}]
    if mode=='paginated' and '--cursor' not in args:
        output({'workers':[], 'page':{'hasMore':True,'nextCursor':'page2'}})
    else: output({'workers':workers, 'page':{'hasMore':False}})
elif args[:2] == ['terminal','read']:
    if mode=='failed-read': sys.exit(1)
    if mode in ('paginated', 'failed-list'): mode='idle'
    text={'idle':'› Ask Codex to do anything', 'working':'Working (esc to interrupt)\n› Ask Codex to do anything',
          'stopped':"You've hit your usage limit", 'capacity':'No capacity available',
          'rate':'Rate limit reached', 'quota':'Quota exhausted', 'claude':'❯ ', 'empty':'Working (esc to interrupt)',
          'unavailable':'› Ask Codex to do anything'}[mode]
    output({'terminal':{'tail':text.splitlines(),'source':'screen-unavailable' if mode=='unavailable' else 'screen'}})
elif args[:2] in (['terminal','send'], ['orchestration','send']):
    with open(os.environ['WATCHDOG_TEST_ACTIONS'],'a') as f: f.write(json.dumps(args)+'\n')
    output({})
else: sys.exit(1)
PY
chmod +x "$tmp/bin/orca"
run_case() {
  rm -rf "$HOME/.orca"; : > "$tmp/actions"
  WATCHDOG_TEST_MODE=$1 bash "$root/script/worker-watchdog.sh" --run run_test --notify term_owner --notify-run run_owner --interval 0 --checks "$2"
}
count() { python3 - "$tmp/actions" "$1" <<'PY'
import json,sys
print(sum(json.loads(l)[:2] == sys.argv[2].split() for l in open(sys.argv[1])))
PY
}
run_case idle 1
[[ $(count 'terminal send') == 0 ]]
run_case idle 8
[[ $(count 'terminal send') == 2 ]] # coordinator and worker, once each despite cooldown
[[ $(count 'orchestration send') == 2 ]] # three idle checks after nudge
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
[[ $(count 'terminal send') == 2 ]]
run_case paginated 3
[[ $(count 'terminal send') == 2 && $(count 'orchestration send') == 0 ]]
# Failed worker state is unknown, never evidence for a zero-worker escalation.
run_case failed-list 3
[[ $(count 'orchestration send') == 0 ]]
run_case working 5
[[ ! -s "$tmp/actions" ]]
run_case unavailable 5
[[ ! -s "$tmp/actions" ]]
run_case stopped 3
[[ $(count 'terminal send') == 0 && $(count 'orchestration send') == 2 ]]
for stopped_mode in capacity rate quota; do
  run_case "$stopped_mode" 2
  [[ $(count 'terminal send') == 0 && $(count 'orchestration send') == 2 ]]
done
run_case claude 2
[[ $(count 'terminal send') == 2 ]]
run_case empty 3
[[ $(count 'orchestration send') == 1 ]]
# Repeatable run flags still deduplicate shared terminal handles.
rm -rf "$HOME/.orca"; : > "$tmp/actions"
WATCHDOG_TEST_MODE=idle bash "$root/script/worker-watchdog.sh" --run run_a --run run_b --notify term_owner --notify-run run_owner --interval 0 --checks 2
[[ $(count 'terminal send') == 2 ]]
if rg -q 'Ask Codex|usage limit|❯' "$HOME/.orca/logs/worker-watchdog.log"; then exit 1; fi
echo 'worker-watchdog: PASS (idle, cooldown, escalation, working, screen unavailable, stopped, Claude, empty run, multiple runs, pagination, restart/read-failure cooldown, failed worker query)'
