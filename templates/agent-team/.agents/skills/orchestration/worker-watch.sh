#!/usr/bin/env bash
# worker-watch.sh <run_id>
# Flags Orca workers stopped by a provider limit (STOPPED) or near full context (LOW_CONTEXT).
# Heartbeats and a live terminal do not prove progress, so read the screen.
# Exit 0 all OK, 4 any STOPPED or LOW_CONTEXT, 2 usage or orca error.
set -u

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: worker-watch.sh <run_id>" >&2; exit 2; }
run="$1"

list=$(orca orchestration worker-list --run "$run" --json 2>/dev/null) \
  || { echo "worker-watch: worker-list failed for $run" >&2; exit 2; }

# One line per unsettled dispatch: <dispatch_id> <terminal_handle>
rows=$(printf '%s' "$list" | python3 -c '
import json, sys
try:
    workers = json.load(sys.stdin)["result"]["workers"]
except Exception:
    sys.exit(3)
for w in workers:
    p = w.get("projection") or {}
    handle = w.get("agentTerminalHandle")
    if p.get("outcome", "in_progress") != "in_progress" or not handle:
        continue
    print(w["dispatchId"], handle)
') || { echo "worker-watch: cannot parse worker-list output" >&2; exit 2; }

status=0
while read -r dispatch handle; do
  [ -n "$dispatch" ] || continue
  raw=$(orca terminal read --terminal "$handle" --screen --json 2>/dev/null) \
    || { echo "worker-watch: cannot read terminal $handle" >&2; exit 2; }
  verdict=$(printf '%s' "$raw" | python3 -c '
import json, re, sys
try:
    tail = json.load(sys.stdin)["result"]["terminal"]["tail"]
except Exception:
    sys.exit(3)
tail = [l.rstrip() for l in tail[-30:]]
# Only the providers actual stop messages, never bare words.
stop = re.compile(
    r"Individual quota reached|\bResets in \d|weekly limit.*% left|hit your weekly limit"
    r"|spendLimitHit: true|usage limit reached|limit will reset|Context limit reached"
    r"|Run /compact to", re.I)
marker = re.compile(r"^\s*[⚠■✗✖!]")
# Source, diffs and shell lines are not provider notices.
code = re.compile(r"^\s*(\d+\s*[:|│]|[+\-#]|[│|])|[`=]|\b(grep|printf|echo|check|pattern|re\.compile)\b|[\x27\"]")
ui = tail[-8:]
for l in tail:
    if stop.search(l) and (l in ui or marker.match(l)) and (marker.match(l) or not code.search(l)):
        print("STOPPED", l.strip()[:160]); sys.exit(0)
for l in tail[-5:]:
    m = re.search(r"ctx:\s*(\d+)%", l)
    if m and int(m.group(1)) >= 80:
        print("LOW_CONTEXT", l.strip()[:160]); sys.exit(0)
print("OK")
') || { echo "worker-watch: cannot read terminal $handle" >&2; exit 2; }
  echo "$dispatch $handle $verdict"
  case "$verdict" in OK) ;; *) status=4 ;; esac
done <<< "$rows"

exit $status
