#!/usr/bin/env bash
# Observe rendered agent prompts, nudge idleness, and escalate to the owning coordinator.
# No terminal text is logged. The watchdog never stops or retries workers.
set -euo pipefail
runs=() notify='' notify_run='' interval=90 checks=0 all=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-runs) all=1; shift ;;
    --run) runs+=("$2"); shift 2 ;;
    --notify) notify=$2; shift 2 ;;
    --notify-run) notify_run=$2; shift 2 ;;
    --interval) interval=$2; shift 2 ;;
    --checks) checks=$2; shift 2 ;;
    *) echo 'usage: worker-watchdog.sh (--all-runs | --run ID [--run ID] --notify HANDLE --notify-run ID) [--interval 90] [--checks N]' >&2; exit 2 ;;
  esac
done
[[ "$interval" =~ ^[0-9]+$ && "$checks" =~ ^[0-9]+$ ]] || exit 2
[[ "$all" == 1 || (${#runs[@]} -gt 0 && -n "$notify" && -n "$notify_run") ]] || exit 2
[[ "$all" == 1 ]] && notify_run=all-runs
for id in ${runs[@]+"${runs[@]}"} ${notify:+"$notify"} "$notify_run"; do
  [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
done
orca_cli=${ORCA_CLI_COMMAND:-orca}
gate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage-gate.py"
# Bound every external command so a hung CLI cannot stall the loop.
# macOS ships no timeout, so fall back to perl, where alarm survives exec and kills the command.
bound=${WATCHDOG_BOUND_SECONDS:-30}
bounded() {
  if command -v timeout > /dev/null 2>&1; then timeout "$bound" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then gtimeout "$bound" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$bound" "$@"
  fi
}
root="$HOME/.orca/state/worker-watchdog"
state="$root/$notify_run"
alerts="$root/alerts.log"
log="$HOME/.orca/logs/worker-watchdog.log"
mkdir -p "$state" "$(dirname "$log")"
# One monitor per notification run; preserve counters/cooldowns across launchd restarts.
if ! mkdir "$state/lock" 2>/dev/null; then
  old_pid=$(cat "$state/lock/pid" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then exit 0; fi
  rm -rf "$state/lock"
  mkdir "$state/lock"
fi
printf '%s\n' "$$" > "$state/lock/pid"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$state/lock"' EXIT
trap 'exit 0' INT TERM
log_action() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$log"; }
# Alerts that cannot be delivered must still reach a human: alerts.log plus a macOS notification.
alert_fallback() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$alerts"
  if command -v osascript > /dev/null 2>&1; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Worker watchdog"' -e 'end run' "$1" > /dev/null 2>&1 || true
  fi
}
# escalate RUN SUBJECT BODY: send to that run's coordinator on that run.
escalate() {
  local run=$1 to=$notify rr=$notify_run fails=0
  if [[ "$all" == 1 ]]; then to=$(cat "$tmp/coord-$run" 2>/dev/null || true); rr=$run; fi
  [[ ! -f "$state/send-fails" ]] || read -r fails < "$state/send-fails"
  if [[ -n "$to" ]] && bounded "$orca_cli" orchestration send --to "$to" --run "$rr" --type status \
      --subject "Watchdog: $2" --body "$3" --json > /dev/null 2>&1; then
    log_action "escalation $2"
    alert_fallback "sent (run $rr): $2"
    printf '0\n' > "$state/send-fails"
    return 0
  fi
  log_action "escalation-failed $2"
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$state/send-fails"
  alert_fallback "undelivered (run $rr): $2. $3"
  [[ "$fails" != 3 ]] || alert_fallback "3 consecutive watchdog sends failed; coordinators are not reachable"
  return 1
}
# Page through run-list or worker-list, printing the run ids that qualify.
list_runs() {
  local kind=$1 cursor='' n=0
  while [[ $n -lt 20 ]]; do
    args=(orchestration "$kind-list" --limit 100 --json)
    [[ -z "$cursor" ]] || args+=(--cursor "$cursor")
    bounded "$orca_cli" "${args[@]}" > "$tmp/page" 2>/dev/null || return 1
    python3 - "$kind" "$tmp/page" > "$tmp/pageout" 2>/dev/null <<'PY' || return 1
import json,sys
r=json.load(open(sys.argv[2])); assert r.get('ok',True); r=r['result']
if sys.argv[1]=='worker':
    for w in r['workers']:
        if w.get('terminalState') in ('active','retained') and w.get('runId'): print('run',w['runId'])
    p=r.get('page',{}); print('cursor',p.get('nextCursor') or '' if p.get('hasMore') else '')
else:
    for x in r['runs']: print('run',x['id'])
    print('cursor',r.get('nextCursor') or '')
PY
    sed -n 's/^run //p' "$tmp/pageout"
    cursor=$(sed -n 's/^cursor //p' "$tmp/pageout")
    [[ -n "$cursor" ]] || return 0
    n=$((n + 1))
  done
}
cycle=0
while :; do
  : > "$tmp/terminals"; : > "$tmp/busy-coord"
  if [[ "$all" == 1 ]]; then
    runs=()
    if list_runs worker | sort -u > "$tmp/active-runs" && list_runs run | sort -u > "$tmp/known-runs"; then
      while read -r id; do
        [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]] && runs+=("$id")
      done < <(comm -12 "$tmp/active-runs" "$tmp/known-runs")
    else log_action "discover-runs-failed"; fi
  fi
  for run in "${runs[@]}"; do
    if ! bounded "$orca_cli" orchestration run-show --id "$run" --json > "$tmp/run" 2>/dev/null; then
      log_action "read-run-failed $run"; continue
    fi
    if ! python3 - "$tmp/run" "$run" "$tmp/coord-$run" >> "$tmp/terminals" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r.get('ok',True)
h=r['result']['run']['coordinator_handle']
if h:
    print(h, sys.argv[2]); open(sys.argv[3],'w').write(h)
PY
    then log_action "parse-run-failed $run"; continue; fi
    live=0 cursor='' complete=1
    while :; do
      args=(orchestration worker-list --run "$run" --limit 100 --json)
      [[ -z "$cursor" ]] || args+=(--cursor "$cursor")
      if ! bounded "$orca_cli" "${args[@]}" > "$tmp/workers" 2>/dev/null; then
        complete=0; log_action "read-workers-failed $run"; break
      fi
      if ! python3 - "$tmp/workers" > "$tmp/parsed" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r.get('ok',True)
r=r['result']; page=r.get('page',{})
for w in r['workers']:
    if (w.get('terminalState') in ('active','retained') and w.get('dispatchStatus') not in ('completed','failed','cancelled','abandoned')
        and w.get('projection',{}).get('liveness',{}).get('verdict') != 'exited'):
        h=w.get('agentTerminalHandle')
        if h: print('terminal',h,str((w.get('projection') or {}).get('provider') or 'none').lower())
if page.get('hasMore'):
    assert page.get('nextCursor')
    print('cursor',page['nextCursor'])
PY
      then complete=0; log_action "parse-workers-failed $run"; break; fi
      cursor=''
      while read -r kind value provider; do
        if [[ "$kind" == terminal ]]; then
          printf '%s %s %s\n' "$value" "$run" "${provider:-none}" >> "$tmp/terminals"
          live=$((live + 1))
        else cursor=$value; fi
      done < "$tmp/parsed"
      [[ -n "$cursor" ]] || break
    done
    # A coordinator waits on its workers in the background, so its prompt looks idle; do not nudge it.
    [[ "$live" -lt 1 ]] || { cat "$tmp/coord-$run"; echo; } >> "$tmp/busy-coord" 2>/dev/null || true
    empty=0
    [[ ! -f "$state/run-$run" ]] || read -r empty < "$state/run-$run"
    if [[ "$complete" == 1 && "$live" == 0 ]]; then
      # A run with no pending or ready tasks is finished, not stuck. Unreadable queue counts as finished.
      pending=0
      if bounded "$orca_cli" orchestration task-list --run "$run" --json > "$tmp/tasks" 2>/dev/null; then
        pending=$(python3 - "$tmp/tasks" <<'PY' 2>/dev/null || echo 0
import json,sys
r=json.load(open(sys.argv[1]))['result']
print(sum(t.get('status') in ('pending','ready') for t in r['tasks']))
PY
)
      else log_action "read-tasks-failed $run"; fi
      if [[ "${pending:-0}" == 0 ]]; then empty=0
      elif [[ "$empty" -lt 3 ]]; then
        empty=$((empty + 1))
        # Once per empty episode, whether or not the send succeeds. Stays at 3 until a live worker resets it.
        if [[ "$empty" == 3 ]]; then
          escalate "$run" "zero-live-workers $run" "Run $run has zero live workers for three checks; inspect its queue and provider usage gate." || true
        fi
      fi
    else empty=0; fi
    printf '%s\n' "$empty" > "$state/run-$run"
  done
  # A report its coordinator has not read for 5 minutes means nobody is reading. inbox lists without consuming.
  if [[ ${#runs[@]} -gt 0 ]] && bounded "$orca_cli" orchestration inbox --limit 200 --json > "$tmp/inbox" 2>/dev/null; then
    touch "$state/unread-alerted"
    if python3 - "$tmp/inbox" "$state/unread-alerted" "${runs[@]}" > "$tmp/unread" 2>/dev/null <<'PY'
import json,sys,calendar,time
r=json.load(open(sys.argv[1])); assert r.get('ok',True)
seen=set(open(sys.argv[2]).read().split()); runs=set(sys.argv[3:])
for m in r['result']['messages']:
    age=time.time()-calendar.timegm(time.strptime(m['created_at'],'%Y-%m-%dT%H:%M:%SZ'))
    if m.get('run_id') in runs and not m.get('read') and m.get('type') in ('worker_done','escalation','question') and age>=300 and m['id'] not in seen:
        print(m['id'],m['run_id'],m['type'])
PY
    then
      while read -r id run type; do
        [[ "$id" =~ ^[a-zA-Z0-9_-]+$ && "$run" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        printf '%s\n' "$id" >> "$state/unread-alerted"
        escalate "$run" "unread-report $id" "Run $run has an unread $type message $id older than 5 minutes; its coordinator is not reading. Run: orca orchestration check --run $run" || true
      done < "$tmp/unread"
    else log_action "parse-inbox-failed"; fi
  fi
  sort -u -k1,1 "$tmp/terminals" > "$tmp/unique"
  while read -r terminal run provider; do
    [[ "$terminal" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
    if ! bounded "$orca_cli" terminal read --terminal "$terminal" --screen --limit 24 --json > "$tmp/screen" 2>/dev/null; then
      log_action "read-screen-failed $terminal"
      last=0
      [[ ! -f "$state/term-$terminal" ]] || read -r _ last _ _ < "$state/term-$terminal"
      printf '0 %s 0 0\n' "$last" > "$state/term-$terminal"
      continue
    fi
    if [[ "${provider:-none}" == antigravity ]]; then
      # Antigravity shows a quota banner instead of an error; record it so the pool stays blocked.
      if python3 - "$tmp/screen" > "$tmp/banner" 2>/dev/null <<'PY'
import json,re,sys
t=json.load(open(sys.argv[1]))['result']['terminal']
tail=t.get('tail',[])
if t.get('source')=='screen':
    print(re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','','\n'.join(tail if isinstance(tail,list) else tail.splitlines())))
PY
      then
        [[ ! -s "$tmp/banner" ]] || bounded python3 "$gate" banner < "$tmp/banner" > /dev/null 2>&1 || log_action "banner-failed $terminal"
      fi
    fi
    if ! observation=$(python3 - "$tmp/screen" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); assert r.get('ok',True)
t=r['result']['terminal']
if t.get('source')!='screen': print('unknown'); sys.exit()
tail=t.get('tail',[])
s='\n'.join(tail[-24:] if isinstance(tail,list) else tail.splitlines()[-24:])
s=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',s)
if re.search(r"(?:you(?:'ve| have)? (?:hit|reached|exceeded).*?(?:usage|rate|quota|capacity).*?limit|(?:usage|rate) limit (?:reached|exceeded)|(?:at|over) capacity|(?:no|insufficient) capacity(?: available)?|quota (?:exceeded|exhausted)|out of (?:usage|quota)|hit your limit)",s,re.I):
    print('stopped')
elif re.search(r'\bWorking\b|esc to interrupt',s,re.I): print('working')
elif 'Ask Codex to do anything' in s or re.search(r'^\s*[❯>]\s*$',s,re.M): print('idle')
else: print('unknown')
PY
    ); then observation=unknown; fi
    idle=0 last=0 after=0 alerted=0
    [[ ! -f "$state/term-$terminal" ]] || read -r idle last after alerted < "$state/term-$terminal"
    now=$(date +%s)
    case "$observation" in
      stopped)
        idle=0; after=0
        if [[ "$alerted" == 0 ]]; then
          escalate "$run" "provider-stopped $terminal" "Run $run terminal $terminal shows a provider capacity, quota, rate or usage limit; check fresh real provider usage and recover its queue." && alerted=1
        fi ;;
      idle)
        if grep -qx -- "$terminal" "$tmp/busy-coord"; then idle=0; after=0; alerted=0; else
        idle=$((idle + 1))
        if [[ "$after" -gt 0 ]]; then
          after=$((after + 1))
          if [[ "$after" -ge 4 && "$alerted" == 0 ]]; then
            escalate "$run" "idle-after-nudge $terminal" "Run $run terminal $terminal remained idle for three checks after a nudge; inspect its screen and continue its queue." && alerted=1
          fi
        fi
        if [[ "$idle" -ge 2 && $((now - last)) -ge 600 ]]; then
          if bounded "$orca_cli" terminal send --terminal "$terminal" --text 'Resume: read your inbox (orca orchestration inbox --limit 5 --full) and continue your queue; only the usage gate may stop you.' --enter --json > /dev/null 2>&1; then
            log_action "nudge $terminal run=$run"; last=$now; after=1
          else log_action "nudge-failed $terminal"; fi
        fi
        fi ;;
      *) idle=0; after=0; alerted=0 ;;
    esac
    printf '%s %s %s %s\n' "$idle" "$last" "$after" "$alerted" > "$state/term-$terminal"
  done < "$tmp/unique"
  cycle=$((cycle + 1))
  [[ "$checks" == 0 || "$cycle" -lt "$checks" ]] || break
  sleep "$interval"
done
