#!/usr/bin/env bash
# Tests for worker-pane.sh role colors using a fake orca script (no live Orca needed).
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "orchestration worker-show"*) printf '{"result":{"dispatch":{"assigneeHandle":"-","status":"%s","taskTitle":"%s"}}}' "${FAKE_STATUS:-completed}" "$FAKE_TITLE" ;;
  "terminal close"*) echo "$*" >> "$FAKE_LOG" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
pane() { FAKE_TITLE="$1" "$here/worker-pane.sh" d1 ${2:+"$2"} 2>/dev/null; }

check "secops-finops gets 124" "$(pane 'secops-finops - review PR 1729' | grep -q '48;5;124m'; echo $?)"
check "lead gets 25" "$(pane 'lead - merge PRs' | grep -q '48;5;25m'; echo $?)"
check "tech-lead gets 25" "$(pane 'tech-lead - merge PRs' | grep -q '48;5;25m'; echo $?)"
check "unknown role gets 240" "$(pane 'intern - make coffee' | grep -q '48;5;240m'; echo $?)"
check "no dash in title gets 240" "$(pane 'whatever' | grep -q '48;5;240m'; echo $?)"
check "explicit color overrides role" "$(pane 'secops-finops - x' 5 | grep -q '48;5;5m'; echo $?)"
check "--role-color fullstack-dev is 28" "$([ "$("$here/worker-pane.sh" --role-color 'fullstack-dev - fix')" = 28 ]; echo $?)"
check "--role-color is case insensitive" "$([ "$("$here/worker-pane.sh" --role-color 'Elon - plan')" = 178 ]; echo $?)"

check "ended dispatch prints no hold text" "$(pane 'lead - x' | grep -q 'pane stays'; [ $? = 1 ]; echo $?)"

# Self-close: the pane closes its own terminal once the dispatch has ended.
export ORCA_PANE_CLOSE_DELAY=0 FAKE_LOG="$tmp/close.log"
for st in completed failed cancelled released; do
  : > "$FAKE_LOG"; FAKE_STATUS=$st FAKE_TITLE='lead - x' ORCA_TERMINAL_HANDLE=term_abc "$here/worker-pane.sh" d1 >/dev/null 2>&1
  check "$st dispatch closes own pane with its handle" "$([ "$(cat "$FAKE_LOG")" = "terminal close --terminal term_abc" ]; echo $?)"
done
: > "$FAKE_LOG"; FAKE_STATUS=completed FAKE_TITLE='lead - x' ORCA_TERMINAL_HANDLE= "$here/worker-pane.sh" d1 >/dev/null 2>&1
check "empty ORCA_TERMINAL_HANDLE: no close" "$([ ! -s "$FAKE_LOG" ]; echo $?)"
: > "$FAKE_LOG"; env -u ORCA_TERMINAL_HANDLE FAKE_STATUS=completed FAKE_TITLE='lead - x' "$here/worker-pane.sh" d1 >/dev/null 2>&1
check "unset ORCA_TERMINAL_HANDLE: no close" "$([ ! -s "$FAKE_LOG" ]; echo $?)"
# A running dispatch must never close; a failing worker-show must not end the loop or close.
for mode in running show-fails; do
  : > "$FAKE_LOG"
  if [ $mode = running ]; then FAKE_STATUS=running; else FAKE_STATUS=; fi
  [ $mode = show-fails ] && cp "$tmp/orca" "$tmp/orca.bak" && sed -i.x 's/^  "orchestration worker-show"\*).*$/  "orchestration worker-show"*) exit 1 ;;/' "$tmp/orca"
  ( FAKE_STATUS=$FAKE_STATUS FAKE_TITLE='lead - x' ORCA_TERMINAL_HANDLE=term_abc timeout 7 "$here/worker-pane.sh" d1 >/dev/null 2>&1 ); rc=$?
  [ $mode = show-fails ] && cp "$tmp/orca.bak" "$tmp/orca"
  check "$mode: still running after 7s (timeout 124)" "$([ $rc = 124 ]; echo $?)"
  check "$mode: no close" "$([ ! -s "$FAKE_LOG" ]; echo $?)"
done

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
