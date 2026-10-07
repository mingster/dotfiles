#!/usr/bin/env bash
# Tests for worker-pane-close.sh and the state file worker-panes.sh writes, with a fake orca (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-show --dispatch "*) d=$4; s=$(cat "$FAKE_DIR/status.$d" 2>/dev/null); printf '{"result":{"dispatch":{"status":"%s"}}}' "$s" ;;
  "terminal close --terminal "*) echo "$4" >> "$FAKE_DIR/closes.log" ;;
  "terminal list"*) echo '{"result":{"terminals":[]}}' ;;
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

echo term_e > "$tmp/state/d5"; echo released > "$tmp/status.d5"
sed -i.bak 's/terminal close --terminal/terminal closeX --terminal/' "$tmp/orca" && rm "$tmp/orca.bak"
"$here/worker-pane-close.sh" d5 >/dev/null; rc=$?
check "already-closed pane (close fails) is not an error" "$([ "$rc" = 0 ] && [ ! -e "$tmp/state/d5" ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
