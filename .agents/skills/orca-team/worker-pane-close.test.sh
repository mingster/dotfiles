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
    if [ -f "$FAKE_DIR/release.$d.json" ]; then cat "$FAKE_DIR/release.$d.json"; exit "${FAKE_RELEASE_EXIT:-0}"; fi
    printf '{"ok":true,"result":{"state":"released","dispatchId":"'"$d"'","processAction":"closed_agent_terminal"}}\n' ;;
  "orchestration worker-list --cursor next"*) cat "$FAKE_DIR/workers-next.json" ;;
  "orchestration worker-list"*) cat "$FAKE_DIR/workers.json" 2>/dev/null || echo '{"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  "terminal list"*) [ "${FAKE_LIST_FAILS:-0}" = 0 ] || exit 1; python3 - "$FAKE_DIR/terminals.json" <<'LIST'
import json,sys,os
try: r=json.load(open(sys.argv[1]))
except Exception: r={"result":{"terminals":[]}}
r['result']['terminals'].append({'handle':'term_coordinator','worktreePath':os.getcwd(),'worktreeId':'repo1::'+os.getcwd()})
print(json.dumps(r))
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
check "split cleanup closes the worker pane and terminals" "$(grep -qx term_pane "$tmp/closes.log" && grep -qx term_worker "$tmp/closes.log" && grep -qx term_setup "$tmp/closes.log"; echo $?)"
rm -f "$tmp/split.json" "$tmp/split-after.json" "$tmp/show.anchor_case" "$tmp/terminals.json" "$tmp/closes.log" "$tmp/state/anchor_case"

echo completed > "$tmp/status.d1"
echo term_a > "$tmp/state/d1"; echo term_b > "$tmp/state/d2"
"$here/worker-pane-close.sh" d1 >/dev/null
check "close by id closes that pane" "$(grep -qx term_a "$tmp/closes.log"; echo $?)"
check "close by id deletes its state file" "$([ ! -e "$tmp/state/d1" ]; echo $?)"
check "close by id leaves other panes" "$([ -e "$tmp/state/d2" ] && [ "$(closes)" = 1 ]; echo $?)"

"$here/worker-pane-close.sh" d1 >/dev/null; rc=$?
check "re-running close is a no-op" "$([ "$rc" = 0 ] && [ "$(closes)" = 1 ]; echo $?)"
"$here/worker-pane-close.sh" nope >/dev/null
check "unknown dispatch is not an error" "$([ "$(closes)" = 1 ]; echo $?)"

echo term_c > "$tmp/state/d3"; echo term_d > "$tmp/state/d4"
cat > "$tmp/show.d2" <<JSON
{"result":{"dispatch":{"status":"completed"},"worker":{"effects":[{"kind":"worktree","action":"created_child","id":"wt1::$tmp/gone"}]}}}
JSON
echo completed > "$tmp/status.d2"; echo running > "$tmp/status.d3"; echo dispatched > "$tmp/status.d4"
"$here/worker-pane-close.sh" >/dev/null
check "no args closes the ended dispatch" "$(grep -qx term_b "$tmp/closes.log"; echo $?)"
check "no args keeps running and dispatched" "$([ -e "$tmp/state/d3" ] && [ -e "$tmp/state/d4" ] && ! grep -qE 'term_(c|d)' "$tmp/closes.log"; echo $?)"
"$here/worker-pane-close.sh" >/dev/null
check "no args re-run is a no-op" "$([ "$(closes)" = 2 ]; echo $?)"

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
check "explicit id still closes a settled dispatch whose worktree exists" "$(grep -qx term_live "$tmp/closes.log"; echo $?)"
# Restore the live record for the marker cases.
echo term_live > "$tmp/state/dlive"; rm -f "$tmp/closes.log"
echo '{"result":{"terminals":[{"handle":"term_live","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
# A --release marker lets the sweep close a released worker whose worktree still exists (Orca retains external terminals).
mkdir -p "$tmp/state/released"; : > "$tmp/state/released/dlive"
"$here/worker-pane-close.sh" >/dev/null
check "sweep closes a released dispatch whose worktree still exists" "$(grep -qx term_live "$tmp/closes.log" && [ ! -e "$tmp/state/dlive" ] && [ ! -e "$tmp/state/released/dlive" ]; echo $?)"
rm -f "$tmp/closes.log"
echo term_rel > "$tmp/state/drel"
printf '{"result":{"dispatch":{"status":"completed"},"worker":{"effects":[{"kind":"worktree","action":"created_child","id":"wt1::%s/linked"}]}}}' "$tmp" > "$tmp/show.drel"
echo '{"result":{"terminals":[{"handle":"term_rel","worktreePath":"'"$tmp"'/linked"}]}}' > "$tmp/terminals.json"
"$here/worker-pane-close.sh" --release drel >/dev/null
check "--release releases, closes and clears its marker" "$(grep -q 'worker-release --dispatch drel' "$tmp/rpc.log" && grep -qx term_rel "$tmp/closes.log" && [ ! -e "$tmp/state/released/drel" ]; echo $?)"
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
check "leftover: closes the agent terminal" "$(grep -qx term_agent "$tmp/closes.log"; echo $?)"
check "leftover: closes the setup terminal" "$(grep -qx term_setup "$tmp/closes.log"; echo $?)"
check "leftover: closes a shell whose cwd is the worker worktree" "$(grep -qx term_shell "$tmp/closes.log"; echo $?)"
check "leftover: skips a handle orca terminal list no longer shows" "$(! grep -qx term_gone "$tmp/closes.log"; echo $?)"
check "leftover: leaves the owner's and other worktrees' terminals" "$(! grep -qE 'term_owner|term_wt_prefix' "$tmp/closes.log"; echo $?)"
check "leftover: each terminal closed once" "$([ "$(sort "$tmp/closes.log" | uniq -d | wc -l | tr -d ' ')" = 0 ]; echo $?)"

# Reusing a linked worktree still owns its leftover shell terminals.
rm -f "$tmp/closes.log"
sed 's/"created_child"/"reused"/' "$tmp/show.d6" > "$tmp/show.reused"
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_shell_one","worktreePath":"$tmp/linked"},{"handle":"term_shell_two","worktreePath":"$tmp/linked"}]}}
JSON
"$here/worker-pane-close.sh" reused >/dev/null
check "reused worktree: closes both leftover shells" "$(grep -qx term_shell_one "$tmp/closes.log" && grep -qx term_shell_two "$tmp/closes.log"; echo $?)"

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
  check "$source fallback: closes leftover shell" "$(grep -qx term_fallback_shell "$tmp/closes.log"; echo $?)"
done

# A pane recorded in the state file is closed once even when it is also in the listing.
cat > "$tmp/terminals.json" <<JSON
{"result":{"terminals":[{"handle":"term_shell","worktreePath":"$tmp/linked"}]}}
JSON
rm -f "$tmp/closes.log"; echo term_shell > "$tmp/state/d6"
"$here/worker-pane-close.sh" d6 >/dev/null
check "leftover: recorded pane is closed once" "$([ "$(grep -cx term_shell "$tmp/closes.log")" = 1 ] && [ ! -e "$tmp/state/d6" ]; echo $?)"

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
check "current worktree: closes only the worker's own terminal" "$([ "$(cat "$tmp/closes.log")" = term_agent ]; echo $?)"

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
check "no args: shared terminal of a live retry is not closed" "$([ ! -s "$tmp/closes.log" ]; echo $?)"
echo '{"result":{"workers":[{"dispatchId":"dfail","dispatchStatus":"failed","agentTerminalHandle":"term_shared"},{"dispatchId":"dretry","dispatchStatus":"completed","agentTerminalHandle":"term_shared"}],"page":{"hasMore":false}}}' > "$tmp/workers.json"
"$here/worker-pane-close.sh" dfail >/dev/null
check "retry ended too: terminal is closed" "$(grep -qx term_shared "$tmp/closes.log"; echo $?)"
rm -f "$tmp/workers.json" "$tmp/show.dfail"

# The recorded pane file may list several handles (one per line); all are closed.
rm -f "$tmp/closes.log" "$tmp/show.d9"; printf 'term_p1\nterm_p2\n' > "$tmp/state/d9"
echo completed > "$tmp/status.d9"
"$here/worker-pane-close.sh" d9 >/dev/null
check "multi-line state file closes every handle" "$(grep -qx term_p1 "$tmp/closes.log" && grep -qx term_p2 "$tmp/closes.log"; echo $?)"

# A failed close and three accepted-but-still-listed closes need five attempts.
rm -f "$tmp/closes.log"
echo completed > "$tmp/status.retry"; echo term_retry > "$tmp/state/retry"
echo '{"result":{"terminals":[{"handle":"term_retry"}]}}' > "$tmp/terminals.json"
: > "$tmp/sleeps.log"
FAKE_FAILS=1 FAKE_LINGERS=4 "$here/worker-pane-close.sh" retry >/dev/null
check "one close attempt retains record when terminal lingers" "$([ "$(closes)" = 1 ] && [ -e "$tmp/state/retry" ]; echo $?)"
check "no retry backoff sleep after single-shot close" "$([ ! -s "$tmp/sleeps.log" ]; echo $?)"
# If authority changes while retrying, stop closing and retain the handle.
rm -f "$tmp/closes.log"
echo completed > "$tmp/status.reactivate"; echo term_retry > "$tmp/state/reactivate"
echo '{"result":{"terminals":[{"handle":"term_retry"}]}}' > "$tmp/terminals.json"
FAKE_REACTIVATE=reactivate FAKE_FAILS=100 "$here/worker-pane-close.sh" reactivate >/dev/null
check "dispatch becoming running stops retries" "$([ "$(closes)" = 1 ] && [ -e "$tmp/state/reactivate" ]; echo $?)"
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
check "wake sweep discovers unrecorded leftover terminals on later pages" "$(grep -qx term_agent "$tmp/closes.log"; echo $?)"
check "wake sweep excludes ended dispatches from other projects" "$(! grep -qx term_other "$tmp/closes.log"; echo $?)"
check "wake sweep leaves coordinator terminal" "$(! grep -qx term_coordinator "$tmp/closes.log"; echo $?)"
rm "$tmp/workers.json"
# Budget expiry retains the record for a later wake sweep.
echo completed > "$tmp/status.stuck"; echo term_stuck > "$tmp/state/stuck"
echo '{"result":{"terminals":[{"handle":"term_stuck"}]}}' > "$tmp/terminals.json"
ORCA_PANE_CLOSE_TIMEOUT=0 FAKE_FAILS=100 "$here/worker-pane-close.sh" stuck >/dev/null
check "unverified close retains record" "$([ -e "$tmp/state/stuck" ]; echo $?)"
ORCA_PANE_CLOSE_TIMEOUT=0 FAKE_LIST_FAILS=1 "$here/worker-pane-close.sh" stuck >/dev/null
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
sed -i.bak 's/terminal close --terminal/terminal closeX --terminal/' "$tmp/orca" && rm "$tmp/orca.bak"
"$here/worker-pane-close.sh" d5 >/dev/null; rc=$?
check "already-closed pane (close fails) is not an error" "$([ "$rc" = 0 ] && [ ! -e "$tmp/state/d5" ]; echo $?)"

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
check "wrong dispatch id on --release refuses close" "$([ "$rc" != 0 ] && [ ! -s "$tmp/closes.log" ] && [ ! -e "$tmp/state/released/dwrong" ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
