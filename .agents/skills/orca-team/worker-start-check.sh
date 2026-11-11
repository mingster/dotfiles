#!/usr/bin/env bash
# worker-start-check.sh [--screen-only] <dispatch_id> [seconds]
# Run after every `orca orchestration worker-start`. Exit 0 when the Dispatch is running or settled
# and its screen is not the Antigravity sign-in step. Exit 1 when it failed, was not accepted within
# the wait (default 120 seconds), or the screen says "You are currently not signed in. Select login method".
# --screen-only exits 1 only for that sign-in step; a slow or failed start stays 0.
# Prints the state. The sign-in failure is on stderr.
set -u
screen_only=0
if [ "${1:-}" = --screen-only ]; then
  screen_only=1
  shift
fi
dispatch=${1:-}
wait=${2:-120}
orca=${ORCA_CLI_COMMAND:-orca}
[ -n "$dispatch" ] || { echo "usage: worker-start-check.sh [--screen-only] <dispatch_id> [seconds]" >&2; exit 2; }
command -v jq >/dev/null || { echo "worker-start-check requires jq" >&2; exit 2; }
command -v python3 >/dev/null || { echo "worker-start-check requires python3" >&2; exit 2; }

terminal_handle() { # <worker-show json>
  jq -er '
    def as_handle:
      if type == "string" and length > 0 then .
      elif type == "object" then (.handle // .id // empty)
      else empty end;
    .result as $r
    | ($r.terminal | as_handle)
    // $r.agentTerminalHandle
    // ($r.worker.agentTerminalHandle // empty)
    // ($r.dispatch.assigneeHandle // empty)
  ' <<<"$1" 2>/dev/null || true
}

screen_is_sign_in() { # <terminal handle> ; return 0 when the screen is the sign-in step
  local raw
  raw=$("$orca" terminal read --terminal "$1" --screen --json 2>/dev/null) || return 1
  # Match the login lines themselves. A longer line that only quotes the prompt is not the sign-in step.
  printf '%s' "$raw" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
lines = raw.splitlines()
try:
    doc = json.loads(raw)
except Exception:
    doc = None
if isinstance(doc, dict):
    result = doc.get("result")
    if isinstance(result, dict):
        term = result.get("terminal")
        tail = None
        if isinstance(term, dict):
            tail = term.get("tail")
            if not isinstance(tail, list):
                screen = term.get("screen")
                tail = screen.splitlines() if isinstance(screen, str) else None
        elif isinstance(term, str):
            tail = term.splitlines()
        if isinstance(tail, list):
            lines = [str(line) for line in tail[-30:]]
ansi = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
normed = []
for line in lines:
    line = ansi.sub("", line).strip().lower().strip(" \t\"'\''`")
    if line:
        normed.append(line.rstrip(" .:;"))
prompt = "you are currently not signed in. select login method"
signed_out = "you are currently not signed in"
choose = "select login method"
blocked = prompt in normed or (signed_out in normed and choose in normed)
raise SystemExit(0 if blocked else 1)
'
}

end=$((SECONDS + wait))
while :; do
  out=$("$orca" orchestration worker-show --dispatch "$dispatch" --json 2>&1) || true
  state=$(jq -r '.result.state // .result.worker.state // .result.dispatch.state // empty' <<<"$out" 2>/dev/null || true)
  handle=$(terminal_handle "$out")
  if [ -n "$handle" ] && screen_is_sign_in "$handle"; then
    echo "FAILED $dispatch sign-in step: You are currently not signed in. Select login method" >&2
    exit 1
  fi
  case "$state" in
    running|ready|accepted|succeeded|completed)
      echo "ok $dispatch $state"
      exit 0
      ;;
    failed|stopped|abandoned|rejected)
      if [ "$screen_only" -eq 1 ]; then
        exit 0
      fi
      echo "FAILED $dispatch $state"
      exit 1
      ;;
  esac
  if [ "$SECONDS" -ge "$end" ]; then
    if [ "$screen_only" -eq 1 ]; then
      exit 0
    fi
    echo "FAILED $dispatch not accepted in ${wait}s (state: ${state:-unknown})"
    exit 1
  fi
  sleep 5
done
