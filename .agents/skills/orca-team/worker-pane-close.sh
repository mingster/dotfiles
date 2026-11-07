#!/usr/bin/env bash
# Close what a finished worker left open. The coordinator runs this after worker-release.
# Usage: worker-pane-close.sh <dispatch_id> [...]   close those workers' panes and leftover terminals
#        worker-pane-close.sh --release <dispatch_id> [...]   worker-release, mark released, then close
#        worker-pane-close.sh                       sweep recorded panes and discover ended workers in the caller's Run
# The sweep closes a settled dispatch only once its linked worktree is gone: a dispatch settles at its first
# worker_done, and the worker may still be on a correction pass in that worktree. Explicit ids skip that check,
# and so does a dispatch marked by --release ($state/released/<id>): Orca retains external terminals
# on release, so the marker is what lets a later sweep finish a close that did not complete.
# Protected by identity, whichever Run owns them: every Run's coordinator_handle (run-list), the caller, and any terminal or
# worktree a live dispatch uses. If run-list or worker-list cannot be read, nothing closes.
# Closes the pane worker-panes.sh recorded, then every terminal of that worker still in `orca terminal list`:
# the handles worker-show reports (agent and setup terminals) and any terminal whose worktreePath matches
# the linked git worktree the worker created or reused. A dispatch that is still running keeps its terminals,
# and so does a terminal that a dispatch not yet in a final state also uses (a retry reuses the failed dispatch's terminal). Missing or already-closed
# terminals are not errors. Release closes at most the agent terminal; after a confirmed release the remaining
# handles are closed here (never the agent terminal or the caller's own $ORCA_TERMINAL_HANDLE). State: $ORCA_PANE_STATE_DIR (default ~/.cache/orca-worker-panes/<dispatch_id>),
# one handle per line, retained until verified gone. Failed or lingering closes retry for up to 30 minutes.
set -u
orca="${ORCA_CLI_COMMAND:-orca}"
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=worker-pane-retry.sh
. "$here/worker-pane-retry.sh"
state="${ORCA_PANE_STATE_DIR:-$HOME/.cache/orca-worker-panes}"
close_deadline=$((SECONDS+${ORCA_PANE_CLOSE_TIMEOUT:-1800}))
sweep_before_deadline() { [ "$SECONDS" -lt "$close_deadline" ]; }
dispatch_final() { # worker-show json on stdin -> rc 0 only when the dispatch has positively ended; prints its status
  python3 -c '
import sys,json
sys.path.insert(0, sys.argv[1]); import worker_state as ws
try: r=json.load(sys.stdin)["result"]
except Exception: print(""); sys.exit(1)
print(ws.status(r)); sys.exit(0 if ws.can_close(r) else 1)' "$here"
}
leftovers() { # $1 worker-show json, $2 terminal list json, $3 protected handles and "wt:<path>" lines -> handles still listed that belong to the worker
  SHOW="$1" LIST="$2" PROTECT="${3:-}" python3 -c '
import os,json,subprocess
try: r=json.loads(os.environ["SHOW"])["result"]
except Exception: r={}
try: terms=json.loads(os.environ["LIST"])["result"]["terminals"]
except Exception: terms=[]
w=r.get("worker") or {}; d=r.get("dispatch") or {}
own=[w.get("agentTerminalHandle"), d.get("assigneeHandle"), r.get("terminal") if isinstance(r.get("terminal"),str) else None]
path=""
for e in w.get("effects") or []:
  if e.get("kind")=="terminal" and e.get("action")=="created": own.append(e.get("id"))
  if e.get("kind")=="worktree":
    path=(e.get("id") or "").split("::",1)[-1]
if not path:
  path=(w.get("worktreeId") or "").split("::",1)[-1]
if not path and isinstance(r.get("workspace"),str):
  path=r["workspace"].split("::",1)[-1]
if not path:
  option=(w.get("startOptions") or {}).get("worktree") or ""
  if option.startswith("path:"): path=option[len("path:"):]
# Main checkouts have a .git directory and may host owner or coordinator sessions.
# A path that does not exist here belongs to another host: it cannot be inspected, so match its terminals by
# worktree path and id, and skip any on the repo main branch.
remote=bool(path) and not os.path.exists(path)
if path and not remote and not os.path.isfile(os.path.join(path,".git")): path=""
# Unpushed commits stay safe: a local worktree ahead of its upstream keeps its shell terminals.
if path and not remote:
  try:
    ahead=subprocess.run(["git","-C",path,"rev-list","--count","@{upstream}..HEAD"],capture_output=True,text=True)
    if ahead.returncode==0 and int(ahead.stdout.strip() or 0)>0: path=""
  except Exception: pass
protect=set(os.environ.get("PROTECT","").split("\n"))
seen=set()
for t in terms:
  h=t.get("handle")
  if not h or h in seen or h==os.environ.get("ORCA_TERMINAL_HANDLE"): continue
  if h in protect or "wt:"+str(t.get("worktreePath")) in protect: continue
  if remote and t.get("branch") in ("refs/heads/main","refs/heads/master"): continue
  if h in own or (path and t.get("worktreePath")==path):
    seen.add(h); print(h)'
}
worktree_gone() { # $1 worker-show json -> rc 0 only when the dispatch names a worktree path that no longer exists
  SHOW="$1" python3 -c '
import os,sys,json
try: r=json.loads(os.environ["SHOW"])["result"]; w=r.get("worker") or {}
except Exception: sys.exit(1)
path=""
for e in w.get("effects") or []:
  if e.get("kind")=="worktree": path=(e.get("id") or "").split("::",1)[-1]
if not path: path=(w.get("worktreeId") or "").split("::",1)[-1]
if not path and isinstance(r.get("workspace"),str): path=r["workspace"].split("::",1)[-1]
if not path:
  option=(w.get("startOptions") or {}).get("worktree") or ""
  if option.startswith("path:"): path=option[len("path:"):]
sys.exit(0 if path and not os.path.exists(path) else 1)'
}
run_coordinators() { # -> every Run's coordinator handle (the caller, leads, other Runs); rc 1 if the Run list cannot be read
  local cursor="" args runs page next
  while :; do
    args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
    runs=$(close_rpc orchestration run-list --full ${args[@]+"${args[@]}"} --json 2>/dev/null) || return 1
    page=$(printf '%s' "$runs" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
doc=json.load(sys.stdin)
if doc.get("ok") is False: sys.exit(1)
r=doc["result"]
for run in r["runs"]:
    if run.get("coordinator_handle"): print(run["coordinator_handle"])
c=ws.next_cursor(r)
if c: print("CURSOR="+c)' "$here") || return 1
    printf '%s\n' "$page" | sed '/^CURSOR=/d'
    next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
    [ -n "$next" ] || return 0
    [ "$next" != "$cursor" ] || return 1
    cursor="$next"
  done
}
run_ids() { # -> every Run id; rc 1 if the Run list cannot be read or a cursor repeats
  local cursor="" args runs page next
  while :; do
    args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
    runs=$(close_rpc orchestration run-list --full ${args[@]+"${args[@]}"} --json 2>/dev/null) || return 1
    page=$(printf '%s' "$runs" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
doc=json.load(sys.stdin)
if doc.get("ok") is False: sys.exit(1)
r=doc["result"]
for run in r["runs"]:
    if run.get("id"): print(run["id"])
c=ws.next_cursor(r)
if c: print("CURSOR="+c)' "$here") || return 1
    printf '%s\n' "$page" | sed '/^CURSOR=/d'
    next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
    [ -n "$next" ] || return 0
    [ "$next" != "$cursor" ] || return 1
    cursor="$next"
  done
}
# worker-list without --run shows only the caller's Run, so read every Run. $1 is a python snippet run on each page
# with r (the result), ws and sys.argv[2..] in scope; it prints lines. rc 1 if any Run or page cannot be read.
each_worker_page() {
  local snippet=$1 run cursor args workers page next ids
  shift
  ids=$(run_ids) || return 1
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    cursor=""
    while :; do
      args=(--run "$run"); [ -z "$cursor" ] || args+=(--cursor "$cursor")
      workers=$(close_rpc orchestration worker-list "${args[@]}" --json 2>/dev/null) || return 1
      page=$(printf '%s' "$workers" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
doc=json.load(sys.stdin)
if doc.get("ok") is False: sys.exit(1)
r=doc["result"]
'"$snippet"'
c=ws.next_cursor(r)
if c: print("CURSOR="+c)' "$here" "$@") || return 1
      printf '%s\n' "$page" | sed '/^CURSOR=/d'
      next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
      [ -n "$next" ] || break
      [ "$next" != "$cursor" ] || return 1
      cursor="$next"
    done
  done <<< "$ids"
}
busy_handles() { # $1 dispatch to ignore -> terminal handles and "wt:<path>" worktrees used by any other dispatch not in a final state, in every Run; rc 1 if a list cannot be read
  each_worker_page '
for w in r["workers"]:
    if w.get("dispatchId")==sys.argv[2] or ws.is_final(w): continue
    for h in (ws.terminal(w), w.get("agentTerminalHandle"), (w.get("resource") or {}).get("terminalHandle")):
        if h: print(h)
    wid=ws.workspace_id(w)
    if wid: print("wt:"+wid.split("::",1)[-1])' "$1"
}
close_allowed() {
  [ "${2:-}" != "${ORCA_TERMINAL_HANDLE:-}" ] || return 1
  local show
  show=$(close_rpc orchestration worker-show --dispatch "$1" --json 2>/dev/null) || return 1
  printf '%s' "$show" | dispatch_final >/dev/null
}
parse_release_strict() {
  RELEASE_BODY="$1" RELEASE_RC="${2:-0}" DISPATCH_ID="$3" python3 <<'PY'
import json, os, sys
body = os.environ.get("RELEASE_BODY", "")
rc = int(os.environ.get("RELEASE_RC", "0"))
dispatch_id = os.environ.get("DISPATCH_ID", "")
try:
    doc = json.loads(body)
except Exception:
    print("malformed\t%s\t" % rc)
    sys.exit(0)
if doc.get("ok") is not True:
    code = (doc.get("error") or {}).get("code") or "error"
    print("%s\t%s\t" % (code, rc))
    sys.exit(0)
result = doc.get("result") or {}
rid = result.get("dispatchId")
if dispatch_id:
    if rid is None or rid == "":
        print("missing\t%s\t" % rc)
        sys.exit(0)
    if rid != dispatch_id:
        print("id_mismatch\t%s\t" % rc)
        sys.exit(0)
state = result.get("state") or "missing"
action = result.get("processAction") or ""
if state in ("released", "already_released") and rc != 0:
    print("nonzero_success\t%s\t" % rc)
    sys.exit(0)
print("%s\t%s\t%s" % (state, rc, action))
PY
}
terminal_absent() {
  local h=$1 list
  list=$(close_rpc terminal list --json 2>/dev/null) || return 1
  printf '%s' "$list" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[2]); import worker_state as ws
try:
    doc = json.load(sys.stdin)
    if not ws.terminal_inventory_ok(doc):
        sys.exit(1)
    target = sys.argv[1]
    for t in doc["result"]["terminals"]:
        if t["handle"] == target:
            sys.exit(1)
    sys.exit(0)
except Exception:
    sys.exit(1)' "$h" "$here"
}
# The only gate that deletes a pane state file or its released marker.
pane_record_rm() {
  local d=$1 final_proof=$2 worker_list_ok=${3:-0} list_json=${4:-} f="$state/$1" r="$state/released/$1"
  [ -f "$f" ] || return 1
  PANE_RM_HERE="$here" PANE_RM_FINAL="$final_proof" PANE_RM_WORKER_LIST_OK="$worker_list_ok" \
    PANE_RM_LIST="$list_json" PANE_RM_STATE="$f" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PANE_RM_HERE"]); import worker_state as ws
if os.environ.get("PANE_RM_WORKER_LIST_OK") != "1":
    sys.exit(1)
final = os.environ.get("PANE_RM_FINAL", "")
if final in ("list_running", "show_unknown", "none", ""):
    sys.exit(1)
if final not in ("list_final", "show_final", "show_not_found", "explicit_final"):
    sys.exit(1)
try:
    hs = [ln.strip() for ln in open(os.environ["PANE_RM_STATE"]) if ln.strip()]
except Exception:
    sys.exit(1)
lst = os.environ.get("PANE_RM_LIST", "")
try:
    doc = json.loads(lst) if lst else {}
    live = ws.terminal_live_handles(doc)
except Exception:
    live = None
if live is None or any(h in live for h in hs):
    sys.exit(1)
sys.exit(0)
' || return 1
  rm -f "$f" "$r"
  [ -n "${ORCA_PANE_RM_LOG:-}" ] && printf 'rm %s\nrm %s\n' "$f" "$r" >> "$ORCA_PANE_RM_LOG"
  return 0
}
native_release_for_close() {
  local d=$1 release_out="" release_rc=0 parsed rel_state rel_rc rel_action
  release_out=$(close_rpc orchestration worker-release --dispatch "$d" --json) || release_rc=$?
  parsed=$(parse_release_strict "$release_out" "$release_rc" "$d") || return 1
  rel_state=${parsed%%$'\t'*}
  parsed=${parsed#*$'\t'}
  rel_rc=${parsed%%$'\t'*}
  rel_action=${parsed#*$'\t'}
  RELEASE_PARSE_STATE=$rel_state
  RELEASE_PARSE_RC=$rel_rc
  RELEASE_PARSE_BODY=$release_out
  case "$rel_state" in
    released|already_released) return 0 ;;
    retained|release_pending) return 2 ;;
    *) return 1 ;;
  esac
}
close_one() {
  local d="$1" f="$state/$1" show list h agent fresh worker_list_ok=0
  local handles=() pending=()
  [ "${2:-}" != sweep ] || sweep_before_deadline || return 0
  show=$(close_rpc orchestration worker-show --dispatch "$d" --json 2>/dev/null) || return 0
  printf '%s' "$show" | dispatch_final >/dev/null || return 0
  [ "${2:-}" != sweep ] || [ -e "$state/released/$d" ] || worktree_gone "$show" || return 0
  [ -f "$f" ] && while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < "$f" 2>/dev/null || true
  # Protect by identity, whichever Run owns the terminal: every Run's coordinator and anything a live dispatch uses.
  # If either list cannot be read, close nothing.
  local coords busy prot
  if [ "${2:-}" = sweep ]; then
    # The sweep read the Run list, every Run's workers and the terminal list once; an unread list closes nothing.
    [ "$sweep_ok" -eq 1 ] || return 0
    worker_list_ok=$sweep_ok
    coords=$sweep_coords
    busy=$(printf '%s\n' "$sweep_busy" | awk -F'\t' -v d="$d" '$1 != d { print $2 }')
    list=$sweep_list
  else
    coords=$(run_coordinators) || return 0
    busy=$(busy_handles "$d") || return 0
    worker_list_ok=1
    list=$(close_rpc terminal list --json 2>/dev/null) || list=''
  fi
  prot="$coords
$busy"
  while IFS= read -r h; do [ -n "$h" ] && handles+=("$h"); done < <(leftovers "$show" "$list" "$prot")
  local done_=" "
  for h in ${handles[@]+"${handles[@]}"}; do
    case "$done_" in *" $h "*) continue;; esac
    done_="$done_$h "; pending+=("$h")
  done
  # A retry may reuse this dispatch's terminal: leave any handle a live dispatch also uses.
  if [ "${#pending[@]}" -gt 0 ]; then
    local kept=()
    for h in "${pending[@]}"; do
      case $'\n'"$prot"$'\n' in *$'\n'"$h"$'\n'*) ;; *) kept+=("$h");; esac
    done
    [ "${#kept[@]}" -gt 0 ] || return 0
    pending=(${kept[@]+"${kept[@]}"})
  fi
  [ "${#pending[@]}" -gt 0 ] || {
    list=$(close_rpc terminal list --json 2>/dev/null) || list=''
    pane_record_rm "$d" explicit_final "$worker_list_ok" "$list"
    return 0
  }
  native_release_for_close "$d" || rel_rc=$?
  case "${rel_rc:-0}" in
    2)
      return 0
      ;;
    1)
      case "${RELEASE_PARSE_STATE:-}" in
        id_mismatch|nonzero_success|malformed|error|release_unknown|missing) return 0 ;;
      esac
      return 0
      ;;
  esac
  # Release closes at most the agent terminal. The coordinator's split pane and the worker's Setup or shell
  # terminals in its own worktree stay open, so close those exact handles. The agent terminal is left to Orca,
  # and close_allowed rechecks that the dispatch ended and the handle is not the caller's own terminal.
  agent=$(printf '%s' "$show" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[1]); import worker_state as ws
try: print(ws.terminal(json.load(sys.stdin)["result"]))
except Exception: print("")' "$here")
  mkdir -p "$state"
  handles=()
  for h in "${pending[@]}"; do
    terminal_absent "$h" && continue
    if [ "$h" != "$agent" ] && close_allowed "$d" "$h"; then
      # The sweep's lists are minutes old by now: reread who is live, only for a terminal about to be closed.
      if [ "${2:-}" = sweep ]; then
        fresh=$(busy_handles "$d") || { handles+=("$h"); continue; }
        case $'\n'"$fresh"$'\n' in *$'\n'"$h"$'\n'*) handles+=("$h"); continue ;; esac
      fi
      close_rpc terminal close --terminal "$h" >/dev/null 2>&1 || :
      terminal_absent "$h" && continue
    fi
    handles+=("$h")
  done
  if [ "${#handles[@]}" -gt 0 ]; then
    printf '%s\n' "${handles[@]}" > "$state/.$d.$$" && mv -f "$state/.$d.$$" "$f"
  else
    list=$(close_rpc terminal list --json 2>/dev/null) || list=''
    pane_record_rm "$d" explicit_final "$worker_list_ok" "$list" \
      && echo "closed $d (${#pending[@]})"
  fi
  return 0
}
if [ "${1:-}" = --release ]; then
  shift
  [ "$#" -gt 0 ] || { echo "worker-pane-close: --release requires a dispatch id" >&2; exit 2; }
  for d in "$@"; do
    show=$(close_rpc orchestration worker-show --dispatch "$d" --json) || exit 1
    status=$(printf '%s' "$show" | dispatch_final) && final=1 || final=0
    case "$final" in 1) ;;
      *) echo "worker-pane-close: refusing --release $d (status=${status:-unknown}); settle it, or use worker-stop explicitly before release" >&2; exit 1 ;;
    esac
    release_out=$(close_rpc orchestration worker-release --dispatch "$d" --json) || release_rc=$?
    release_parsed=$(parse_release_strict "$release_out" "${release_rc:-0}" "$d") || {
      echo "worker-pane-close: could not parse worker-release for $d; retaining terminals" >&2
      exit 1
    }
    rel_state=${release_parsed%%$'\t'*}
    release_parsed=${release_parsed#*$'\t'}
    rel_rc=${release_parsed%%$'\t'*}
    rel_action=${release_parsed#*$'\t'}
    case "$rel_state" in
      released|already_released)
        mkdir -p "$state/released" && : > "$state/released/$d"
        [ "$rel_action" != "none" ] || echo "worker-pane-close: $d $rel_state; native retained external terminals, closing leftovers" >&2
        close_one "$d"
        ;;
      retained|release_pending)
        reason=$(printf '%s' "$release_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("result",{}).get("reason") or "")
except Exception: print("")' 2>/dev/null)
        echo "worker-pane-close: $d $rel_state${reason:+ ($reason)}; retaining terminals" >&2
        ;;
      release_unknown|missing|malformed|error|id_mismatch|nonzero_success)
        echo "worker-pane-close: release failed for $d ($rel_state); retaining terminals" >&2
        printf '%s\n' "$release_out" >&2
        exit 1
        ;;
      *)
        echo "worker-pane-close: release failed for $d (unknown state $rel_state); retaining terminals" >&2
        printf '%s\n' "$release_out" >&2
        exit 1
        ;;
    esac
  done
  exit 0
fi
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
# Enumerate every Run's pages so an ended dispatch without a pane record is covered on wake.
dispatches=$(for f in "$state"/*; do [ ! -f "$f" ] || basename "$f"; done)
if [ -n "$project" ] && found=$(each_worker_page '
for w in r["workers"]:
    wid=ws.workspace_id(w)
    if wid.startswith(sys.argv[2]+"::") and w.get("dispatchId") and ws.is_final(w):
        print(w["dispatchId"])' "$project"); then
  dispatches="$dispatches
$found"
fi
# Read each list once for the whole sweep, not once per dispatch. Any list that cannot be read closes nothing.
sweep_ok=1; sweep_coords=''; sweep_busy=''; sweep_list=''
sweep_rows_file=$(mktemp); sweep_rows_cleanup() { rm -f "$sweep_rows_file"; }
trap sweep_rows_cleanup EXIT
: > "$sweep_rows_file"
export ORCA_SWEEP_ROWS_FILE="$sweep_rows_file"
sweep_coords=$(run_coordinators) || sweep_ok=0
sweep_busy=$(each_worker_page '
import json, os
rows_path=os.environ.get("ORCA_SWEEP_ROWS_FILE") or ""
rows=open(rows_path,"a") if rows_path else None
for w in r["workers"]:
    did=w.get("dispatchId") or ""
    if rows and did:
        rows.write(did+"\t"+json.dumps(w,separators=(",",":"))+"\n")
    if ws.is_final(w): continue
    d=did
    for h in (ws.terminal(w), w.get("agentTerminalHandle"), (w.get("resource") or {}).get("terminalHandle")):
        if h: print(d+"\t"+h)
    wid=ws.workspace_id(w)
    if wid: print(d+"\twt:"+wid.split("::",1)[-1])' "$here") || sweep_ok=0
unset ORCA_SWEEP_ROWS_FILE
sweep_list=$(close_rpc terminal list --json 2>/dev/null) || sweep_list=''
# A pane file whose handles are all gone has nothing left to close once its dispatch ended or is unknown. Needs a complete
# terminal inventory: an unreadable or partial list proves nothing and removes nothing.
if [ -n "$sweep_list" ]; then
  gone=$(STATE="$state" LIST="$sweep_list" HERE="$here" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["HERE"]); import worker_state as ws
try:
    doc = json.loads(os.environ["LIST"])
    live = ws.terminal_live_handles(doc)
except Exception:
    live = None
if live is not None:
    st = os.environ["STATE"]
    for n in sorted(os.listdir(st)):
        p = os.path.join(st, n)
        if not os.path.isfile(p) or "\n" in n:
            continue
        hs = [l.strip() for l in open(p) if l.strip()]
        if not any(h in live for h in hs):
            print(n)' 2>/dev/null) || gone=''
  # A dispatch that is still running keeps its record (its pane may not be listed yet). An ended or unknown one does not.
  # Use the worker-list rows read for the sweep; worker-show only when a dispatch is missing from every page.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    drop=$(DID="$d" ROWS="$sweep_rows_file" HERE="$here" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["HERE"]); import worker_state as ws
did = os.environ["DID"]
row = None
for line in open(os.environ["ROWS"]):
    line = line.rstrip("\n")
    if not line: continue
    i, raw = line.split("\t", 1)
    if i == did:
        try: row = json.loads(raw)
        except Exception: pass
        break
if row is not None:
    print(1 if ws.is_final(row) else 0)
else:
    print(2)' 2>/dev/null) || continue
    proof=list_running
    case "$drop" in
      1) proof=list_final ;;
      0) proof=list_running ;;
      *)
        proof=show_unknown
        if [ "$sweep_ok" -eq 1 ]; then
          show=$(close_rpc orchestration worker-show --dispatch "$d" --json 2>/dev/null) || show=''
          if [ -n "$show" ] && printf '%s' "$show" | dispatch_final >/dev/null; then
            proof=show_final
          elif [ -n "$show" ] && printf '%s' "$show" | python3 -c '
import sys,json
try: doc=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if doc.get("ok") is False and (doc.get("error") or {}).get("code")=="dispatch_not_found" else 1)' 2>/dev/null; then
            proof=show_not_found
          fi
        fi
        ;;
    esac
    pane_record_rm "$d" "$proof" "$sweep_ok" "$sweep_list"
  done <<< "$gone"
  dispatches=$(for f in "$state"/*; do [ ! -f "$f" ] || basename "$f"; done; printf '%s\n' "${found:-}")
fi
sweep_stopped=0
while IFS= read -r d || [ -n "$d" ]; do
  [ -z "$d" ] && continue
  if [ "$SECONDS" -ge "$close_deadline" ]; then sweep_stopped=1; break; fi
  close_one "$d" sweep
done < <(printf '%s\n' "$dispatches" | sort -u)
if [ "$sweep_stopped" -eq 1 ]; then
  n=0
  for f in "$state"/*; do [ -f "$f" ] || continue; n=$((n+1)); done
  printf 'sweep: deadline reached, %s pane record(s) left\n' "$n"
fi
sweep_rows_cleanup; trap - EXIT
exit 0
