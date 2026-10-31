#!/usr/bin/env bash
# Tests for worker-pane-close.sh and the state file worker-panes.sh writes, with a fake orca (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-show --dispatch "*) d=$4
    if [ "${FAKE_REACTIVATE:-}" = "$d" ] && [ -s "$FAKE_DIR/closes.log" ]; then
      echo '{"result":{"dispatch":{"status":"running"}}}'; exit 0
    fi
    if [ -f "$FAKE_DIR/show.$d" ]; then cat "$FAKE_DIR/show.$d"; else s=$(cat "$FAKE_DIR/status.$d" 2>/dev/null); printf '{"result":{"dispatch":{"status":"%s"}}}' "$s"; fi ;;
  "terminal close --terminal "*)
    echo "$4" >> "$FAKE_DIR/closes.log"
    n=$(grep -cx "$4" "$FAKE_DIR/closes.log")
    [ "$n" -le "${FAKE_FAILS:-0}" ] && exit 1
    [ "$n" -le "${FAKE_LINGERS:-0}" ] && exit 0
    if [ -f "$FAKE_DIR/terminals.json" ]; then
      python3 - "$FAKE_DIR/terminals.json" "$4" <<'REMOVE'
import json,sys
p,h=sys.argv[1:]; r=json.load(open(p)); r['result']['terminals']=[t for t in r['result']['terminals'] if t['handle']!=h]
json.dump(r,open(p,'w'))
REMOVE
    fi ;;
  "orchestration worker-release --dispatch "*) echo "$*" >> "$FAKE_DIR/rpc.log"; d=$4
    body=""
    if [ -f "$FAKE_DIR/release.$d.json" ]; then body=$(cat "$FAKE_DIR/release.$d.json"); else
      body='{"ok":true,"result":{"state":"released","dispatchId":"'"$d"'","processAction":"closed_agent_terminal"}}'
    fi
    printf '%s\n' "$body"
    rc=${FAKE_RELEASE_EXIT:-0}
    if [ "$rc" = 0 ]; then
      FAKE_DIR="$FAKE_DIR" BODY="$body" DISPATCH="$d" ORCA_TERMINAL_HANDLE="${ORCA_TERMINAL_HANDLE:-}" python3 <<'NATIVERM'
import json, os, sys
body = json.loads(os.environ["BODY"])
if body.get("ok") is not True:
    sys.exit(0)
result = body.get("result") or {}
dispatch = os.environ["DISPATCH"]
rid = result.get("dispatchId")
if rid != dispatch:
    sys.exit(0)
if result.get("processAction") == "none":
    sys.exit(0)
if result.get("state") not in ("released", "already_released"):
    sys.exit(0)
if os.environ.get("FAKE_SKIP_NATIVE_RM") == "1":
    sys.exit(0)
fake = os.environ["FAKE_DIR"]
show_path = os.path.join(fake, "show." + dispatch)
try:
    show = json.load(open(show_path)) if os.path.isfile(show_path) else {}
except Exception:
    show = {}
if not show:
    status = open(os.path.join(fake, "status." + dispatch)).read().strip() if os.path.isfile(os.path.join(fake, "status." + dispatch)) else "completed"
    show = {"result": {"dispatch": {"status": status}}}
r = show.get("result") or {}
w = r.get("worker") or {}
d = r.get("dispatch") or {}
own = {w.get("agentTerminalHandle"), d.get("assigneeHandle")}
for e in w.get("effects") or []:
    if e.get("kind") == "terminal" and e.get("action") == "created":
        own.add(e.get("id"))
path = ""
for e in w.get("effects") or []:
    if e.get("kind") == "worktree":
        path = (e.get("id") or "").split("::", 1)[-1]
if not path:
    path = (w.get("worktreeId") or "").split("::", 1)[-1]
if not path:
    option = (w.get("startOptions") or {}).get("worktree") or ""
    if option.startswith("path:"):
        path = option[len("path:"):]
if path and not os.path.isfile(os.path.join(path, ".git")):
    path = ""
coord = os.environ.get("ORCA_TERMINAL_HANDLE")
term_path = os.path.join(fake, "terminals.json")
try:
    terms_doc = json.load(open(term_path))
except Exception:
    sys.exit(0)
terms = terms_doc.get("result", {}).get("terminals") or []
state_path = os.path.join(fake, "state", dispatch)
state_handles = []
if os.path.isfile(state_path):
    state_handles = [ln.strip() for ln in open(state_path) if ln.strip()]
remove = set(state_handles)
for t in terms:
    h = t.get("handle")
    if not h or h == coord:
        continue
    if h in own or (path and t.get("worktreePath") == path):
        remove.add(h)
if coord:
    remove.discard(coord)
if not remove:
    sys.exit(0)
terms_doc["result"]["terminals"] = [t for t in terms if t.get("handle") not in remove]
json.dump(terms_doc, open(term_path, "w"))
NATIVERM
    fi
    exit "$rc" ;;
  "orchestration worker-list --cursor next"*) cat "$FAKE_DIR/workers-next.json" ;;
  "orchestration worker-list"*) cat "$FAKE_DIR/workers.json" 2>/dev/null || echo '{"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  "terminal list"*) [ "${FAKE_LIST_FAILS:-0}" = 0 ] || exit 1; FAKE_DIR="$FAKE_DIR" python3 <<'LIST'
import json, os
path = os.path.join(os.environ["FAKE_DIR"], "terminals.json")
try:
    doc = json.load(open(path))
except Exception:
    doc = {}
explicit_ok = isinstance(doc.get("ok"), bool)
if explicit_ok:
    payload = doc
    if os.environ.get("FAKE_APPEND_COORDINATOR", "1") != "0":
        res = payload.get("result")
        if isinstance(res, dict):
            terms = res.get("terminals")
            if isinstance(terms, list):
                if not any(isinstance(t, dict) and t.get("handle") == "term_coordinator" for t in terms):
                    terms.append({"handle": "term_coordinator", "worktreePath": os.getcwd(), "worktreeId": "repo1::" + os.getcwd()})
    print(json.dumps(payload))
else:
    if isinstance(doc.get("result"), dict):
        payload = {"ok": True, "result": doc["result"]}
    else:
        payload = {"ok": True, "result": {"terminals": doc.get("terminals", []) if isinstance(doc, dict) else []}}
    res = payload.setdefault("result", {})
    if not isinstance(res.get("terminals"), list):
        res["terminals"] = []
    res.setdefault("truncated", False)
    scope = res.get("hostScope")
    if not isinstance(scope, dict):
        res["hostScope"] = {"hostIds": ["local"], "omittedHostIds": []}
    else:
        scope.setdefault("hostIds", ["local"])
        scope.setdefault("omittedHostIds", [])
    if os.environ.get("FAKE_APPEND_COORDINATOR", "1") != "0":
        terms = res["terminals"]
        if not any(t.get("handle") == "term_coordinator" for t in terms):
            terms.append({"handle": "term_coordinator", "worktreePath": os.getcwd(), "worktreeId": "repo1::" + os.getcwd()})
    print(json.dumps(payload))
LIST
    ;;
  "terminal split"*) if [ -f "$FAKE_DIR/split.json" ]; then
    cp "$FAKE_DIR/split-after.json" "$FAKE_DIR/terminals.json"
    cat "$FAKE_DIR/split.json"; exit 0
    fi; echo '{"result":{"terminal":{"handle":"term_new"}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_TERMINAL_HANDLE=term_coordinator ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp" ORCA_PANE_STATE_DIR="$tmp/state"
mkdir -p "$tmp/state" "$tmp/bin" "$tmp/linked" "$tmp/main/.git"
printf 'gitdir: /fixture/worktrees/linked\n' > "$tmp/linked/.git"
# The fake lists the coordinator at the cwd; run outside any git checkout so the script's project root matches it.
cd "$tmp"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "$FAKE_DIR/sleeps.log"\n' > "$tmp/bin/sleep"; chmod +x "$tmp/bin/sleep"
export PATH="$tmp/bin:$PATH"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
closes() { [ -f "$tmp/closes.log" ] && wc -l < "$tmp/closes.log" | tr -d ' ' || echo 0; }
no_generic_close() { [ ! -s "$tmp/closes.log" ]; }
term_absent() {
  python3 - "$tmp/terminals.json" "$1" <<'TP'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if all(t["handle"]!=sys.argv[2] for t in terms) else 1)
TP
}

"$here/worker-panes.sh" run_x term_coordinator dnew >/dev/null 2>&1
check "worker-panes records the pane handle" "$([ "$(cat "$tmp/state/dnew" 2>/dev/null)" = term_new ]; echo $?)"
rm "$tmp/state/dnew"

# The anchor is a separate main checkout shell, not the caller of cleanup.
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_anchor","title":"elon","tabId":"t1","worktreePath":"$tmp/main"},
 {"handle":"term_worker","tabId":"t2","worktreePath":"$tmp/linked"},
 {"handle":"term_setup","tabId":"t2","worktreePath":"$tmp/linked"}]}}
JSON
python3 - "$tmp/terminals.json" "$tmp/split-after.json" <<'SPLIT'
import json,sys
r=json.load(open(sys.argv[1]))
r["result"]["terminals"].append({"handle":"term_pane","tabId":"t1"})
json.dump(r,open(sys.argv[2],"w"))
SPLIT
cat > "$tmp/split.json" <<'JSON'
{"result":{"parent":{"handle":"term_anchor"},"terminal":{"handle":"term_pane"}}}
JSON
cat > "$tmp/show.anchor_case" <<JSON
{"result":{"dispatch":{"status":"released","assigneeHandle":"term_worker"},"worker":{
 "agentTerminalHandle":"term_worker","effects":[
 {"kind":"worktree","action":"reused","id":"wt1::$tmp/linked"},
 {"kind":"terminal","action":"created","id":"term_setup"}]}}}
JSON
"$here/worker-panes.sh" run_x term_anchor anchor_case >/dev/null 2>&1
"$here/worker-pane-close.sh" anchor_case >/dev/null
check "split parent anchor survives cleanup from another terminal" "$(python3 - "$tmp/terminals.json" <<'ANCHOR'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if any(t["handle"]=="term_anchor" for t in terms) else 1)
ANCHOR
echo $?
)"
check "split cleanup clears worker terminals via native release only" "$(no_generic_close && term_absent term_pane && term_absent term_worker && term_absent term_setup && grep -q 'worker-release --dispatch anchor_case' "$tmp/rpc.log"; echo $?)"
rm -f "$tmp/split.json" "$tmp/split-after.json" "$tmp/show.anchor_case" "$tmp/terminals.json" "$tmp/closes.log" "$tmp/state/anchor_case"

echo completed > "$tmp/status.d1"
echo term_a > "$tmp/state/d1"; echo term_b > "$tmp/state/d2"
echo '{"result":{"terminals":[{"handle":"term_a"},{"handle":"term_b"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" d1 >/dev/null
check "close by id clears pane via native release" "$(no_generic_close && term_absent term_a && grep -q 'worker-release --dispatch d1' "$tmp/rpc.log"; echo $?)"
check "close by id deletes its state file" "$([ ! -e "$tmp/state/d1" ]; echo $?)"
check "close by id leaves other panes" "$([ -e "$tmp/state/d2" ] && term_absent term_a; echo $?)"

"$here/worker-pane-close.sh" d1 >/dev/null; rc=$?
check "re-running close is a no-op" "$([ "$rc" = 0 ] && [ ! -e "$tmp/state/d1" ]; echo $?)"
"$here/worker-pane-close.sh" nope >/dev/null
check "unknown dispatch is not an error" "$(no_generic_close; echo $?)"

echo term_c > "$tmp/state/d3"; echo term_d > "$tmp/state/d4"
cat > "$tmp/show.d2" <<JSON
{"result":{"dispatch":{"status":"completed"},"worker":{"effects":[{"kind":"worktree","action":"created_child","id":"wt1::$tmp/gone"}]}}}
JSON
echo completed > "$tmp/status.d2"; echo running > "$tmp/status.d3"; echo dispatched > "$tmp/status.d4"
echo '{"result":{"terminals":[{"handle":"term_b"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" >/dev/null
check "no args clears ended dispatch via native release" "$(no_generic_close && term_absent term_b && grep -q 'worker-release --dispatch d2' "$tmp/rpc.log"; echo $?)"
check "no args keeps running and dispatched" "$([ -e "$tmp/state/d3" ] && [ -e "$tmp/state/d4" ] && no_generic_close; echo $?)"
"$here/worker-pane-close.sh" >/dev/null
check "no args re-run is a no-op" "$(term_absent term_b; echo $?)"

# Sweep: a settled dispatch whose linked worktree still exists keeps its panes (it may be on a correction pass).
rm -f "$tmp/closes.log"
cat > "$tmp/show.dlive" <<JSON
{"result":{"dispatch":{"status":"completed","assigneeHandle":"term_live"},"worker":{"agentTerminalHandle":"term_live","effects":[
  {"kind":"worktree","action":"created_child","id":"wt1::$tmp/linked"}]}}}
JSON
echo term_live > "$tmp/state/dlive"
echo '{"result":{"terminals":[{"handle":"term_live","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" >/dev/null
check "sweep keeps the pane of a settled dispatch whose worktree still exists" "$([ ! -s "$tmp/closes.log" ] && [ -e "$tmp/state/dlive" ]; echo $?)"

"$here/worker-pane-close.sh" dlive >/dev/null
check "explicit id still clears settled dispatch whose worktree exists" "$(no_generic_close && term_absent term_live && grep -q 'worker-release --dispatch dlive' "$tmp/rpc.log"; echo $?)"
# Restore the live record for the marker cases.
echo term_live > "$tmp/state/dlive"; rm -f "$tmp/closes.log"
echo '{"result":{"terminals":[{"handle":"term_live","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
# A --release marker lets the sweep close a released worker whose worktree still exists (Orca retains external terminals).
mkdir -p "$tmp/state/released"; : > "$tmp/state/released/dlive"
"$here/worker-pane-close.sh" >/dev/null
check "sweep clears released dispatch whose worktree still exists" "$(no_generic_close && term_absent term_live && [ ! -e "$tmp/state/dlive" ] && [ ! -e "$tmp/state/released/dlive" ]; echo $?)"
rm -f "$tmp/closes.log"
echo term_rel > "$tmp/state/drel"
printf '{"result":{"dispatch":{"status":"completed"},"worker":{"effects":[{"kind":"worktree","action":"created_child","id":"wt1::%s/linked"}]}}}' "$tmp" > "$tmp/show.drel"
echo '{"result":{"terminals":[{"handle":"term_rel","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" --release drel >/dev/null
check "--release native-clears and drops marker" "$(grep -q 'worker-release --dispatch drel' "$tmp/rpc.log" && no_generic_close && term_absent term_rel && [ ! -e "$tmp/state/released/drel" ]; echo $?)"
rm -f "$tmp/closes.log" "$tmp/show.dlive" "$tmp/terminals.json"

# Leftover terminals: a validated worker leaves its agent and setup terminals, a shell in its worktree and
# maybe a pane whose split timed out. Close the ones still listed, never the owner's or other projects'.
rm -f "$tmp/closes.log"
cat > "$tmp/show.d6" <<JSON
{"result":{"dispatch":{"status":"released","assigneeHandle":"term_agent"},
 "worker":{"agentTerminalHandle":"term_agent","effects":[
  {"kind":"worktree","action":"created_child","id":"wt1::$tmp/linked"},
  {"kind":"terminal","role":"agent","action":"created","id":"term_agent"},
  {"kind":"terminal","role":"setup","action":"created","id":"term_setup"},
  {"kind":"terminal","role":"setup","action":"created","id":"term_gone"}]}}}
JSON
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[
 {"handle":"term_agent","worktreePath":"$tmp/linked"},{"handle":"term_setup","worktreePath":"$tmp/linked"},
 {"handle":"term_shell","worktreePath":"$tmp/linked"},{"handle":"term_owner","worktreePath":"$tmp/main"},
 {"handle":"term_wt_prefix","worktreePath":"$tmp/linked-other"}]}}
JSON
"$here/worker-pane-close.sh" d6 >/dev/null
check "leftover: native clears agent terminal" "$(no_generic_close && term_absent term_agent; echo $?)"
check "leftover: native clears setup terminal" "$(term_absent term_setup; echo $?)"
check "leftover: native clears shell in worker worktree" "$(term_absent term_shell; echo $?)"
check "leftover: skips handle no longer listed" "$(term_absent term_gone; echo $?)"
check "leftover: leaves owner and other worktree terminals" "$(python3 - "$tmp/terminals.json" <<'OWN'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if any(t["handle"]=="term_owner" for t in terms) and any(t["handle"]=="term_wt_prefix" for t in terms) else 1)
OWN
echo $?)"
check "leftover: never uses generic terminal close" "$(no_generic_close; echo $?)"

# Reusing a linked worktree still owns its leftover shell terminals.
rm -f "$tmp/closes.log"
sed 's/"created_child"/"reused"/' "$tmp/show.d6" > "$tmp/show.reused"
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_shell_one","worktreePath":"$tmp/linked"},{"handle":"term_shell_two","worktreePath":"$tmp/linked"}]}}
JSON
"$here/worker-pane-close.sh" reused >/dev/null
check "reused worktree: native clears both leftover shells" "$(no_generic_close && term_absent term_shell_one && term_absent term_shell_two; echo $?)"

# Missing worktree effects fall back to the worker identity, then its start options.
for source in worktreeId startOptions; do
  rm -f "$tmp/closes.log"
  python3 - "$tmp/show.fallback" "$tmp/linked" "$source" <<'FIXTURE'
import json,sys
file,path,source=sys.argv[1:]
worker={"worktreeId":"wt1::"+path} if source=="worktreeId" else {"startOptions":{"worktree":"path:"+path}}
json.dump({"result":{"dispatch":{"status":"released"},"worker":worker}},open(file,"w"))
FIXTURE
  cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_fallback_shell","worktreePath":"$tmp/linked"}]}}
JSON
  "$here/worker-pane-close.sh" fallback >/dev/null
  check "$source fallback: native clears leftover shell" "$(no_generic_close && term_absent term_fallback_shell; echo $?)"
done

# A pane recorded in the state file is closed once even when it is also in the listing.
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_shell","worktreePath":"$tmp/linked"}]}}
JSON
rm -f "$tmp/closes.log"; echo term_shell > "$tmp/state/d6"
"$here/worker-pane-close.sh" d6 >/dev/null
check "leftover: recorded pane cleared once via native release" "$(no_generic_close && term_absent term_shell && [ ! -e "$tmp/state/d6" ]; echo $?)"

# Still-active dispatch: never close its terminals.
rm -f "$tmp/closes.log"; sed 's/"released"/"running"/' "$tmp/show.d6" > "$tmp/show.d7"
echo term_shell > "$tmp/state/d7"
"$here/worker-pane-close.sh" d7 >/dev/null
check "active dispatch: no terminal is closed" "$([ ! -e "$tmp/closes.log" ]; echo $?)"

# A reused main checkout has a .git directory and is matched by handle only, never by cwd.
rm -f "$tmp/closes.log"
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_agent","worktreePath":"$tmp/main"},{"handle":"term_owner","worktreePath":"$tmp/main"}]}}
JSON
cat > "$tmp/show.d8" <<JSON
{"result":{"dispatch":{"status":"failed"},"worker":{"agentTerminalHandle":"term_agent","effects":[
  {"kind":"worktree","action":"reused","id":"wt0::$tmp/main"},
  {"kind":"terminal","role":"agent","action":"created","id":"term_agent"}]}}}
JSON
"$here/worker-pane-close.sh" d8 >/dev/null
check "current worktree: native clears only worker terminal" "$(no_generic_close && term_absent term_agent && python3 - "$tmp/terminals.json" <<'MAIN'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if any(t["handle"]=="term_owner" for t in terms) else 1)
MAIN
echo $?)"

# A retry reuses the failed dispatch's terminal: never close a terminal a live dispatch also uses.
rm -f "$tmp/closes.log" "$tmp/workers.json"
cat > "$tmp/show.dfail" <<'JSON'
{"result":{"dispatch":{"status":"failed","assigneeHandle":"term_shared"},"worker":{"agentTerminalHandle":"term_shared","effects":[]}}}
JSON
echo term_shared > "$tmp/state/dfail"
echo '{"result":{"terminals":[{"handle":"term_shared"}]}}' > "$tmp/terminals.json"
echo '{"result":{"workers":[{"dispatchId":"dfail","dispatchStatus":"failed","agentTerminalHandle":"term_shared"},{"dispatchId":"dretry","dispatchStatus":"running","agentTerminalHandle":"term_shared","resource":{"terminalHandle":"term_shared"}}],"page":{"hasMore":false}}}' > "$tmp/workers.json"
"$here/worker-pane-close.sh" dfail >/dev/null
check "retry sharing the terminal: not closed" "$([ ! -s "$tmp/closes.log" ]; echo $?)"
check "retry sharing the terminal: record kept" "$([ -e "$tmp/state/dfail" ]; echo $?)"
"$here/worker-pane-close.sh" >/dev/null
check "no args: shared terminal of a live retry is not closed" "$(no_generic_close; echo $?)"
echo '{"result":{"workers":[{"dispatchId":"dfail","dispatchStatus":"failed","agentTerminalHandle":"term_shared"},{"dispatchId":"dretry","dispatchStatus":"completed","agentTerminalHandle":"term_shared"}],"page":{"hasMore":false}}}' > "$tmp/workers.json"
echo '{"result":{"terminals":[{"handle":"term_shared"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" dfail >/dev/null
check "retry ended too: native clears shared terminal" "$(no_generic_close && term_absent term_shared; echo $?)"
rm -f "$tmp/workers.json" "$tmp/show.dfail"

# The recorded pane file may list several handles (one per line); all are closed.
rm -f "$tmp/closes.log" "$tmp/show.d9"; printf 'term_p1\nterm_p2\n' > "$tmp/state/d9"
echo completed > "$tmp/status.d9"
echo '{"result":{"terminals":[{"handle":"term_p1"},{"handle":"term_p2"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" d9 >/dev/null
check "multi-line state native-clears every handle" "$(no_generic_close && term_absent term_p1 && term_absent term_p2; echo $?)"

# A failed native verify retains the record (terminal still listed after release).
rm -f "$tmp/closes.log"
echo completed > "$tmp/status.retry"; echo term_retry > "$tmp/state/retry"
echo '{"result":{"terminals":[{"handle":"term_retry"}]}}' > "$tmp/terminals.json"
: > "$tmp/sleeps.log"
FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" retry >/dev/null
check "native verify retains record when terminal lingers" "$([ -e "$tmp/state/retry" ] && no_generic_close; echo $?)"
check "no retry backoff sleep after native-only verify" "$([ ! -s "$tmp/sleeps.log" ]; echo $?)"
# If authority changes while retrying, stop closing and retain the handle.
rm -f "$tmp/closes.log"
echo completed > "$tmp/status.reactivate"; echo term_retry > "$tmp/state/reactivate"
echo '{"result":{"terminals":[{"handle":"term_retry"}]}}' > "$tmp/terminals.json"
FAKE_REACTIVATE=reactivate FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" reactivate >/dev/null
check "dispatch becoming running stops native cleanup" "$([ -e "$tmp/state/reactivate" ] && no_generic_close; echo $?)"
rm "$tmp/state/reactivate"
# No recorded pane: discover ended workers from the current Run, with pagination.
cat > "$tmp/workers.json" <<JSON
{"result":{"workers":[{"dispatchId":"d7","resource":{"worktreeId":"repo1::$tmp/linked"}}],"page":{"hasMore":true,"nextCursor":"next"}}}
JSON
cat > "$tmp/workers-next.json" <<JSON
{"result":{"workers":[{"dispatchId":"d6","dispatchStatus":"released","resource":{"worktreeId":"repo1::$tmp/linked"}},{"dispatchId":"other","dispatchStatus":"completed","resource":{"worktreeId":"repo2::/other"}}],"page":{"hasMore":false}}}
JSON
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_agent","worktreePath":"$tmp/linked"},{"handle":"term_other","worktreePath":"/other"}]}}
JSON
sed "s#$tmp/linked#$tmp/gone#" "$tmp/show.d6" > "$tmp/show.d6.gone" && mv "$tmp/show.d6.gone" "$tmp/show.d6"
echo '{"result":{"dispatch":{"status":"completed","assigneeHandle":"term_other"}}}' > "$tmp/show.other"
rm -f "$tmp/closes.log"
"$here/worker-pane-close.sh" >/dev/null
check "wake sweep discovers unrecorded leftovers via native release" "$(no_generic_close && term_absent term_agent && grep -q 'worker-release --dispatch d6' "$tmp/rpc.log"; echo $?)"
check "wake sweep excludes ended dispatches from other projects" "$(python3 - "$tmp/terminals.json" <<'OTHER'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if any(t["handle"]=="term_other" for t in terms) else 1)
OTHER
echo $?)"
check "wake sweep never generic-closes coordinator" "$(no_generic_close; echo $?)"
rm "$tmp/workers.json"
# Budget expiry retains the record for a later wake sweep.
echo completed > "$tmp/status.stuck"; echo term_stuck > "$tmp/state/stuck"
echo '{"result":{"terminals":[{"handle":"term_stuck"}]}}' > "$tmp/terminals.json"
FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" stuck >/dev/null
check "unverified native close retains record" "$([ -e "$tmp/state/stuck" ] && no_generic_close; echo $?)"
FAKE_LIST_FAILS=1 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" stuck >/dev/null
check "failed list cannot prove disappearance" "$([ -e "$tmp/state/stuck" ]; echo $?)"
rm "$tmp/state/stuck"
echo term_unknown > "$tmp/state/unknown"
rm -f "$tmp/closes.log"
"$here/worker-pane-close.sh" unknown >/dev/null
check "unknown dispatch status preserves pane" "$([ -e "$tmp/state/unknown" ] && [ ! -s "$tmp/closes.log" ]; echo $?)"
echo completed > "$tmp/status.coordinator"
echo term_coordinator > "$tmp/state/coordinator"
rm -f "$tmp/closes.log"
"$here/worker-pane-close.sh" coordinator >/dev/null
check "explicit cleanup cannot close its coordinator even with a stale record" "$([ ! -s "$tmp/closes.log" ] && [ -e "$tmp/state/coordinator" ]; echo $?)"
echo term_e > "$tmp/state/d5"; echo released > "$tmp/status.d5"
echo '{"result":{"terminals":[{"handle":"term_e"}]}}' > "$tmp/terminals.json"
FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" d5 >/dev/null; rc=$?
check "terminal still listed after native release keeps state without error" "$([ "$rc" = 0 ] && [ -e "$tmp/state/d5" ] && no_generic_close; echo $?)"

echo dispatched > "$tmp/status.live-release"
rm -f "$tmp/state/released/live-release"
"$here/worker-pane-close.sh" --release live-release > "$tmp/live-release.out" 2>&1; rc=$?
check "live --release refuses with actionable message and no marker" "$([ "$rc" != 0 ] && grep -q 'worker-stop explicitly' "$tmp/live-release.out" && [ ! -e "$tmp/state/released/live-release" ]; echo $?)"

# #442-shaped exit-0 retained: no marker, no terminal close
cat > "$tmp/release.ctx442.json" <<'JSON'
{"ok":true,"result":{"dispatchId":"ctx442","state":"retained","reason":"user_takeover","processAction":"none","archive":null}}
JSON
echo completed > "$tmp/status.ctx442"
echo term_442 > "$tmp/state/ctx442"
echo '{"result":{"terminals":[{"handle":"term_442","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
rm -f "$tmp/closes.log"
"$here/worker-pane-close.sh" --release ctx442 > "$tmp/retained442.out" 2>&1; rc=$?
check "retained --release exits 0 without closing terminals" "$([ "$rc" = 0 ] && [ ! -s "$tmp/closes.log" ] && [ -e "$tmp/state/ctx442" ] && [ ! -e "$tmp/state/released/ctx442" ]; echo $?)"
check "retained --release reports reason" "$(grep -q 'user_takeover' "$tmp/retained442.out"; echo $?)"

# Stale released marker must not authorize terminal close when native release is retained
stale_state="$tmp/state_stale"; stale_fake="$tmp/fake_stale"
mkdir -p "$stale_state/released" "$stale_fake"
: > "$stale_state/released/dstale"
echo term_stale > "$stale_state/dstale"
cat > "$stale_fake/release.dstale.json" <<'JSON'
{"ok":true,"result":{"dispatchId":"dstale","state":"retained","reason":"user_takeover","processAction":"none","archive":null}}
JSON
echo completed > "$stale_fake/status.dstale"
echo '{"result":{"terminals":[{"handle":"term_stale","worktreePath":"'"$tmp"'/linked"}]}}' > "$stale_fake/terminals.json"
cp "$tmp/orca" "$stale_fake/orca"
rm -f "$stale_fake/closes.log"
ORCA_PANE_STATE_DIR="$stale_state" FAKE_DIR="$stale_fake" ORCA_CLI_COMMAND="$stale_fake/orca" \
  "$here/worker-pane-close.sh" >/dev/null 2>&1
check "stale marker plus retained native release does not close terminals" "$([ ! -s "$stale_fake/closes.log" ] && [ -e "$stale_state/dstale" ]; echo $?)"

# --release with released JSON but nonzero CLI exit: no marker, no close
cat > "$tmp/release.dnz.json" <<'JSON'
{"ok":true,"result":{"dispatchId":"dnz","state":"released","processAction":"closed_agent_terminal","archive":"captured"}}
JSON
echo completed > "$tmp/status.dnz"
echo term_nz > "$tmp/state/dnz"
echo '{"result":{"terminals":[{"handle":"term_nz"}]}}' > "$tmp/terminals.json"
rm -f "$tmp/closes.log" "$tmp/state/released/dnz"
FAKE_RELEASE_EXIT=1 "$here/worker-pane-close.sh" --release dnz > "$tmp/dnz.out" 2>&1; rc=$?
check "nonzero release exit refuses marker and close" "$([ "$rc" != 0 ] && [ ! -s "$tmp/closes.log" ] && [ ! -e "$tmp/state/released/dnz" ]; echo $?)"

# Wrong dispatch id in release response on --release
cat > "$tmp/release.dwrong.json" <<'JSON'
{"ok":true,"result":{"dispatchId":"d_other","state":"released","processAction":"closed_agent_terminal"}}
JSON
echo completed > "$tmp/status.dwrong"
echo term_wrong > "$tmp/state/dwrong"
rm -f "$tmp/closes.log" "$tmp/state/released/dwrong"
"$here/worker-pane-close.sh" --release dwrong > "$tmp/dwrong.out" 2>&1; rc=$?
check "wrong dispatch id on --release refuses marker and generic close" "$([ "$rc" != 0 ] && no_generic_close && [ ! -e "$tmp/state/released/dwrong" ]; echo $?)"

# Missing dispatchId in release response fails closed on --release and explicit close
cat > "$tmp/release.dmiss.json" <<'JSON'
{"ok":true,"result":{"state":"released","processAction":"closed_agent_terminal"}}
JSON
echo completed > "$tmp/status.dmiss"
echo term_miss > "$tmp/state/dmiss"
echo '{"result":{"terminals":[{"handle":"term_miss"}]}}' > "$tmp/terminals.json"
rm -f "$tmp/closes.log" "$tmp/state/released/dmiss"
"$here/worker-pane-close.sh" --release dmiss > "$tmp/dmiss-release.out" 2>&1; rc=$?
check "missing dispatchId on --release refuses marker and close" "$([ "$rc" != 0 ] && no_generic_close && python3 - "$tmp/terminals.json" <<'MISS'
import json,sys
terms=json.load(open(sys.argv[1]))["result"]["terminals"]
sys.exit(0 if any(t["handle"]=="term_miss" for t in terms) else 1)
MISS
echo $?)"
"$here/worker-pane-close.sh" dmiss > "$tmp/dmiss-id.out" 2>&1; rc=$?
check "missing dispatchId on explicit close retains terminals" "$([ "$rc" = 0 ] && no_generic_close && [ -e "$tmp/state/dmiss" ]; echo $?)"

# ok:false with non-boolean ok fails closed
cat > "$tmp/release.dbadok.json" <<'JSON'
{"ok":"true","result":{"dispatchId":"dbadok","state":"released","processAction":"closed_agent_terminal"}}
JSON
echo completed > "$tmp/status.dbadok"
echo term_bad > "$tmp/state/dbadok"
rm -f "$tmp/state/released/dbadok"
"$here/worker-pane-close.sh" --release dbadok > "$tmp/dbadok.out" 2>&1; rc=$?
check "nonboolean ok on --release fails closed" "$([ "$rc" != 0 ] && no_generic_close; echo $?)"

# Host-scope completeness: incomplete native inventory must not claim verified close.
echo completed > "$tmp/status.dscope"
echo term_remote_scope > "$tmp/state/dscope"
cat > "$tmp/terminals.json" <<'JSON'
{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":["niteking"]}}}
JSON
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dscope > "$tmp/dscope.out" 2>&1
check "omitted host ids retain pane state" "$([ -e "$tmp/state/dscope" ]; echo $?)"
check "omitted host ids do not print verified closed" "$(grep -q '^closed dscope' "$tmp/dscope.out"; rc=$?; [ "$rc" != 0 ]; echo $?)"

echo completed > "$tmp/status.dtrunc"
echo term_trunc > "$tmp/state/dtrunc"
cat > "$tmp/terminals.json" <<'JSON'
{"ok":true,"result":{"terminals":[],"truncated":true,"hostScope":{"hostIds":["local"],"omittedHostIds":[]}}}
JSON
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dtrunc > "$tmp/dtrunc.out" 2>&1
check "truncated terminal list retains state" "$([ -e "$tmp/state/dtrunc" ]; echo $?)"
check "truncated list does not print verified closed" "$(! grep -q '^closed dtrunc' "$tmp/dtrunc.out"; echo $?)"

echo completed > "$tmp/status.dbadlist"
echo term_badlist > "$tmp/state/dbadlist"
echo '{"ok":false,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]}}}' > "$tmp/terminals.json"
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dbadlist > "$tmp/dbadlist.out" 2>&1
check "ok false terminal list retains state" "$([ -e "$tmp/state/dbadlist" ]; echo $?)"

echo completed > "$tmp/status.dnoscope"
echo term_noscope > "$tmp/state/dnoscope"
echo '{"ok":true,"result":{"terminals":[],"truncated":false}}' > "$tmp/terminals.json"
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dnoscope > "$tmp/dnoscope.out" 2>&1
check "missing hostScope retains state" "$([ -e "$tmp/state/dnoscope" ]; echo $?)"
check "missing hostScope does not print verified closed" "$(! grep -q '^closed dnoscope' "$tmp/dnoscope.out"; echo $?)"

inventory_negative() {
  local id=$1 json=$2
  echo completed > "$tmp/status.$id"
  echo "term_${id}" > "$tmp/state/$id"
  printf '%s' "$json" > "$tmp/terminals.json"
  FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" "$id" > "$tmp/${id}.out" 2>&1
  check "inventory $id retains state" "$([ -e "$tmp/state/$id" ]; echo $?)"
  check "inventory $id no verified closed" "$(! grep -q "^closed $id" "$tmp/${id}.out"; echo $?)"
}

scope='{"hostIds":["local"],"omittedHostIds":[]}'
while IFS='|' read -r tid tjson; do
  [ -n "$tid" ] || continue
  inventory_negative "$tid" "$tjson"
done <<CASES
dnotrunc|{"ok":true,"result":{"terminals":[],"hostScope":$scope}}
dtruncnull|{"ok":true,"result":{"terminals":[],"truncated":null,"hostScope":$scope}}
dtrunc0|{"ok":true,"result":{"terminals":[],"truncated":0,"hostScope":$scope}}
dtruncstr|{"ok":true,"result":{"terminals":[],"truncated":"false","hostScope":$scope}}
dresmiss|{"ok":true}
dhostmiss|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"omittedHostIds":[]}}}
dhostnull|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":null,"omittedHostIds":[]}}}
dhostempty|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":[],"omittedHostIds":[]}}}
dhostnum|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":[1],"omittedHostIds":[]}}}
dhostblank|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":[""],"omittedHostIds":[]}}}
domitmiss|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"]}}}
domitbad|{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":"x"}}}
dtermsbad|{"ok":true,"result":{"terminals":"x","truncated":false,"hostScope":$scope}}
dtermempty|{"ok":true,"result":{"terminals":[{}],"truncated":false,"hostScope":$scope}}
dtermnull|{"ok":true,"result":{"terminals":[null],"truncated":false,"hostScope":$scope}}
dtermstr|{"ok":true,"result":{"terminals":["x"],"truncated":false,"hostScope":$scope}}
dhandnull|{"ok":true,"result":{"terminals":[{"handle":null}],"truncated":false,"hostScope":$scope}}
dhandempty|{"ok":true,"result":{"terminals":[{"handle":""}],"truncated":false,"hostScope":$scope}}
dhandnum|{"ok":true,"result":{"terminals":[{"handle":1}],"truncated":false,"hostScope":$scope}}
CASES

echo completed > "$tmp/status.dpresent"
echo term_dpresent > "$tmp/state/dpresent"
cat > "$tmp/terminals.json" <<'JSON'
{"ok":true,"result":{"terminals":[{"handle":"term_dpresent"}],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]}}}
JSON
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dpresent > "$tmp/dpresent.out" 2>&1
check "target still listed retains state" "$([ -e "$tmp/state/dpresent" ]; echo $?)"
check "target still listed does not print verified closed" "$(! grep -q '^closed dpresent' "$tmp/dpresent.out"; echo $?)"

echo completed > "$tmp/status.dinv"
echo term_inv > "$tmp/state/dinv"
cat > "$tmp/terminals.json" <<'JSON'
{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]}}}
JSON
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dinv > "$tmp/dinv.out" 2>&1
check "complete inventory verifies absence and clears state" "$([ ! -e "$tmp/state/dinv" ]; echo $?)"
check "complete inventory prints verified closed" "$(grep -q '^closed dinv (1)$' "$tmp/dinv.out"; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
