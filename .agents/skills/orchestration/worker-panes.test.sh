#!/usr/bin/env bash
# Tests for worker-panes.sh using a fake orca script (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-list"*) cat "$FAKE_DIR/workers.json" ;;
  "terminal list"*) cat "$FAKE_DIR/terminals.json" ;;
  "terminal split"*) echo "$*" >> "$FAKE_DIR/splits.log"; n=$(wc -l < "$FAKE_DIR/splits.log" | tr -d ' '); echo "{\"result\":{\"terminal\":{\"handle\":\"pane_$n\"}}}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp" ORCA_PANE_STATE_DIR="$tmp/state"
cat > "$tmp/workers.json" <<'JSON'
{"result":{"workers":[
 {"dispatchId":"d1","dispatchStatus":"running"},
 {"dispatchId":"d2","dispatchStatus":"completed"},
 {"dispatchId":"d3","dispatchStatus":"dispatched"}]}}
JSON

cat > "$tmp/terminals.json" <<'JSON'
{"result":{"terminals":[{"handle":"term_base","tabId":"t1"},{"handle":"term_other","tabId":"t2"}]}}
JSON

pass=0; fail=0
check() { # name condition_exit
  if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi
}

reset() { rm -rf "$tmp/splits.log" "$tmp/state"; }
terms() { # live handles in the coordinator's tab
  local j=""; for h in "$@"; do j="$j{\"handle\":\"$h\",\"tabId\":\"t1\"},"; done
  echo "{\"result\":{\"terminals\":[$j{\"handle\":\"term_other\",\"tabId\":\"t2\"}]}}" > "$tmp/terminals.json"
}
terms term_base

"$here/worker-panes.sh" run_x term_base >/dev/null 2>&1
check "splits only active workers" "$([ "$(wc -l < "$tmp/splits.log")" -eq 2 ]; echo $?)"
check "first pane splits the coordinator to the right" "$(sed -n 1p "$tmp/splits.log" | grep -q -- '--terminal term_base --direction vertical.*worker-pane.sh d1 --json'; echo $?)"
check "second pane splits the first worker pane below" "$(sed -n 2p "$tmp/splits.log" | grep -q -- '--terminal pane_1 --direction horizontal.*worker-pane.sh d3 --json'; echo $?)"

reset
"$here/worker-panes.sh" run_x term_base d2 >/dev/null 2>&1
check "explicit dispatch id overrides the list" "$(grep -q 'worker-pane.sh d2 --json' "$tmp/splits.log"; echo $?)"

# A later call stacks under the recorded worker pane, never under the coordinator.
reset; mkdir -p "$tmp/state"; echo w1 > "$tmp/state/dold"
terms term_base w1
"$here/worker-panes.sh" run_x term_base d4 >/dev/null 2>&1
check "later call splits the live worker pane below" "$(grep -q -- '--terminal w1 --direction horizontal.*worker-pane.sh d4 --json' "$tmp/splits.log"; echo $?)"

# The recorded pane is gone: back to splitting the coordinator to the right.
reset; mkdir -p "$tmp/state"; echo w_gone > "$tmp/state/dold"
terms term_base
"$here/worker-panes.sh" run_x term_base d5 >/dev/null 2>&1
check "gone worker pane falls back to the coordinator" "$(grep -q -- '--terminal term_base --direction vertical.*worker-pane.sh d5 --json' "$tmp/splits.log"; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
