#!/usr/bin/env bash
# Tests for worker-watch.sh using a fake `orca` on PATH.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
# FAKE_DIR holds workers.json and <handle>.txt (one screen line per line).
case "$*" in
  "orchestration worker-list"*) cat "$FAKE_DIR/workers.json" ;;
  "terminal read"*)
    h=$(echo "$*" | sed -E 's/.*--terminal ([^ ]+).*/\1/')
    python3 -c '
import json, sys
print(json.dumps({"ok": True, "result": {"terminal": {"tail": open(sys.argv[1]).read().splitlines()}}}))
' "$FAKE_DIR/$h.txt" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp"

pass=0; fail=0
check() { # name expected_exit output_regex
  out=$("$here/worker-watch.sh" run_x 2>&1); code=$?
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1 (exit $code)"; echo "$out"; fi
}
workers() { # id:handle:outcome ...
  python3 -c '
import json, sys
ws = []
for a in sys.argv[1:]:
    d, h, o = a.split(":")
    ws.append({"dispatchId": d, "agentTerminalHandle": h, "projection": {"outcome": o}})
print(json.dumps({"ok": True, "result": {"workers": ws}}))
' "$@" > "$tmp/workers.json"
}

workers ctx_a:term_a:in_progress
printf 'Working on spec\nrunning tests --limit 40\nconst limit = 5\n' > "$tmp/term_a.txt"
check "all OK, bare word limit not flagged" 0 'ctx_a term_a OK'

printf 'Individual quota reached. Resets in 4h51m\n' > "$tmp/term_a.txt"
check "antigravity quota" 4 'ctx_a term_a STOPPED .*quota'

printf 'You have hit your weekly limit (1% left)\n' > "$tmp/term_a.txt"
check "codex weekly limit" 4 'ctx_a term_a STOPPED .*weekly limit'

printf 'Error: spendLimitHit: true\n' > "$tmp/term_a.txt"
check "cursor spendLimitHit" 4 'ctx_a term_a STOPPED .*spendLimitHit'

printf 'Working\nctx: 79%%\n' > "$tmp/term_a.txt"
check "ctx 79 is OK" 0 'ctx_a term_a OK'

printf 'Working\nopus | ctx: 80%%\n' > "$tmp/term_a.txt"
check "ctx 80 LOW_CONTEXT" 4 'ctx_a term_a LOW_CONTEXT .*80%'

printf 'Working\nContext limit reached. Run /compact to continue\n' > "$tmp/term_a.txt"
check "context limit STOPPED" 4 'ctx_a term_a STOPPED .*Context limit'

printf 'Claude usage limit reached. Your limit will reset at 5pm\n' > "$tmp/term_a.txt"
check "claude usage limit" 4 'ctx_a term_a STOPPED .*usage limit'

printf 'ok\n⚠ Individual quota reached\nmore\nlines\nbelow\nthis\nnotice\nhere\nand\nmore\nstuff\n' > "$tmp/term_a.txt"
check "notice marker above the tail" 4 'ctx_a term_a STOPPED .*quota'

# A diff of worker-watch.sh itself: every phrase sits inside a code line.
cat > "$tmp/term_a.txt" <<'SRC'
+    r"Individual quota reached|\bResets in \d|weekly limit.*% left"
+    r"|spendLimitHit: true|usage limit reached|limit will reset|Context limit reached"
  12 | grep -iE 'quota|usage limit|spendLimitHit' "$screen"
  13 | echo "Individual quota reached. Resets in 4h"
pattern='Context limit reached|weekly limit (1% left)'
printf 'Individual quota reached\n' > term.txt
Reading worker-watch.sh
SRC
check "own source on screen not flagged" 0 'ctx_a term_a OK'

workers ctx_a:term_a:succeeded ctx_b:term_b:in_progress
printf 'Working\n' > "$tmp/term_b.txt"
out=$("$here/worker-watch.sh" run_x); code=$?
if [ "$code" = 0 ] && ! echo "$out" | grep -q ctx_a && echo "$out" | grep -q 'ctx_b term_b OK'; then pass=$((pass+1)); echo "ok   settled skipped"; else fail=$((fail+1)); echo "FAIL settled skipped"; echo "$out"; fi

"$here/worker-watch.sh" >/dev/null 2>&1; [ $? = 2 ] && { pass=$((pass+1)); echo "ok   usage exit 2"; } || { fail=$((fail+1)); echo "FAIL usage exit 2"; }

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
