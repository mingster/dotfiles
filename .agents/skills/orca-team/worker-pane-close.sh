#!/usr/bin/env bash
# Close what a finished worker left open. The coordinator runs this after worker-release.
# Usage: worker-pane-close.sh <dispatch_id> [...]   close those workers' panes and leftover terminals
#        worker-pane-close.sh --release <dispatch_id> [...]   worker-release, mark released, then close
#        worker-pane-close.sh                       sweep recorded panes and discover ended workers in the caller's Run
# The sweep closes a settled dispatch only once its linked worktree is gone: a dispatch settles at its first
# worker_done, and the worker may still be on a correction pass in that worktree. Explicit ids skip that check,
# and so does a dispatch marked by --release ($state/released/<id>): Orca retains external terminals
# on release, so the marker is what lets a later sweep finish a close that did not complete.
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
dispatch_final() { # worker-show json on stdin -> rc 0 only when the dispatch has positively ended; prints its status
  python3 -c '
import sys,json
sys.path.insert(0, sys.argv[1]); import worker_state as ws
try: r=json.load(sys.stdin)["result"]
except Exception: print(""); sys.exit(1)
print(ws.status(r)); sys.exit(0 if ws.is_final(r) else 1)' "$here"
}
leftovers() { # $1 worker-show json, $2 terminal list json -> handles still listed that belong to the worker
  SHOW="$1" LIST="$2" python3 -c '
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
seen=set()
for t in terms:
  h=t.get("handle")
  if not h or h in seen or h==os.environ.get("ORCA_TERMINAL_HANDLE"): continue
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
busy_handles() { # $1 dispatch to ignore -> terminal handles used by any other dispatch not in a final state; rc 1 if the list cannot be read
  local cursor="" args workers page next
  while :; do
    args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
    workers=$(close_rpc orchestration worker-list ${args[@]+"${args[@]}"} --json 2>/dev/null) || return 1
    page=$(printf '%s' "$workers" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[2]); import worker_state as ws
r=json.load(sys.stdin)["result"]
for w in r["workers"]:
    if w.get("dispatchId")==sys.argv[1] or ws.is_final(w): continue
    for h in (ws.terminal(w), w.get("agentTerminalHandle"), (w.get("resource") or {}).get("terminalHandle")):
        if h: print(h)
p=r.get("page") or {}
if p.get("hasMore") and p.get("nextCursor"): print("CURSOR="+p["nextCursor"])' "$1" "$here") || return 1
    printf '%s\n' "$page" | sed '/^CURSOR=/d'
    next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
    [ -n "$next" ] && [ "$next" != "$cursor" ] || return 0
    cursor="$next"
  done
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
def valid_inventory(res):
    if not isinstance(res, dict):
        return False
    if res.get("truncated") is not False:
        return False
    scope = res.get("hostScope")
    if not isinstance(scope, dict):
        return False
    host_ids = scope.get("hostIds")
    if not isinstance(host_ids, list) or not host_ids:
        return False
    if not all(isinstance(x, str) and x for x in host_ids):
        return False
    omitted = scope.get("omittedHostIds")
    if not isinstance(omitted, list) or omitted:
        return False
    terms = res.get("terminals")
    if not isinstance(terms, list):
        return False
    for t in terms:
        if not isinstance(t, dict):
            return False
        h = t.get("handle")
        if not isinstance(h, str) or not h:
            return False
    return True
try:
    r=json.load(sys.stdin)
    if r.get("ok") is not True:
        sys.exit(1)
    res=r.get("result")
    if not valid_inventory(res):
        sys.exit(1)
    target=sys.argv[1]
    for t in res["terminals"]:
        if t["handle"]==target:
            sys.exit(1)
    sys.exit(0)
except Exception:
    sys.exit(1)' "$h"
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
  local d="$1" f="$state/$1" show list h agent
  local handles=() pending=()
  show=$(close_rpc orchestration worker-show --dispatch "$d" --json 2>/dev/null) || return 0
  printf '%s' "$show" | dispatch_final >/dev/null || return 0
  [ "${2:-}" != sweep ] || [ -e "$state/released/$d" ] || worktree_gone "$show" || return 0
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
      close_rpc terminal close --terminal "$h" >/dev/null 2>&1 || :
      terminal_absent "$h" && continue
    fi
    handles+=("$h")
  done
  if [ "${#handles[@]}" -gt 0 ]; then
    printf '%s\n' "${handles[@]}" > "$f"
  else
    rm -f "$f" "$state/released/$d"
    echo "closed $d (${#pending[@]})"
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
# Enumerate pages so an ended dispatch without a pane record is covered on wake.
dispatches=$(for f in "$state"/*; do [ ! -f "$f" ] || basename "$f"; done)
cursor=""
while [ -n "$project" ]; do
  args=(); [ -z "$cursor" ] || args=(--cursor "$cursor")
  workers=$(close_rpc orchestration worker-list ${args[@]+"${args[@]}"} --json 2>/dev/null) || break
  page=$(printf '%s' "$workers" | python3 -c '
import json,sys
sys.path.insert(0, sys.argv[2]); import worker_state as ws
try:
    r=json.load(sys.stdin)["result"]
    for w in r["workers"]:
        wid=ws.workspace_id(w)
        if wid.startswith(sys.argv[1]+"::") and w.get("dispatchId") and ws.is_final(w):
            print(w["dispatchId"])
    p=r.get("page") or {}
    if p.get("hasMore") and p.get("nextCursor"): print("CURSOR="+p["nextCursor"])
except Exception: pass' "$project" "$here")
  dispatches="$dispatches
$(printf '%s\n' "$page" | sed '/^CURSOR=/d')"
  next=$(printf '%s\n' "$page" | sed -n 's/^CURSOR=//p')
  [ -n "$next" ] && [ "$next" != "$cursor" ] || break
  cursor="$next"
done
while IFS= read -r d; do [ -z "$d" ] || close_one "$d" sweep; done < <(printf '%s\n' "$dispatches" | sort -u)
exit 0
