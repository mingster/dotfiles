#!/usr/bin/env bash
# Observe rendered agent prompts, nudge idleness, and escalate to the owning coordinator.
# No terminal text is logged. The watchdog never stops or retries workers.
set -euo pipefail
runs=() notify='' notify_run='' interval=90 checks=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) runs+=("$2"); shift 2 ;;
    --notify) notify=$2; shift 2 ;;
    --notify-run) notify_run=$2; shift 2 ;;
    --interval) interval=$2; shift 2 ;;
    --checks) checks=$2; shift 2 ;;
    *) echo 'usage: worker-watchdog.sh --run ID [--run ID] --notify HANDLE --notify-run ID [--interval 90] [--checks N]' >&2; exit 2 ;;
  esac
done
[[ ${#runs[@]} -gt 0 && -n "$notify" && -n "$notify_run" && "$interval" =~ ^[0-9]+$ && "$checks" =~ ^[0-9]+$ ]] || exit 2
for id in "${runs[@]}" "$notify" "$notify_run"; do
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
state="$HOME/.orca/state/worker-watchdog/$notify_run"
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
escalate() {
  if bounded "$orca_cli" orchestration send --to "$notify" --run "$notify_run" --type escalation \
      --subject "Watchdog: $1" --body "$2" --json > /dev/null 2>&1; then
    log_action "escalation $1"
    return 0
  fi
  log_action "escalation-failed $1"
  return 1
}
cycle=0
while :; do
  : > "$tmp/terminals"
  for run in "${runs[@]}"; do
    if ! bounded "$orca_cli" orchestration run-show --id "$run" --json > "$tmp/run" 2>/dev/null; then
      log_action "read-run-failed $run"; continue
    fi
    if ! python3 - "$tmp/run" "$run" >> "$tmp/terminals" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r.get('ok',True)
h=r['result']['run']['coordinator_handle']
if h: print(h, sys.argv[2])
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
          escalate "zero-live-workers $run" "Run $run has zero live workers for three checks; inspect its queue and provider usage gate." || true
        fi
      fi
    else empty=0; fi
    printf '%s\n' "$empty" > "$state/run-$run"
  done
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
          escalate "provider-stopped $terminal" "Run $run terminal $terminal shows a provider capacity, quota, rate or usage limit; check fresh real provider usage and recover its queue." && alerted=1
        fi ;;
      idle)
        idle=$((idle + 1))
        if [[ "$after" -gt 0 ]]; then
          after=$((after + 1))
          if [[ "$after" -ge 4 && "$alerted" == 0 ]]; then
            escalate "idle-after-nudge $terminal" "Run $run terminal $terminal remained idle for three checks after a nudge; inspect its screen and continue its queue." && alerted=1
          fi
        fi
        if [[ "$idle" -ge 2 && $((now - last)) -ge 600 ]]; then
          if bounded "$orca_cli" terminal send --terminal "$terminal" --text 'Resume: read your inbox (orca orchestration inbox --limit 5 --full) and continue your queue; only the usage gate may stop you.' --enter --json > /dev/null 2>&1; then
            log_action "nudge $terminal run=$run"; last=$now; after=1
          else log_action "nudge-failed $terminal"; fi
        fi ;;
      *) idle=0; after=0; alerted=0 ;;
    esac
    printf '%s %s %s %s\n' "$idle" "$last" "$after" "$alerted" > "$state/term-$terminal"
  done < "$tmp/unique"
  cycle=$((cycle + 1))
  [[ "$checks" == 0 || "$cycle" -lt "$checks" ]] || break
  sleep "$interval"
done
