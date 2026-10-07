#!/usr/bin/env bash
# Close what a finished worker left open. The coordinator runs this after worker-release.
# Usage: worker-pane-close.sh <dispatch_id> [...]   close those workers' panes and leftover terminals
#        worker-pane-close.sh                       close every recorded pane whose dispatch has ended
# Closes the pane worker-panes.sh recorded, then every terminal of that worker still in `orca terminal list`:
# the handles worker-show reports (agent and setup terminals) and any terminal whose cwd is the worktree Orca
# created for the worker. A dispatch that is still running keeps its terminals. Missing or already-closed
# terminals are not errors. State: $ORCA_PANE_STATE_DIR (default ~/.cache/orca-worker-panes/<dispatch_id>),
# one handle per line.
set -u
orca="${ORCA_CLI_COMMAND:-orca}"
state="${ORCA_PANE_STATE_DIR:-$HOME/.cache/orca-worker-panes}"
dispatch_status() { # worker-show json on stdin -> status
  python3 -c '
import sys,json
try: print(json.load(sys.stdin)["result"]["dispatch"]["status"])
except Exception: print("")'
}
leftovers() { # $1 worker-show json, $2 terminal list json -> handles still listed that belong to the worker
  SHOW="$1" LIST="$2" python3 -c '
import os,json
try: r=json.loads(os.environ["SHOW"])["result"]
except Exception: r={}
try: terms=json.loads(os.environ["LIST"])["result"]["terminals"]
except Exception: terms=[]
w=r.get("worker") or {}; d=r.get("dispatch") or {}
own=[w.get("agentTerminalHandle"), d.get("assigneeHandle")]
path=""
for e in w.get("effects") or []:
  if e.get("kind")=="terminal" and e.get("action")=="created": own.append(e.get("id"))
  if e.get("kind")=="worktree" and e.get("action")=="created_child":
    path=(e.get("id") or "").split("::",1)[-1]
seen=set()
for t in terms:
  h=t.get("handle")
  if not h or h in seen: continue
  if h in own or (path and t.get("worktreePath")==path):
    seen.add(h); print(h)'
}
close_one() {
  local d="$1" f="$state/$1" show status list n=0 h
  local handles=()
  [ -f "$f" ] && while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < "$f"
  show=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null)
  status=$(printf '%s' "$show" | dispatch_status)
  case "$status" in
    dispatched|running|pending) ;;
    *) list=$("$orca" terminal list --json 2>/dev/null)
       while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < <(leftovers "$show" "$list");;
  esac
  local done_=" "
  for h in ${handles[@]+"${handles[@]}"}; do
    case "$done_" in *" $h "*) continue;; esac
    done_="$done_$h "; n=$((n+1))
    "$orca" terminal close --terminal "$h" >/dev/null 2>&1
  done
  [ -f "$f" ] && rm -f "$f"
  [ "$n" -gt 0 ] && echo "closed $d ($n)"
  return 0
}
if [ $# -gt 0 ]; then
  for d in "$@"; do close_one "$d"; done
  exit 0
fi
for f in "$state"/*; do
  [ -f "$f" ] || continue
  d=$(basename "$f")
  status=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null | dispatch_status)
  case "$status" in ""|dispatched|running|pending) ;; *) close_one "$d";; esac
done
exit 0
