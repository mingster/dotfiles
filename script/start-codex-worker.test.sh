#!/usr/bin/env bash
# Tests for start-codex-worker.sh with a fake orca (no live Orca). bash 3.2 compatible.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/calls.log"
case "$*" in
  "worktree create"*) echo '{"ok":true,"result":{"worktree":{"path":"/wt/new"}}}' ;;
  "terminal create"*) echo '{"ok":true,"result":{"terminal":{"handle":"term_x"}}}' ;;
  "terminal read"*) echo "{\"result\":{\"screen\":\"${FAKE_SCREEN:-Ask Codex  ready}\"}}" ;;
  "terminal send"*) echo '{"ok":true}' ;;
  "terminal rename"*) echo '{"ok":true}' ;;
  "orchestration worker-start"*) echo "{\"ok\":true,\"result\":{\"dispatchId\":\"ctx_1\",\"state\":\"${FAKE_STATE:-ready}\"}}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/orca"
export ORCA_CLI_COMMAND="$tmp/orca" FAKE_DIR="$tmp" START_CODEX_POLL=0 ORCA_TERMINAL_HANDLE=term_coord
echo "spec text" > "$tmp/spec.txt"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

out=$("$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title "dev - job" --worktree-path /wt/existing 2>&1); rc=$?
check "existing worktree: exit 0 and prints dispatch, terminal, state" "$([ $rc = 0 ] && [ "$out" = "ctx_1 term_x ready" ]; echo $?)"
check "no worktree create for an existing worktree" "$(! grep -q '^worktree create' "$tmp/calls.log"; echo $?)"
check "terminal opens codex with model and effort" "$(grep -q 'terminal create.*codex -m gpt-6.1-sol -c model_reasoning_effort=medium' "$tmp/calls.log"; echo $?)"
check "warm-up line is sent before worker-start" "$([ "$(grep -n 'Say ready' "$tmp/calls.log" | cut -d: -f1)" -lt "$(grep -n 'worker-start' "$tmp/calls.log" | cut -d: -f1)" ]; echo $?)"
check "heavy plugins are disabled on the codex command" "$(grep 'terminal create' "$tmp/calls.log" | grep -q 'plugins."documents@openai-primary-runtime".enabled=false'; echo $?)"
check "worker-start uses the terminal and worktree path" "$(grep 'worker-start' "$tmp/calls.log" | grep -q -- '--terminal term_x --worktree path:/wt/existing'; echo $?)"

: > "$tmp/calls.log"
out=$("$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title "dev - job" --name lane --repo /r --base-branch origin/main --model gpt-6.1-sol --effort low 2>&1); rc=$?
check "new worktree: exit 0" "$([ $rc = 0 ]; echo $?)"
check "new worktree path read from result.worktree.path" "$(grep -q 'worker-start.*--worktree path:/wt/new' "$tmp/calls.log"; echo $?)"
check "model and effort flags pass through" "$(grep -q 'codex -m gpt-6.1-sol -c model_reasoning_effort=low' "$tmp/calls.log"; echo $?)"

FAKE_STATE=failed "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e >/dev/null 2>&1
check "non-running state exits 1" "$([ $? = 1 ]; echo $?)"

"$here/start-codex-worker.sh" --run run_1 >/dev/null 2>&1
check "missing args exit 2" "$([ $? = 2 ]; echo $?)"

: > "$tmp/calls.log"
FAKE_SCREEN='GPT-6.1-Sol low · ~/x' "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e >/dev/null 2>&1
check "0.163 footer (GPT-n) counts as ready without waiting" "$([ "$(grep -c '^terminal read' "$tmp/calls.log")" -le 91 ]; echo $?)"

check "worker-start passes the coordinator handle as --from" "$(grep 'worker-start' "$tmp/calls.log" | grep -q -- '--from term_coord'; echo $?)"

: > "$tmp/calls.log"
out=$("$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --from orca_session_id:elon 2>&1)
check "--from overrides ORCA_TERMINAL_HANDLE" "$(grep 'worker-start' "$tmp/calls.log" | grep -q -- '--from orca_session_id:elon'; echo $?)"

: > "$tmp/calls.log"
ORCA_TERMINAL_HANDLE= "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --name lane --repo /r >/dev/null 2>&1; rc=$?
check "no handle: exit 2 before any worktree or terminal" "$([ $rc = 2 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"

: > "$tmp/calls.log"
"$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --model gpt-6-astra >/dev/null 2>&1; rc=$?
check "gpt-6-astra without OWNER_ASTRA_YES: exit 3 before any orca call" "$([ $rc = 3 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"
OWNER_ASTRA_YES="owner 2026-10-22 issue 1" "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --model gpt-6-astra >/dev/null 2>&1; rc=$?
check "gpt-6-astra with OWNER_ASTRA_YES starts the worker" "$([ $rc = 0 ] && grep -q 'codex -m gpt-6-astra' "$tmp/calls.log"; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
