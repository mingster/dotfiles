#!/usr/bin/env bash
# Close what a finished worker left open. The coordinator runs this after worker-release.
# Usage: worker-pane-close.sh <dispatch_id> [...]   close those workers' panes and leftover terminals
#        worker-pane-close.sh                       sweep recorded panes and discover ended workers in the caller's Run
# Closes the pane worker-panes.sh recorded, then every terminal of that worker still in `orca terminal list`:
# the handles worker-show reports (agent and setup terminals) and any terminal whose cwd is the worktree Orca
# created for the worker. A dispatch that is still running keeps its terminals, and so does a terminal that a
# dispatch not yet in a final state also uses (a retry reuses the failed dispatch's terminal). Missing or already-closed
# terminals are not errors. State: $ORCA_PANE_STATE_DIR (default ~/.cache/orca-worker-panes/<dispatch_id>),
# one handle per line, retained until verified gone. Failed or lingering closes retry for up to 30 minutes.
set -u
orca="${ORCA_CLI_COMMAND:-orca}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-pane-retry.sh
. "$here/worker-pane-retry.sh"
state="${ORCA_PANE_STATE_DIR:-$HOME/.cache/orca-worker-panes}"
close_deadline=$((SECONDS+${ORCA_PANE_CLOSE_TIMEOUT:-1800}))
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
busy_handles() { # $1 dispatch to ignore -> terminal handles used by any other dispatch not in a final state; rc 1 if the list cannot be read
  local cursor="" args workers page next
  while :; do
    args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
    workers=$(close_rpc orchestration worker-list ${args[@]+"${args[@]}"} --json 2>/dev/null) || return 1
    page=$(printf '%s' "$workers" | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
for w in r["workers"]:
    if w.get("dispatchId")==sys.argv[1] or w.get("dispatchStatus") in ("completed","failed","cancelled","released"): continue
    for h in (w.get("agentTerminalHandle"), (w.get("resource") or {}).get("terminalHandle")):
        if h: print(h)
p=r.get("page") or {}
if p.get("hasMore") and p.get("nextCursor"): print("CURSOR="+p["nextCursor"])' "$1") || return 1
    printf '%s\n' "$page" | sed '/^CURSOR=/d'
    next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
    [ -n "$next" ] && [ "$next" != "$cursor" ] || return 0
    cursor="$next"
  done
}
close_allowed() {
  [ "${2:-}" != "${ORCA_TERMINAL_HANDLE:-}" ] || return 1
  local show status
  show=$(close_rpc orchestration worker-show --dispatch "$1" --json 2>/dev/null) || return 1
  status=$(printf '%s' "$show" | dispatch_status)
  case "$status" in completed|failed|cancelled|released) return 0;; *) return 1;; esac
}
close_one() {
  local d="$1" f="$state/$1" show status list h
  local handles=() pending=()
  show=$(close_rpc orchestration worker-show --dispatch "$d" --json 2>/dev/null) || return 0
  status=$(printf '%s' "$show" | dispatch_status)
  case "$status" in completed|failed|cancelled|released) ;; *) return 0;; esac
  [ -f "$f" ] && while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < "$f"
  list=$(close_rpc terminal list --json 2>/dev/null)
  while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < <(leftovers "$show" "$list")
  local done_=" "
  for h in ${handles[@]+"${handles[@]}"}; do
    case "$done_" in *" $h "*) continue;; esac
    done_="$done_$h "; pending+=("$h")
  done
  # A retry may reuse this dispatch's terminal: leave any handle a live dispatch also uses.
  if [ "${#pending[@]}" -gt 0 ]; then
    local busy kept=()
    busy=$(busy_handles "$d") || return 0
    for h in "${pending[@]}"; do
      case $'\n'"$busy"$'\n' in *$'\n'"$h"$'\n'*) ;; *) kept+=("$h");; esac
    done
    [ "${#kept[@]}" -gt 0 ] || return 0
    pending=(${kept[@]+"${kept[@]}"})
  fi
  [ "${#pending[@]}" -gt 0 ] || { [ ! -f "$f" ] || rm -f "$f"; return 0; }
  # Persist newly discovered leftovers too, so budget expiry can be recovered on wake.
  mkdir -p "$state"
  printf '%s\n' "${pending[@]}" > "$f"
  handles=()
  for h in "${pending[@]}"; do
    close_verified "$h" "$d" || handles+=("$h")
  done
  if [ "${#handles[@]}" -gt 0 ]; then
    printf '%s\n' "${handles[@]}" > "$f"
  else
    rm -f "$f"
    echo "closed $d (${#pending[@]})"
  fi
  return 0
}
if [ $# -gt 0 ]; then
  for d in "$@"; do close_one "$d"; done
  exit 0
fi
# Resolve the current project from live terminal metadata. Some CLI contexts list all Runs;
# new discovery must stay within this project. Recorded panes remain explicit cleanup targets.
project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
project=$(close_rpc terminal list --json 2>/dev/null | python3 -c '
import json,sys
try:
    terms=json.load(sys.stdin)["result"]["terminals"]
    ids={t["worktreeId"].split("::",1)[0] for t in terms
         if t.get("worktreePath")==sys.argv[1] and "::" in t.get("worktreeId","")}
    if len(ids)==1: print(ids.pop())
except Exception: pass' "$project_root")
# Enumerate pages so an ended dispatch without a pane record is covered on wake.
dispatches=$(for f in "$state"/*; do [ ! -f "$f" ] || basename "$f"; done)
cursor=""
while [ -n "$project" ]; do
  args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
  workers=$(close_rpc orchestration worker-list ${args[@]+"${args[@]}"} --json 2>/dev/null) || break
  page=$(printf '%s' "$workers" | python3 -c '
import json,sys
try:
    r=json.load(sys.stdin)["result"]
    for w in r["workers"]:
        resource=w.get("resource") or {}
        workspace=(w.get("projection") or {}).get("workspace") or {}
        wid=resource.get("worktreeId") or workspace.get("id") or ""
        if (wid.startswith(sys.argv[1]+"::") and w.get("dispatchId")
            and w.get("dispatchStatus") in ("completed","failed","cancelled","released")):
            print(w["dispatchId"])
    p=r.get("page") or {}
    if p.get("hasMore") and p.get("nextCursor"): print("CURSOR="+p["nextCursor"])
except Exception: pass' "$project")
  dispatches="$dispatches
$(printf '%s\n' "$page" | sed '/^CURSOR=/d')"
  next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
  [ -n "$next" ] && [ "$next" != "$cursor" ] || break
  cursor="$next"
done
while IFS= read -r d; do [ -z "$d" ] || close_one "$d"; done < <(printf '%s\n' "$dispatches" | sort -u)
exit 0
