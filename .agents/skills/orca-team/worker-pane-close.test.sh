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
  "worktree set "*) echo "$*" >> "$FAKE_DIR/board.log" ;;
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
if os.environ.get("FAKE_REAL_RELEASE") == "1":
    show = json.load(open(os.path.join(os.environ["FAKE_DIR"], "show." + dispatch)))
    agent = show["result"].get("terminal")
    p = os.path.join(os.environ["FAKE_DIR"], "terminals.json")
    doc = json.load(open(p))
    doc["result"]["terminals"] = [t for t in doc["result"]["terminals"] if t.get("handle") != agent]
    json.dump(doc, open(p, "w"))
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
  "orchestration run-list"*) [ "${FAKE_RUNLIST_FAILS:-0}" = 0 ] || exit 1
    case "$*" in
      *"--cursor next"*) cat "$FAKE_DIR/runs-next.json" ;;
      *) cat "$FAKE_DIR/runs.json" 2>/dev/null || echo '{"ok":true,"result":{"runs":[{"id":"run_caller","coordinator_handle":"term_coordinator"}]}}' ;;
    esac ;;
  "orchestration worker-list"*)
    wl_run=$(printf '%s' "$*" | sed -n 's/.*--run \([^ ]*\).*/\1/p'); wl_sfx=""
    case "$*" in *"--cursor next"*) wl_sfx="-next" ;; esac
    if [ -n "$wl_run" ] && [ -f "$FAKE_DIR/workers-$wl_run$wl_sfx.json" ]; then cat "$FAKE_DIR/workers-$wl_run$wl_sfx.json"
    elif [ -n "$wl_sfx" ]; then cat "$FAKE_DIR/workers-next.json"
    else cat "$FAKE_DIR/workers.json" 2>/dev/null || echo '{"result":{"workers":[],"page":{"hasMore":false}}}'; fi ;;
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

# --release sets completed on a worktree whose branch has no PR, and leaves one that has a PR alone.
mkdir -p "$tmp/gitwt" && git init -q -b nopr-branch "$tmp/gitwt" && : > "$tmp/board.log"
mv "$tmp/gitwt/.git" "$tmp/gitwt.gitdir" && printf 'gitdir: %s\n' "$tmp/gitwt.gitdir" > "$tmp/gitwt/.git"
printf '#!/bin/sh\nprintf "%%s" "$FAKE_PR_COUNT"\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
printf '{"result":{"dispatch":{"status":"completed"},"worker":{"effects":[{"kind":"worktree","action":"created_child","id":"wt1::%s/gitwt"}]}}}' "$tmp" > "$tmp/show.dnopr"
echo '{"result":{"terminals":[]}}' > "$tmp/terminals.json"
FAKE_PR_COUNT=0 "$here/worker-pane-close.sh" --release dnopr >/dev/null 2>&1
check "--release with no PR sets completed" "$([ "$(cat "$tmp/board.log")" = "worktree set --worktree path:$tmp/gitwt --workspace-status completed" ]; echo $?)"
: > "$tmp/board.log"
FAKE_PR_COUNT=1 "$here/worker-pane-close.sh" --release dnopr >/dev/null 2>&1
check "--release with a PR leaves the status alone" "$([ ! -s "$tmp/board.log" ]; echo $?)"
: > "$tmp/board.log"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"
"$here/worker-pane-close.sh" --release dnopr >/dev/null 2>&1
check "--release with gh failing leaves the status alone" "$([ ! -s "$tmp/board.log" ]; echo $?)"
rm -f "$tmp/bin/gh" "$tmp/show.dnopr" "$tmp/terminals.json" "$tmp/closes.log"

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
FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" retry >/dev/null
check "verify retains record when terminal lingers after close" "$([ -e "$tmp/state/retry" ] && [ "$(cat "$tmp/closes.log")" = term_retry ]; echo $?)"
check "no retry backoff sleep after native-only verify" "$([ ! -s "$tmp/sleeps.log" ]; echo $?)"
# If authority changes while retrying, stop closing and retain the handle.
rm -f "$tmp/closes.log"
echo completed > "$tmp/status.reactivate"; echo term_retry > "$tmp/state/reactivate"
echo '{"result":{"terminals":[{"handle":"term_retry"}]}}' > "$tmp/terminals.json"
FAKE_REACTIVATE=reactivate FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" reactivate >/dev/null
check "dispatch becoming running stops cleanup" "$([ -e "$tmp/state/reactivate" ] && [ "$(closes)" = 1 ]; echo $?)"
rm "$tmp/state/reactivate"
# No recorded pane: discover ended workers from the current Run, with pagination.
cat > "$tmp/workers.json" <<JSON
{"result":{"workers":[{"dispatchId":"d7","resource":{"worktreeId":"repo1::$tmp/live7"}}],"page":{"hasMore":true,"nextCursor":"next"}}}
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
FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" stuck >/dev/null
check "unverified close retains record" "$([ -e "$tmp/state/stuck" ]; echo $?)"
FAKE_LIST_FAILS=1 FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" stuck >/dev/null
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
FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" d5 >/dev/null; rc=$?
check "terminal still listed after release and close keeps state without error" "$([ "$rc" = 0 ] && [ -e "$tmp/state/d5" ]; echo $?)"

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
FAKE_APPEND_COORDINATOR=0 FAKE_SKIP_NATIVE_RM=1 FAKE_LINGERS=99 "$here/worker-pane-close.sh" dpresent > "$tmp/dpresent.out" 2>&1
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


# Current Orca: flat worker-show (state/stage/liveness/terminal/workspace) and worker-list rows without dispatchStatus.
# Release closes only the agent terminal, so the coordinator's split pane and the worker's Setup terminal are ours to close.
flat_show() { # $1 dispatch $2 state $3 stage $4 liveness $5 agent terminal $6 worktree path
  printf '{"ok":true,"result":{"dispatchId":"%s","taskId":"t1","runId":"r1","state":"%s","stage":"%s","liveness":"%s","terminal":"%s","workspace":"repo1::%s"}}' "$@" > "$tmp/show.$1"
}
flat_terms() { # the worker's agent and Setup terminals in its worktree, its pane, and the caller's own terminal there too
  cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_fagent","worktreePath":"$tmp/linked"},{"handle":"term_fsetup","title":"Setup","worktreePath":"$tmp/linked"},
 {"handle":"term_fpane","tabId":"t1","worktreePath":"$tmp/main"},{"handle":"term_coordinator","worktreePath":"$tmp/linked"},
 {"handle":"term_fowner","worktreePath":"$tmp/main"}]}}
JSON
}
listed() { ! term_absent "$1"; }
rm -f "$tmp/closes.log" "$tmp/workers.json" "$tmp/state/released/dflat"
flat_show dflat succeeded released exited term_fagent "$tmp/linked"; flat_terms; echo term_fpane > "$tmp/state/dflat"
FAKE_REAL_RELEASE=1 "$here/worker-pane-close.sh" dflat > "$tmp/dflat.out" 2>&1
check "flat succeeded: native release runs" "$(grep -q 'worker-release --dispatch dflat' "$tmp/rpc.log"; echo $?)"
check "flat succeeded: coordinator split pane closed" "$(term_absent term_fpane && grep -qx term_fpane "$tmp/closes.log"; echo $?)"
check "flat succeeded: leftover Setup terminal closed" "$(term_absent term_fsetup && grep -qx term_fsetup "$tmp/closes.log"; echo $?)"
check "flat succeeded: agent terminal left to native release" "$(term_absent term_fagent && ! grep -qx term_fagent "$tmp/closes.log"; echo $?)"
check "flat succeeded: own terminal never closed" "$(listed term_coordinator && ! grep -qx term_coordinator "$tmp/closes.log"; echo $?)"
check "flat succeeded: owner terminal outside the worktree kept" "$(listed term_fowner; echo $?)"
check "flat succeeded: record dropped after verified close" "$([ ! -e "$tmp/state/dflat" ] && grep -q '^closed dflat' "$tmp/dflat.out"; echo $?)"

for row in "ready input_accepted live" "ready released_pending live"; do
  set -- $row; rm -f "$tmp/closes.log" "$tmp/rpc.log"
  flat_show dflive "$1" "$2" "$3" term_fagent "$tmp/linked"; flat_terms; echo term_fpane > "$tmp/state/dflive"
  FAKE_REAL_RELEASE=1 "$here/worker-pane-close.sh" dflive >/dev/null 2>&1
  check "flat $1/$2/$3: nothing released or closed" "$([ ! -s "$tmp/closes.log" ] && ! grep -q dflive "$tmp/rpc.log" 2>/dev/null && [ -e "$tmp/state/dflive" ]; echo $?)"
done
rm -f "$tmp/state/dflive"

rm -f "$tmp/closes.log" "$tmp/state/released/dfrel"
flat_show dfrel succeeded released exited term_fagent "$tmp/linked"; flat_terms; echo term_fpane > "$tmp/state/dfrel"
FAKE_REAL_RELEASE=1 "$here/worker-pane-close.sh" --release dfrel > "$tmp/dfrel.out" 2>&1; rc=$?
check "flat --release of a succeeded worker is accepted" "$([ "$rc" = 0 ] && ! grep -q refusing "$tmp/dfrel.out"; echo $?)"
check "flat --release closes pane and Setup terminal" "$(term_absent term_fpane && term_absent term_fsetup && listed term_coordinator; echo $?)"

# Released with processAction none: Orca kept every terminal; the leftovers are still closed.
rm -f "$tmp/closes.log"
printf '{"ok":true,"result":{"dispatchId":"dfnone","state":"released","processAction":"none"}}' > "$tmp/release.dfnone.json"
flat_show dfnone succeeded released exited term_fagent "$tmp/linked"; flat_terms; echo term_fpane > "$tmp/state/dfnone"
"$here/worker-pane-close.sh" --release dfnone >/dev/null 2>&1
check "released with processAction none still closes pane and Setup" "$(term_absent term_fpane && term_absent term_fsetup && listed term_fagent && listed term_coordinator; echo $?)"

# worker-list rows without dispatchStatus: a live row keeps a shared terminal, a final one does not.
rm -f "$tmp/closes.log"
flat_show dfshare failed released exited term_fshared "$tmp/gone"
echo term_fshared > "$tmp/state/dfshare"
echo '{"result":{"terminals":[{"handle":"term_fshared"}]}}' > "$tmp/terminals.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"dfshare","state":"failed","liveness":"exited","terminal":"term_fshared"},{"dispatchId":"dfretry","state":"ready","liveness":"live","terminal":"term_fshared","workspace":"repo1::'"$tmp"'/linked"}]}}' > "$tmp/workers.json"
FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" dfshare >/dev/null 2>&1
check "flat list: terminal of a live retry is kept" "$([ ! -s "$tmp/closes.log" ] && [ -e "$tmp/state/dfshare" ]; echo $?)"
rm -f "$tmp/state/dfshare"

# Wake sweep discovers a finished worker from flat worker-list rows (state, workspace, no dispatchStatus).
rm -f "$tmp/closes.log"; for f in "$tmp"/state/*; do [ ! -f "$f" ] || rm -f "$f"; done
flat_show dfsweep succeeded released exited term_fsweep "$tmp/gone"
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_fsweep"},{"handle":"term_fother","worktreePath":"/other"}]}}
JSON
cat > "$tmp/workers.json" <<JSON
{"ok":true,"result":{"workers":[{"dispatchId":"dfsweep","taskId":"t1","state":"succeeded","liveness":"exited","terminal":"term_fsweep","workspace":"repo1::$tmp/gone","host":"local"},
 {"dispatchId":"dfother","state":"succeeded","liveness":"exited","terminal":"term_fother","workspace":"repo2::/other"}],"scope":{"run":"r1","source":"flag"}}}
JSON
flat_show dfother succeeded released exited term_fother /other
FAKE_SKIP_NATIVE_RM=1 "$here/worker-pane-close.sh" >/dev/null 2>&1
check "flat sweep: release of a discovered finished worker" "$(grep -q 'worker-release --dispatch dfsweep' "$tmp/rpc.log"; echo $?)"
check "flat sweep: other project's worker untouched" "$(! grep -q 'worker-release --dispatch dfother' "$tmp/rpc.log" && listed term_fother; echo $?)"
rm -f "$tmp/workers.json"

# #515: a worker on another host. Its worktree path does not exist on this machine, so the Setup terminal and the
# plain Terminal 1 left on that host must still close, matched by worktree id. Protected: the caller's own terminal,
# the lead, a running worker's terminal, and anything on the repo's main branch.
rm -f "$tmp/closes.log" "$tmp/rpc.log" "$tmp/workers.json" "$tmp/state/released/dremote"
for f in "$tmp"/state/*; do [ ! -f "$f" ] || rm -f "$f"; done
rwt=/remote/host/orca/workspaces/repo1/wt-remote
flat_show dremote succeeded released exited term_ragent "$rwt"
cat > "$tmp/terminals.json" <<JSON
{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["local","host2"],"omittedHostIds":[]},"terminals":[
 {"handle":"term_ragent","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_rsetup","title":"Setup","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_rplain","title":"Terminal 1","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_coordinator","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_rlead","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_rrunning","worktreeId":"repo1::$rwt","worktreePath":"$rwt","branch":"refs/heads/mingster/wt-remote","executionHostId":"host2"},
 {"handle":"term_rmain","worktreeId":"repo1::/remote/host/repo1","worktreePath":"/remote/host/repo1","branch":"refs/heads/main","executionHostId":"host2"}]}}
JSON
flat_show drunning ready input_accepted live term_rrunning "$rwt"
flat_show dlead ready input_accepted live term_rlead "$rwt"
cat > "$tmp/workers.json" <<JSON
{"ok":true,"result":{"workers":[
 {"dispatchId":"drunning","state":"ready","liveness":"live","terminal":"term_rrunning","workspace":"repo1::/remote/host/orca/workspaces/repo1/wt-live"},
 {"dispatchId":"dlead","state":"ready","liveness":"live","terminal":"term_rlead","workspace":"repo1::/remote/host/orca/workspaces/repo1/wt-live"}]}}
JSON
"$here/worker-pane-close.sh" dremote >/dev/null 2>&1
check "remote: Setup terminal on another host closes" "$(term_absent term_rsetup; echo $?)"
check "remote: plain Terminal 1 on another host closes" "$(term_absent term_rplain; echo $?)"
check "remote: caller's own terminal kept" "$(listed term_coordinator && ! grep -qx term_coordinator "$tmp/closes.log"; echo $?)"
check "remote: lead terminal kept" "$(listed term_rlead; echo $?)"
check "remote: running worker terminal kept" "$(listed term_rrunning; echo $?)"
check "remote: main branch terminal kept" "$(listed term_rmain; echo $?)"
rm -f "$tmp/workers.json"

# #515 correction: protect by identity. Every Run's coordinator stays open whichever Run owns it, a lead with no live
# dispatch included; another Run's settled leftovers still close; an unreadable Run list closes nothing.
rm -f "$tmp/closes.log" "$tmp/rpc.log" "$tmp/workers.json" "$tmp/runs.json" "$tmp/runs-next.json" "$tmp/state/released/dother"
for f in "$tmp"/state/*; do [ ! -f "$f" ] || rm -f "$f"; done
owt=/remote/host/orca/workspaces/repo1/wt-other
flat_show dother succeeded released exited term_oagent "$owt"
reset_other() {
  cat > "$tmp/terminals.json" <<JSON
{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["local","host2"],"omittedHostIds":[]},"terminals":[
 {"handle":"term_oagent","worktreeId":"repo1::$owt","worktreePath":"$owt","branch":"refs/heads/mingster/wt-other","executionHostId":"host2"},
 {"handle":"term_osetup","title":"Setup","worktreeId":"repo1::$owt","worktreePath":"$owt","branch":"refs/heads/mingster/wt-other","executionHostId":"host2"},
 {"handle":"term_olead","worktreeId":"repo1::$owt","worktreePath":"$owt","branch":"refs/heads/mingster/wt-other","executionHostId":"host2"},
 {"handle":"term_ocoord2","worktreeId":"repo1::$owt","worktreePath":"$owt","branch":"refs/heads/mingster/wt-other","executionHostId":"host2"}]}}
JSON
}
cat > "$tmp/runs.json" <<'JSON'
{"ok":true,"result":{"runs":[{"id":"run_a","coordinator_handle":"term_coordinator"},{"id":"run_b","coordinator_handle":"term_olead"}],"nextCursor":"next"}}
JSON
cat > "$tmp/runs-next.json" <<'JSON'
{"ok":true,"result":{"runs":[{"id":"run_c","coordinator_handle":"term_ocoord2"}]}}
JSON
reset_other
"$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "runs: lead with no live dispatch stays open" "$(listed term_olead; echo $?)"
check "runs: another Run's coordinator (second page) stays open" "$(listed term_ocoord2; echo $?)"
check "runs: another Run's settled leftovers close" "$(term_absent term_osetup; echo $?)"
rm -f "$tmp/closes.log"; reset_other
FAKE_RUNLIST_FAILS=1 "$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "runs: failed run-list closes nothing" "$(no_generic_close; echo $?)"
rm -f "$tmp/closes.log"; reset_other
flat_show dlive ready input_accepted live term_olive "$owt"
printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"dlive","state":"ready","liveness":"live","terminal":"term_olive","workspace":"repo1::'"$owt"'"}]}}' > "$tmp/workers.json"
"$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "runs: a live dispatch in the same worktree keeps its shells" "$(listed term_osetup; echo $?)"
# Current Orca worker-list: top level nextCursor, no page object, and only the caller's Run without --run.
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"warnings":[]}}' > "$tmp/workers.json"
rm -f "$tmp/closes.log"; reset_other
flat_show dlive ready input_accepted live term_olive "$owt"
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"warnings":[]}}' > "$tmp/workers-run_a.json"
printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"dlive","state":"ready","liveness":"live","terminal":"term_olive","workspace":"repo1::'"$owt"'"}],"scope":{"source":"flag"},"warnings":[]}}' > "$tmp/workers-run_c.json"
"$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "worker-list: a live dispatch in another Run keeps its shells" "$(listed term_osetup; echo $?)"
rm -f "$tmp/workers-run_c.json" "$tmp/closes.log"; reset_other
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"nextCursor":"next","warnings":[]}}' > "$tmp/workers-run_a.json"
printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"dlive","state":"ready","liveness":"live","terminal":"term_olive","workspace":"repo1::'"$owt"'"}],"scope":{"source":"flag"},"warnings":[]}}' > "$tmp/workers-run_a-next.json"
"$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "worker-list: a live dispatch on page two (nextCursor) keeps its shells" "$(listed term_osetup; echo $?)"
rm -f "$tmp/closes.log"; reset_other
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"nextCursor":"next","warnings":[]}}' > "$tmp/workers-run_a-next.json"
"$here/worker-pane-close.sh" dother >/dev/null 2>&1
check "worker-list: a repeated cursor closes nothing" "$(no_generic_close; echo $?)"
rm -f "$tmp/workers-run_a.json" "$tmp/workers-run_a-next.json" "$tmp/workers-run_c.json"
rm -f "$tmp/workers.json" "$tmp/runs.json" "$tmp/runs-next.json"

# Unpushed commits: a local worktree ahead of its upstream keeps its shell terminals.
rm -f "$tmp/closes.log"; for f in "$tmp"/state/*; do [ ! -f "$f" ] || rm -f "$f"; done
gr="$tmp/gitfix"; mkdir -p "$gr"
( cd "$gr" && git init -q --bare up.git && git clone -q up.git wt 2>/dev/null && cd wt && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m a && git push -q origin HEAD 2>/dev/null && git commit -q --allow-empty -m unpushed )
( cd "$gr/wt" && git worktree add -q ../wt2 -b feat 2>/dev/null; git -C ../wt2 push -q -u origin feat 2>/dev/null; git -C ../wt2 commit -q --allow-empty -m local )
flat_show dunp succeeded released exited term_uagent "$gr/wt2"
cat > "$tmp/terminals.json" <<JSON
{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"terminals":[
 {"handle":"term_uagent","worktreePath":"$gr/wt2"},{"handle":"term_ushell","worktreePath":"$gr/wt2"}]}}
JSON
FAKE_REAL_RELEASE=1 "$here/worker-pane-close.sh" dunp >/dev/null 2>&1
check "unpushed: shell terminal in a worktree with unpushed commits kept" "$(listed term_ushell; echo $?)"

# Sweep cost and safety (issue 571). A second fake orca that counts every call. Sweep reads each list once, not per dispatch.
cat > "$tmp/orca2" <<'FAKE2'
#!/usr/bin/env bash
echo "$*" >> "$F2/calls.log"
case "$*" in
  "orchestration run-list"*) cat "$F2/runs.json" ;;
  "orchestration worker-list"*)
    r=$(printf '%s' "$*" | sed -n 's/.*--run \([^ ]*\).*/\1/p')
    wl_cursor=$(printf '%s' "$*" | sed -n 's/.*--cursor \([^ ]*\).*/\1/p')
    if [ -n "$wl_cursor" ]; then
      [ -n "${F2_WORKER_LIST_FAIL_PAGE2:-}" ] && exit 1
      [ -n "${F2_WORKER_LIST_PAGE2_JUNK:-}" ] && printf 'not json\n' && exit 0
      [ -n "${F2_WORKER_LIST_PAGE2_FALSE:-}" ] && printf '{"ok":false}\n' && exit 0
      if [ -f "$F2/workers-$r-$wl_cursor.json" ]; then cat "$F2/workers-$r-$wl_cursor.json"
      elif [ -f "$F2/workers-$r-next.json" ]; then cat "$F2/workers-$r-next.json"
      else exit 1; fi
    else
      [ -n "${F2_WORKER_LIST_FAIL:-}" ] && exit 1
      [ -n "${F2_WORKER_LIST_PAGE1_JUNK:-}" ] && printf 'not json\n' && exit 0
      if [ -f "$F2/flip-after-first" ] && [ -f "$F2/flipped" ] && [ -f "$F2/workers-$r.live.json" ]; then cat "$F2/workers-$r.live.json"
      else cat "$F2/workers-$r.json"; [ ! -f "$F2/flip-after-first" ] || : > "$F2/flipped"; fi
    fi ;;
  "orchestration worker-show --dispatch "*)
    [ -z "${F2_SHOW_DELAY:-}" ] || sleep "$F2_SHOW_DELAY"
    [ -f "$F2/show.$4" ] && cat "$F2/show.$4" || exit 1 ;;
  "orchestration worker-release"*) printf '{"ok":true,"result":{"state":"released","dispatchId":"%s","processAction":"closed_agent_terminal"}}\n' "$4" ;;
  "terminal list"*) cat "$F2/terminals.json" ;;
  "terminal close --terminal "*) echo "$4" >> "$F2/closes.log"
    python3 - "$F2/terminals.json" "$4" <<'RM'
import json,sys
p,h=sys.argv[1:]; r=json.load(open(p)); r['result']['terminals']=[t for t in r['result']['terminals'] if t['handle']!=h]; json.dump(r,open(p,'w'))
RM
    ;;
  *) exit 1 ;;
esac
FAKE2
chmod +x "$tmp/orca2"
# scale RUNS PER_RUN: RUNS runs of PER_RUN settled dispatches each, every one with a recorded pane whose terminal is already gone.
scale() {
  export F2="$tmp/scale.$1.$2"; rm -rf "$F2"; mkdir -p "$F2/state"
  python3 - "$F2" "$1" "$2" <<'GEN'
import json,sys
d,runs,per=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
json.dump({"ok":True,"result":{"runs":[{"id":f"run{i}","coordinator_handle":f"coord{i}"} for i in range(runs)]}},open(d+"/runs.json","w"))
for i in range(runs):
    ws=[]
    for j in range(per):
        n=f"d{i}_{j}"; ws.append({"dispatchId":n,"state":"succeeded","workspace":"repo1::/nonexistent/gone"})
        json.dump({"result":{"state":"succeeded","workspace":"repo1::/nonexistent/gone"}},open(f"{d}/show.{n}","w"))
        open(f"{d}/state/{n}","w").write(f"t_{n}\n")
    json.dump({"ok":True,"result":{"workers":ws}},open(f"{d}/workers-run{i}.json","w"))
json.dump({"ok":True,"result":{"truncated":False,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}},open(d+"/terminals.json","w"))
GEN
  ( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
  wc -l < "$F2/calls.log" | tr -d ' '
}
c_3_10=$(scale 3 10); c_3_40=$(scale 3 40); c_6_20=$(scale 6 7); c_3_20=$(scale 3 14)
echo "sweep calls: 3 runs x 10 = $c_3_10, 3 runs x 40 = $c_3_40, 6 runs x 7 = $c_6_20, 3 runs x 14 = $c_3_20 (42 dispatches both)"
check "sweep: calls grow by at most 5 per dispatch" "$([ $((c_3_40 - c_3_10)) -le $((5 * 90)) ]; echo $?)"
check "sweep: same dispatch count over more Runs costs at most 8 more calls" "$([ $((c_6_20 - c_3_20)) -le 8 ]; echo $?)"
check "sweep: every pane file with all handles gone is removed" "$([ -z "$(ls "$tmp/scale.3.40/state")" ]; echo $?)"
# A terminal that a dispatch starts using after the sweep read its lists is not closed.
F2="$tmp/live"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"dold","state":"succeeded","workspace":"repo1::/nonexistent/gone"}]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"dold","state":"succeeded","workspace":"repo1::/nonexistent/gone"},{"dispatchId":"dnew","state":"running","terminal":"t_shared","workspace":"repo1::/elsewhere"}]}}' > "$F2/workers-run0.live.json"
echo '{"result":{"state":"succeeded","workspace":"repo1::/nonexistent/gone"}}' > "$F2/show.dold"
echo t_shared > "$F2/state/dold"; : > "$F2/flip-after-first"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[{"handle":"t_shared","worktreePath":"/elsewhere"}]}}' > "$F2/terminals.json"
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "sweep: terminal a dispatch took after the read is not closed" "$([ ! -s "$F2/closes.log" ]; echo $?)"
check "sweep: its record stays" "$([ -e "$F2/state/dold" ]; echo $?)"
# Pane files that can never close: unknown dispatch with every handle gone goes; one with a listed handle stays.
F2="$tmp/junk"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
echo '{"ok":true,"result":{"workers":[]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[{"handle":"t_alive","worktreePath":"/x"}]}}' > "$F2/terminals.json"
echo t_gone > "$F2/state/null"; echo t_gone > "$F2/state/unknown1"; echo t_alive > "$F2/state/unknown2"
printf 't_gone\nt_alive\n' > "$F2/state/partial"
echo t_gone > "$F2/state/running1"; echo '{"result":{"state":"running"}}' > "$F2/show.running1"
echo '{"ok":false,"error":{"code":"dispatch_not_found"}}' > "$F2/show.unknown1"
echo t_gone > "$F2/state/showfail"; echo t_gone > "$F2/state/showjunk"; echo 'not json' > "$F2/show.showjunk"
echo t_gone > "$F2/state/othererr"; echo '{"ok":false,"error":{"code":"runtime_unavailable"}}' > "$F2/show.othererr"
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "sweep: file of a dispatch Orca says does not exist, every handle gone, is removed" "$([ ! -e "$F2/state/unknown1" ]; echo $?)"
check "sweep: a failed worker-show keeps the record" "$([ -e "$F2/state/showfail" ]; echo $?)"
check "sweep: an unreadable worker-show answer keeps the record" "$([ -e "$F2/state/showjunk" ]; echo $?)"
check "sweep: any other error answer keeps the record" "$([ -e "$F2/state/othererr" ]; echo $?)"
check "sweep: file of a running dispatch keeps its record even with every handle gone" "$([ -e "$F2/state/running1" ]; echo $?)"
check "sweep: file with a handle still listed stays" "$([ -e "$F2/state/unknown2" ] && [ -e "$F2/state/partial" ]; echo $?)"
# An unreadable terminal list proves nothing: no file is removed.
echo t_gone > "$F2/state/again"; echo 'not json' > "$F2/terminals.json"
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "sweep: unreadable terminal list removes nothing" "$([ -e "$F2/state/again" ]; echo $?)"
unset F2

# #597: records of workers that are long gone send no release; an already released worker is never released again.
F2="$tmp/dead"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
python3 - "$F2" <<'GEN'
import json,sys
d=sys.argv[1]; ws=[]; terms=[]
for j in range(30):
    n=f"dead{j}"; ws.append({"dispatchId":n,"state":"released","stage":"released","workspace":"repo1::/nonexistent/gone"})
    json.dump({"result":{"state":"released","stage":"released","workspace":"repo1::/nonexistent/gone","terminal":f"t_{n}"}},open(f"{d}/show.{n}","w"))
    open(f"{d}/state/{n}","w").write(f"t_{n}\n")
json.dump({"ok":True,"result":{"workers":ws}},open(d+"/workers-run0.json","w"))
json.dump({"ok":True,"result":{"truncated":False,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":terms}},open(d+"/terminals.json","w"))
GEN
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "#597 many released records: 0 worker-release calls" "$([ "$(grep -c worker-release "$F2/calls.log")" = 0 ]; echo $?)"
check "#597 their records are pruned" "$([ -z "$(ls "$F2/state")" ]; echo $?)"
# A host that does not answer keeps its records.
F2="$tmp/dead-host"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"dh","state":"released","stage":"released","workspace":"repo1::/nonexistent/gone"}]}}' > "$F2/workers-run0.json"
echo '{"result":{"state":"released","stage":"released","workspace":"repo1::/nonexistent/gone"}}' > "$F2/show.dh"
echo t_remote > "$F2/state/dh"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":["other-host"]},"terminals":[]}}' > "$F2/terminals.json"
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "#597 a host that does not answer keeps its records" "$([ -e "$F2/state/dh" ]; echo $?)"
unset F2

# The pane file is replaced through a temp file and rename, so a reader never sees it empty or half written.
check "pane file is written through a temp file and rename" "$(grep -q 'mv -f' "$here/worker-pane-close.sh" && ! grep -q '> "$f"$' "$here/worker-pane-close.sh"; echo $?)"

# Sweep stops at ORCA_PANE_CLOSE_TIMEOUT, keeps records, exits 0, prints how many are left.
F2="$tmp/sweep-deadline"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
python3 - "$F2" <<'GEN'
import json,sys
d=sys.argv[1]
ws=[]
terms=[]
for j in range(25):
    n=f"slow{j}"
    ws.append({"dispatchId":n,"state":"succeeded","workspace":"repo1::/nonexistent/gone","terminal":f"term_{n}"})
    terms.append({"handle":f"term_{n}"})
    json.dump({"result":{"state":"succeeded","workspace":"repo1::/nonexistent/gone","terminal":f"term_{n}"}},open(f"{d}/show.{n}","w"))
    open(f"{d}/state/{n}","w").write(f"term_{n}\n")
json.dump({"ok":True,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}},open(d+"/runs.json","w"))
json.dump({"ok":True,"result":{"workers":ws}},open(d+"/workers-run0.json","w"))
json.dump({"ok":True,"result":{"truncated":False,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":terms}},open(d+"/terminals.json","w"))
GEN
# worker-show delay exceeds the sweep budget so the deadline path is deterministic under load.
out=$(F2_SHOW_DELAY=3 ORCA_PANE_CLOSE_TIMEOUT=2 ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" 2>&1); rc=$?
left=0
for f in "$F2/state"/*; do [ -f "$f" ] || continue; left=$((left + 1)); done
reported=$(printf '%s' "$out" | sed -n 's/^sweep: deadline reached, \([0-9][0-9]*\) pane record(s) left$/\1/p')
check "sweep: stops before deadline without a non-zero exit" "$([ "$rc" = 0 ] && [ "$left" -gt 0 ]; echo $?)"
check "sweep: prints how many pane records are left" "$([ -n "$reported" ] && [ "$reported" = "$left" ]; echo $?)"
unset F2_SHOW_DELAY

# Prune stale pane files from worker-list rows, not one worker-show per file.
F2="$tmp/sweep-rows"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"endedrow","state":"succeeded","liveness":"exited","workspace":"repo1::/x"},{"dispatchId":"live","state":"running","workspace":"repo1::/y"}]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[{"handle":"t_still","worktreePath":"/x"}]}}' > "$F2/terminals.json"
echo t_gone > "$F2/state/endedrow"
echo t_still > "$F2/state/live"
: > "$F2/calls.log"
( ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1 )
check "sweep: stale-file prune uses worker-list without worker-show for listed dispatches" "$([ ! -e "$F2/state/endedrow" ] && [ -e "$F2/state/live" ] && ! grep -q 'worker-show --dispatch endedrow' "$F2/calls.log" 2>/dev/null; echo $?)"
unset F2

# Failed worker-list read: incomplete inventory must not drop pane state (live Orca shape: scope, workers, optional nextCursor).
F2="$tmp/list-fail"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
echo '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"warnings":[]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
echo t_gone > "$F2/state/listfail"
echo '{"ok":true,"result":{"state":"succeeded","liveness":"exited","terminalState":"released"}}' > "$F2/show.listfail"
F2_WORKER_LIST_FAIL=1 ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1
check "sweep: worker-list exit 1 on first page keeps pane record despite ended worker-show" "$([ -e "$F2/state/listfail" ]; echo $?)"
unset F2_WORKER_LIST_FAIL

F2="$tmp/list-page2"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"nextCursor":"page2","warnings":[]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"page2only","state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo1::/gone"}],"scope":{"source":"flag"},"warnings":[]}}' > "$F2/workers-run0-next.json"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
echo t_gone > "$F2/state/page2only"
F2_WORKER_LIST_FAIL_PAGE2=1 ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1
check "sweep: worker-list exit 1 on page after nextCursor keeps absent dispatch record" "$([ -e "$F2/state/page2only" ]; echo $?)"
unset F2_WORKER_LIST_FAIL_PAGE2

F2="$tmp/list-page2-show"; export F2; rm -rf "$F2"; mkdir -p "$F2/state"
echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
printf '%s\n' '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"nextCursor":"page2","warnings":[]}}' > "$F2/workers-run0.json"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
echo t_gone > "$F2/state/noshow"
: > "$F2/calls.log"
F2_WORKER_LIST_FAIL_PAGE2=1 ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" "$here/worker-pane-close.sh" >/dev/null 2>&1
check "sweep: incomplete list and worker-show exit 1 keeps pane record" "$([ -e "$F2/state/noshow" ]; echo $?)"
unset F2

# Deletion gate: one rm site, logging via ORCA_PANE_RM_LOG (synthetic ids only).
gate_rm() { [ -s "$1/rm.log" ] && grep -c '^rm ' "$1/rm.log" | tr -d ' ' || echo 0; }
gate_setup() {
  export F2="$1"
  rm -rf "$F2"
  mkdir -p "$F2/state"
  echo '{"ok":true,"result":{"runs":[{"id":"run0","coordinator_handle":"coord0"}]}}' > "$F2/runs.json"
  echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
  : > "$F2/rm.log"
}
gate_sweep() {
  ORCA_PANE_RM_LOG="$F2/rm.log" ORCA_CLI_COMMAND="$tmp/orca2" ORCA_PANE_STATE_DIR="$F2/state" \
    "$here/worker-pane-close.sh" >/dev/null 2>&1
}
gate_p1_final() {
  printf '%s\n' '{"ok":true,"result":{"workers":[{"dispatchId":"'"$1"'","state":"succeeded","liveness":"exited","terminalState":"released","workspace":"repo1::/gone"}],"scope":{"source":"flag"},"nextCursor":"p2","warnings":[]}}' > "$F2/workers-run0.json"
  echo t_gone > "$F2/state/$1"
}

F2="$tmp/gate-p2exit"; gate_setup "$F2"
gate_p1_final p2exit
F2_WORKER_LIST_FAIL_PAGE2=1 gate_sweep
check "deletion gate: final on page 1 and page 2 exit 1 keeps record" "$([ -e "$F2/state/p2exit" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2_WORKER_LIST_FAIL_PAGE2

F2="$tmp/gate-p2junk"; gate_setup "$F2"
gate_p1_final p2junk
F2_WORKER_LIST_PAGE2_JUNK=1 gate_sweep
check "deletion gate: final on page 1 and page 2 non-JSON keeps record" "$([ -e "$F2/state/p2junk" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2_WORKER_LIST_PAGE2_JUNK

F2="$tmp/gate-p2false"; gate_setup "$F2"
gate_p1_final p2false
F2_WORKER_LIST_PAGE2_FALSE=1 gate_sweep
check "deletion gate: final on page 1 and page 2 ok false keeps record" "$([ -e "$F2/state/p2false" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2_WORKER_LIST_PAGE2_FALSE

F2="$tmp/gate-p1exit"; gate_setup "$F2"
echo t_gone > "$F2/state/p1exit"
F2_WORKER_LIST_FAIL=1 gate_sweep
check "deletion gate: worker-list exit 1 on page 1 keeps record" "$([ -e "$F2/state/p1exit" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2_WORKER_LIST_FAIL

F2="$tmp/gate-p1junk"; gate_setup "$F2"
echo t_gone > "$F2/state/p1junk"
F2_WORKER_LIST_PAGE1_JUNK=1 gate_sweep
check "deletion gate: worker-list non-JSON on page 1 keeps record" "$([ -e "$F2/state/p1junk" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2_WORKER_LIST_PAGE1_JUNK

F2="$tmp/gate-show"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"},"warnings":[]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/showexit"
echo t_gone > "$F2/state/showjunk"
echo t_gone > "$F2/state/shownone"
echo 'not json' > "$F2/show.showjunk"
echo '{"ok":true}' > "$F2/show.shownone"
gate_sweep
check "deletion gate: worker-show exit 1 keeps record" "$([ -e "$F2/state/showexit" ]; echo $?)"
check "deletion gate: worker-show non-JSON keeps record" "$([ -e "$F2/state/showjunk" ]; echo $?)"
check "deletion gate: worker-show ok with no result keeps record" "$([ -e "$F2/state/shownone" ]; echo $?)"
check "deletion gate: failed worker-show emits no rm log" "$([ "$(gate_rm "$F2")" = 0 ]; echo $?)"

F2="$tmp/gate-unread"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"unread","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/unread"
chmod 000 "$F2/state/unread"
gate_sweep
check "deletion gate: unreadable state file on sweep keeps record" "$([ -e "$F2/state/unread" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
chmod 644 "$F2/state/unread" 2>/dev/null || true

flat_show unread2 succeeded released exited term_x "$tmp/gone"
echo t_gone > "$tmp/state/unread2"
chmod 000 "$tmp/state/unread2"
ORCA_PANE_RM_LOG="$tmp/unread2-rm.log" : > "$tmp/unread2-rm.log"
echo '{"ok":true,"result":{"terminals":[],"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]}}}' > "$tmp/terminals.json"
FAKE_APPEND_COORDINATOR=0 "$here/worker-pane-close.sh" unread2 >/dev/null 2>&1
check "deletion gate: unreadable state file on explicit id keeps record" "$([ -e "$tmp/state/unread2" ] && [ ! -s "$tmp/unread2-rm.log" ]; echo $?)"
chmod 644 "$tmp/state/unread2" 2>/dev/null || true

F2="$tmp/gate-remove"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"goneok","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/goneok"
gate_sweep
check "deletion gate: complete list final row handles gone removes record" "$([ ! -e "$F2/state/goneok" ] && [ "$(gate_rm "$F2")" -gt 0 ]; echo $?)"

F2="$tmp/gate-close"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"closeme","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo '{"result":{"state":"succeeded","workspace":"repo1::/gone"}}' > "$F2/show.closeme"
echo t_close > "$F2/state/closeme"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[{"handle":"t_close"}]}}' > "$F2/terminals.json"
gate_sweep
check "deletion gate: listed handle is closed before record removal" "$(grep -qx t_close "$F2/closes.log" && [ ! -e "$F2/state/closeme" ] && [ "$(gate_rm "$F2")" -gt 0 ]; echo $?)"

F2="$tmp/gate-running"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"stillrun","state":"running","workspace":"repo1::/y"}]}}' > "$F2/workers-run0.json"
echo t_live > "$F2/state/stillrun"
gate_sweep
check "deletion gate: running worker-list row keeps record" "$([ -e "$F2/state/stillrun" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2

F2="$tmp/gate-hostblank"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"hostblank","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/hostblank"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":[""],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
gate_sweep
check "deletion gate: sweep blank hostId keeps record" "$([ -e "$F2/state/hostblank" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2

F2="$tmp/gate-missok"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"missok","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/missok"
echo '{"result":{"truncated":false,"hostScope":{"hostIds":["h"],"omittedHostIds":[]},"terminals":[]}}' > "$F2/terminals.json"
gate_sweep
check "deletion gate: sweep missing ok keeps record" "$([ -e "$F2/state/missok" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2

F2="$tmp/gate-missomit"; gate_setup "$F2"
echo '{"ok":true,"result":{"workers":[{"dispatchId":"missomit","state":"succeeded","liveness":"exited","workspace":"repo1::/gone"}]}}' > "$F2/workers-run0.json"
echo t_gone > "$F2/state/missomit"
echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["h"]},"terminals":[]}}' > "$F2/terminals.json"
gate_sweep
check "deletion gate: sweep missing omitted keeps record" "$([ -e "$F2/state/missomit" ] && [ "$(gate_rm "$F2")" = 0 ]; echo $?)"
unset F2

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
