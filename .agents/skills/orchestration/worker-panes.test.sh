#!/usr/bin/env bash
# Tests for worker-panes.sh using a fake orca script (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-list"*) cat "$FAKE_DIR/workers.json" ;;
  "terminal split"*) echo "$*" >> "$FAKE_DIR/splits.log"; echo '{"ok":true}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp"
cat > "$tmp/workers.json" <<'JSON'
{"result":{"workers":[
 {"dispatchId":"d1","dispatchStatus":"running"},
 {"dispatchId":"d2","dispatchStatus":"completed"},
 {"dispatchId":"d3","dispatchStatus":"dispatched"}]}}
JSON

pass=0; fail=0
check() { # name condition_exit
  if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi
}

"$here/worker-panes.sh" run_x term_base >/dev/null 2>&1
check "splits only active workers" "$([ "$(wc -l < "$tmp/splits.log")" -eq 2 ]; echo $?)"
check "first split is vertical, color 1" "$(sed -n 1p "$tmp/splits.log" | grep -q 'vertical.*worker-pane.sh d1 1'; echo $?)"
check "second split is horizontal, color 2" "$(sed -n 2p "$tmp/splits.log" | grep -q 'horizontal.*worker-pane.sh d3 2'; echo $?)"

rm "$tmp/splits.log"
"$here/worker-panes.sh" run_x term_base d2 >/dev/null 2>&1
check "explicit dispatch id overrides the list" "$(grep -q 'worker-pane.sh d2 1' "$tmp/splits.log"; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
