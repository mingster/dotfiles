#!/usr/bin/env bash
# Tests for worker-watch.sh using a fake `orca` on PATH.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
# FAKE_DIR holds workers.json, terminals.json and <handle>.txt (one screen line per line).
case "$*" in
  "orchestration worker-list"*)
    if [[ "$*" == *"--cursor page2"* ]]; then
      cat "$FAKE_DIR/workers-page2.json"
    else
      cat "$FAKE_DIR/workers.json"
    fi ;;
  "terminal list"*) cat "$FAKE_DIR/terminals.json" ;;
  "terminal read"*)
    echo "$*" >> "$FAKE_DIR/terminal-reads.log"
    if [[ "$*" == *"--environment down"* ]]; then
      exit 1
    fi
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
cat > "$tmp/terminals.json" <<EOF
{"ok":true,"result":{"terminals":[{"handle":"term_a","worktreePath":"$tmp/lead-queue"}]}}
EOF
mkdir -p "$tmp/sessions/2026/10/18"
python3 - "$tmp/sessions/2026/10/18/lead.jsonl" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session_meta','payload':{'cwd':__import__('os').environ['FAKE_DIR']+'/lead-queue'}})+'\n')
    for _ in range(10): f.write(json.dumps({'type':'event_msg','payload':{'type':'token_count'}})+'\n')
PY
export CODEX_SESSIONS_DIR="$tmp/sessions"

workers ctx_a:term_a:in_progress
export FAKE_CALLS=10
printf 'Working on spec\nrunning tests --limit 40\nconst limit = 5\n' > "$tmp/term_a.txt"
check "all OK, bare word limit not flagged" 0 'ctx_a term_a OK'
python3 - "$tmp/sessions/2026/10/18/lead.jsonl" <<'PY2'
import json,sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session_meta','payload':{'cwd':__import__('os').environ['FAKE_DIR']+'/lead-queue'}})+'\n')
    for _ in range(200): f.write(json.dumps({'type':'event_msg','payload':{'type':'token_count'}})+'\n')
PY2
check "Codex LONG_SESSION stops named dispatch at 200 calls" 4 'ctx_a term_a LONG_SESSION 200 calls; end dispatch'
python3 - "$tmp/sessions/2026/10/18/lead.jsonl" <<'PY3'
import json,sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session_meta','payload':{'cwd':__import__('os').environ['FAKE_DIR']+'/lead-queue'}})+'\n')
    for _ in range(10): f.write(json.dumps({'type':'event_msg','payload':{'type':'token_count'}})+'\n')
PY3

# Restarts must not reset the count: a second session of the same worktree adds to the first.
python3 - "$tmp/sessions/2026/10/18/lead2.jsonl" <<'PY4'
import json,sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session_meta','payload':{'cwd':__import__('os').environ['FAKE_DIR']+'/lead-queue'}})+'\n')
    for _ in range(115): f.write(json.dumps({'type':'event_msg','payload':{'type':'token_count'}})+'\n')
PY4
printf 'Working on spec\n' > "$tmp/term_a.txt"
check "calls are summed across sessions of one worktree (10 + 115)" 4 'ctx_a term_a LONG_SESSION 125 calls$'
python3 - "$tmp/sessions/2026/10/18/lead2.jsonl" <<'PY5'
import json,sys
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session_meta','payload':{'cwd':__import__('os').environ['FAKE_DIR']+'/lead-queue'}})+'\n')
    f.write(json.dumps({'type':'turn_context','payload':{'model':'gpt-6-astra'}})+'\n')
PY5
check "gpt-6-astra session is flagged ASTRA_MODEL" 4 'ctx_a term_a ASTRA_MODEL'
rm "$tmp/sessions/2026/10/18/lead2.jsonl"

cat > "$tmp/term_a.txt" <<'SCREEN'
  assertions) and initiated the Playwright regression test suite. I am waiting for the test execution to complete.
────────────────────────────────────────
>

SCREEN
export FAKE_CALLS=10
check "antigravity ended turn at empty prompt" 4 'ctx_a term_a IDLE'

cat > "$tmp/term_a.txt" <<'SCREEN'
⚠ There was a network issue connecting to the server, please try again.
Error ID: 95836a72-example
────────────────────────────────────────
>
SCREEN
check "antigravity network error at empty prompt" 4 'ctx_a term_a STOPPED .*network issue'

for prompt in '>' '›' '❯'; do
  printf 'Completed the current turn.\n────────────────────\n%s\n' "$prompt" > "$tmp/term_a.txt"
  check "empty provider prompt $prompt" 4 'ctx_a term_a IDLE'
  for busy in '⠋ Executing tests' 'Running tests' 'Thinking' '• Working (esc to interrupt)'; do
    printf '%s\n────────────────────\n%s\n' "$busy" "$prompt" > "$tmp/term_a.txt"
    check "busy screen $busy with prompt $prompt" 0 'ctx_a term_a OK'
  done
done

printf '> Continue with the tests\n' > "$tmp/term_a.txt"
check "nonempty input is not idle" 0 'ctx_a term_a OK'

cat > "$tmp/term_a.txt" <<'SRC'
+⚠ There was a network issue connecting to the server, please try again.
  12 | ⚠ There was a network issue connecting to the server, please try again.
echo "⚠ There was a network issue connecting to the server, please try again."
SRC
check "network error in source and diff not flagged" 0 'ctx_a term_a OK'

printf 'Individual quota reached. Resets in 4h51m\n' > "$tmp/term_a.txt"
check "antigravity quota" 4 'ctx_a term_a STOPPED .*quota'

printf 'You have hit your weekly limit (1%% left)\n' > "$tmp/term_a.txt"
check "codex weekly limit" 4 'ctx_a term_a STOPPED .*weekly limit'

printf '• Working (3m 21s • esc to interrupt)\n   ⚠ weekly limit: 25%% left · resets at 1:03 PM on 20 Oct · /status\n' > "$tmp/term_a.txt"
check "codex weekly warning while working not flagged" 0 'ctx_a term_a OK'

printf '■ Selected model is at capacity. Please try a different model.\n' > "$tmp/term_a.txt"
check "codex model at capacity" 4 'ctx_a term_a STOPPED .*capacity'

printf 'Error: spendLimitHit: true\n' > "$tmp/term_a.txt"
check "cursor spendLimitHit" 4 'ctx_a term_a STOPPED .*spendLimitHit'

printf 'Switch to a different model or set a Spend Limit\n' > "$tmp/term_a.txt"
check "cursor Claude allowance spent" 4 'ctx_a term_a STOPPED .*Spend Limit'

printf "You've hit your usage limit\nSwitch to a cheaper model\n" > "$tmp/term_a.txt"
check "cursor usage limit" 4 'ctx_a term_a STOPPED .*usage limit'

printf 'Workspace Trust Required\nDo you trust the contents of this directory?\n[a] Trust this workspace\n[q] Quit\n' > "$tmp/term_a.txt"
check "cursor trust dialog" 4 'ctx_a term_a BLOCKED_DIALOG .*Trust Required'

printf 'Bash command\n  rm -rf /tmp/x\nDo you want to proceed?\n> 1. Yes\n  2. No\n' > "$tmp/term_a.txt"
check "pending tool approval" 4 'ctx_a term_a BLOCKED_APPROVAL .*Do you want to proceed'

printf 'grep "Do you want to proceed?" notes.md\nWorking\n' > "$tmp/term_a.txt"
check "approval text in a command is not a prompt" 0 'ctx_a term_a OK'

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

"$here/worker-watch.sh" >/dev/null 2>&1
if [ $? = 2 ]; then pass=$((pass+1)); echo "ok   usage exit 2"
else fail=$((fail+1)); echo "FAIL usage exit 2"; fi

# Page two coverage
cat > "$tmp/workers.json" <<EOF
{"ok":true,"result":{"workers":[{"dispatchId":"ctx_p1","agentTerminalHandle":"term_p1","projection":{"outcome":"in_progress"}}],"page":{"hasMore":true,"nextCursor":"page2"}}}
EOF
cat > "$tmp/workers-page2.json" <<EOF
{"ok":true,"result":{"workers":[{"dispatchId":"ctx_p2","agentTerminalHandle":"term_p2","projection":{"outcome":"in_progress"}}],"page":{"hasMore":false}}}
EOF
printf 'Working on page 1\n' > "$tmp/term_p1.txt"
printf 'Working on page 2\n' > "$tmp/term_p2.txt"
check "page two dispatches are paginated and observed" 0 'ctx_p2 term_p2 OK'

# Remote-only coverage preserving endpoint/environment
: > "$tmp/terminal-reads.log"
cat > "$tmp/workers.json" <<EOF
{"ok":true,"result":{"workers":[{"dispatchId":"ctx_rem","agentTerminalHandle":"term_rem","projection":{"outcome":"in_progress","host":{"kind":"remote","id":"remote-env","connected":true}}}],"page":{"hasMore":false}}}
EOF
printf 'Remote worker active\n' > "$tmp/term_rem.txt"
check "remote-only dispatches read terminal with environment" 0 'ctx_rem term_rem OK'
if grep -q -- '--environment remote-env.*--terminal term_rem' "$tmp/terminal-reads.log"; then
  pass=$((pass+1)); echo "ok   remote terminal read preserves issuing server environment"
else
  fail=$((fail+1)); echo "FAIL remote terminal read did not pass issuing server environment"
fi

# Disconnected host coverage
cat > "$tmp/workers.json" <<EOF
{"ok":true,"result":{"workers":[{"dispatchId":"ctx_disc","agentTerminalHandle":"term_disc","projection":{"outcome":"in_progress","host":{"kind":"remote","id":"remote-down","connected":false}}}],"page":{"hasMore":false}}}
EOF
check "disconnected host produces unknown coverage, never healthy" 4 'ctx_disc term_disc UNKNOWN_COVERAGE'

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
