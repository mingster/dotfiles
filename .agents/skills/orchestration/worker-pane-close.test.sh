#!/usr/bin/env bash
# Tests for worker-pane-close.sh and the state file worker-panes.sh writes, with a fake orca (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-show --dispatch "*) d=$4
    if [ -f "$FAKE_DIR/show.$d" ]; then cat "$FAKE_DIR/show.$d"; else s=$(cat "$FAKE_DIR/status.$d" 2>/dev/null); printf '{"result":{"dispatch":{"status":"%s"}}}' "$s"; fi ;;
  "terminal close --terminal "*) echo "$4" >> "$FAKE_DIR/closes.log" ;;
  "terminal list"*) if [ -f "$FAKE_DIR/terminals.json" ]; then cat "$FAKE_DIR/terminals.json"; else echo '{"result":{"terminals":[]}}'; fi ;;
  "terminal split"*) echo '{"result":{"terminal":{"handle":"term_new"}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp" ORCA_PANE_STATE_DIR="$tmp/state"
mkdir -p "$tmp/state"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
closes() { [ -f "$tmp/closes.log" ] && wc -l < "$tmp/closes.log" | tr -d ' ' || echo 0; }

"$here/worker-panes.sh" run_x term_base dnew >/dev/null 2>&1
check "worker-panes records the pane handle" "$([ "$(cat "$tmp/state/dnew" 2>/dev/null)" = term_new ]; echo $?)"
rm "$tmp/state/dnew"

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
echo completed > "$tmp/status.d2"; echo running > "$tmp/status.d3"; echo dispatched > "$tmp/status.d4"
"$here/worker-pane-close.sh" >/dev/null
check "no args closes the ended dispatch" "$(grep -qx term_b "$tmp/closes.log"; echo $?)"
check "no args keeps running and dispatched" "$([ -e "$tmp/state/d3" ] && [ -e "$tmp/state/d4" ] && ! grep -qE 'term_(c|d)' "$tmp/closes.log"; echo $?)"
"$here/worker-pane-close.sh" >/dev/null
check "no args re-run is a no-op" "$([ "$(closes)" = 2 ]; echo $?)"

# Leftover terminals: a validated worker leaves its agent and setup terminals, a shell in its worktree and
# maybe a pane whose split timed out. Close the ones still listed, never the owner's or other projects'.
rm -f "$tmp/closes.log"
cat > "$tmp/show.d6" <<'JSON'
{"result":{"dispatch":{"status":"released","assigneeHandle":"term_agent"},
 "worker":{"agentTerminalHandle":"term_agent","effects":[
  {"kind":"worktree","action":"created_child","id":"wt1::/wt/d6"},
  {"kind":"terminal","role":"agent","action":"created","id":"term_agent"},
  {"kind":"terminal","role":"setup","action":"created","id":"term_setup"},
  {"kind":"terminal","role":"setup","action":"created","id":"term_gone"}]}}}
JSON
cat > "$tmp/terminals.json" <<'JSON'
{"result":{"terminals":[
 {"handle":"term_agent","worktreePath":"/wt/d6"},{"handle":"term_setup","worktreePath":"/wt/d6"},
 {"handle":"term_shell","worktreePath":"/wt/d6"},{"handle":"term_owner","worktreePath":"/proj"},
 {"handle":"term_wt_prefix","worktreePath":"/wt/d6-other"}]}}
JSON
"$here/worker-pane-close.sh" d6 >/dev/null
check "leftover: closes the agent terminal" "$(grep -qx term_agent "$tmp/closes.log"; echo $?)"
check "leftover: closes the setup terminal" "$(grep -qx term_setup "$tmp/closes.log"; echo $?)"
check "leftover: closes a shell whose cwd is the worker worktree" "$(grep -qx term_shell "$tmp/closes.log"; echo $?)"
check "leftover: skips a handle orca terminal list no longer shows" "$(! grep -qx term_gone "$tmp/closes.log"; echo $?)"
check "leftover: leaves the owner's and other worktrees' terminals" "$(! grep -qE 'term_owner|term_wt_prefix' "$tmp/closes.log"; echo $?)"
check "leftover: each terminal closed once" "$([ "$(sort "$tmp/closes.log" | uniq -d | wc -l | tr -d ' ')" = 0 ]; echo $?)"

# A pane recorded in the state file is closed once even when it is also in the listing.
rm -f "$tmp/closes.log"; echo term_shell > "$tmp/state/d6"
"$here/worker-pane-close.sh" d6 >/dev/null
check "leftover: recorded pane is closed once" "$([ "$(grep -cx term_shell "$tmp/closes.log")" = 1 ] && [ ! -e "$tmp/state/d6" ]; echo $?)"

# Still-active dispatch: never close its terminals.
rm -f "$tmp/closes.log"; sed 's/"released"/"running"/' "$tmp/show.d6" > "$tmp/show.d7"
"$here/worker-pane-close.sh" d7 >/dev/null
check "active dispatch: no terminal is closed" "$([ ! -e "$tmp/closes.log" ]; echo $?)"

# A worker running in the owner's checkout (no created worktree) is matched by handle only, never by cwd.
rm -f "$tmp/closes.log"
cat > "$tmp/show.d8" <<'JSON'
{"result":{"dispatch":{"status":"failed"},"worker":{"agentTerminalHandle":"term_agent","effects":[
  {"kind":"worktree","action":"reused","id":"wt0::/proj"},
  {"kind":"terminal","role":"agent","action":"created","id":"term_agent"}]}}}
JSON
"$here/worker-pane-close.sh" d8 >/dev/null
check "current worktree: closes only the worker's own terminal" "$([ "$(cat "$tmp/closes.log")" = term_agent ]; echo $?)"

# The recorded pane file may list several handles (one per line); all are closed.
rm -f "$tmp/closes.log" "$tmp/show.d9"; printf 'term_p1\nterm_p2\n' > "$tmp/state/d9"
"$here/worker-pane-close.sh" d9 >/dev/null
check "multi-line state file closes every handle" "$(grep -qx term_p1 "$tmp/closes.log" && grep -qx term_p2 "$tmp/closes.log"; echo $?)"

echo term_e > "$tmp/state/d5"; echo released > "$tmp/status.d5"
sed -i.bak 's/terminal close --terminal/terminal closeX --terminal/' "$tmp/orca" && rm "$tmp/orca.bak"
"$here/worker-pane-close.sh" d5 >/dev/null; rc=$?
check "already-closed pane (close fails) is not an error" "$([ "$rc" = 0 ] && [ ! -e "$tmp/state/d5" ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
