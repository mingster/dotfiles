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
  "terminal read"*) scr="${FAKE_SCREEN:-Ask Codex  ready}"
    { [ -z "${FAKE_PROMPT:-}" ] || [ -f "$FAKE_DIR/trusted" ]; } || scr=$FAKE_PROMPT
    echo "{\"result\":{\"screen\":\"$scr\"}}" ;;
  "terminal send"*"--text 2 "*"--enter"*) touch "$FAKE_DIR/trusted"; echo '{"ok":true}' ;;
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
"$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --host not-this-host >/dev/null 2>&1
check "remote --host exits 2 before any orca call (it would start on this machine)" "$([ $? = 2 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"

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

: > "$tmp/calls.log"; printf ' \n' > "$tmp/blank.txt"
"$here/start-codex-worker.sh" --run run_1 --spec "$tmp/blank.txt" --title t --worktree-path /wt/e >/dev/null 2>&1; rc=$?
check "blank spec file: exit 2 before any orca call" "$([ $rc = 2 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"

: > "$tmp/calls.log"
"$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --model gpt-6-astra >/dev/null 2>&1; rc=$?
check "gpt-6-astra without OWNER_ASTRA_YES: exit 3 before any orca call" "$([ $rc = 3 ] && [ ! -s "$tmp/calls.log" ]; echo $?)"
OWNER_ASTRA_YES="owner 2026-10-22 issue 1" "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path /wt/e --model gpt-6-astra >/dev/null 2>&1; rc=$?
check "gpt-6-astra with OWNER_ASTRA_YES starts the worker" "$([ $rc = 0 ] && grep -q 'codex -m gpt-6-astra' "$tmp/calls.log"; echo $?)"

# Hooks trust prompt: a real repo whose origin/main holds the hooks file and the script it runs.
repo="$tmp/repo"; git init -q "$repo"; mkdir "$repo/.codex"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .codex/guard.sh"}]}]}}\n' > "$repo/.codex/hooks.json"
printf 'echo guard\n' > "$repo/.codex/guard.sh"
git -C "$repo" add -A; git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
git -C "$repo" update-ref refs/remotes/origin/main HEAD
prompt='Codex\nhooks are new or changed\n  '"$repo"'/.codex/hooks.json\n  1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting'
hooks_run() { rm -f "$tmp/trusted"; : > "$tmp/calls.log"
  FAKE_PROMPT=$1 "$here/start-codex-worker.sh" --run run_1 --spec "$tmp/spec.txt" --title t --worktree-path "$repo" 2>&1; }
sent_choice() { grep -q -- 'terminal send.*--text [0-9] .*--enter' "$tmp/calls.log"; }

out=$(hooks_run "$prompt"); rc=$?
sha=$(shasum -a 256 "$repo/.codex/hooks.json" | cut -d' ' -f1)
check "hooks identical to origin/main: selects Trust all, logs sha256, finishes warm-up" "$([ $rc = 0 ] && grep -q -- 'terminal send.*--text 2 .*--enter' "$tmp/calls.log" && echo "$out" | grep -q "$sha" && [ "$(echo "$out" | tail -1)" = "ctx_1 term_x ready" ]; echo $?)"

echo ' ' >> "$repo/.codex/hooks.json"
out=$(hooks_run "$prompt"); rc=$?
check "changed hooks file: exit 4, nothing selected, diff printed, no worker-start" "$([ $rc = 4 ] && ! sent_choice && ! grep -q worker-start "$tmp/calls.log" && echo "$out" | grep -q '^+++'; echo $?)"
git -C "$repo" checkout -q -- .

echo '# tampered' >> "$repo/.codex/guard.sh"
out=$(hooks_run "$prompt"); rc=$?
check "changed referenced script: exit 4, nothing selected, diff printed" "$([ $rc = 4 ] && ! sent_choice && ! grep -q worker-start "$tmp/calls.log" && echo "$out" | grep -q 'guard.sh'; echo $?)"
git -C "$repo" checkout -q -- .

printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .codex/new.sh"}]}]}}\n' > "$repo/.codex/hooks.json"
echo 'echo new' > "$repo/.codex/new.sh"; git -C "$repo" add -A; git -C "$repo" -c user.name=t -c user.email=t@t commit -qm local
out=$(hooks_run "$prompt"); rc=$?
check "hooks and script both new relative to origin/main: exit 4" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
git -C "$repo" reset -q --hard origin/main

out=$(hooks_run 'Codex\nhooks are new or changed\n  1. Review hooks\n  2. Trust all and continue'); rc=$?
check "prompt without a hooks file path: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
out=$(hooks_run 'Codex\nhooks are new or changed\n  '"$repo"'/.codex/hooks.json\n  Press enter'); rc=$?
check "prompt without a Trust all option: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
out=$(hooks_run 'Codex\nhooks are new or changed\n  '"$tmp"'/other/hooks.json\n  2. Trust all and continue'); rc=$?
check "listed hooks file outside the worktree: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice; echo $?)"

# The real Codex screen lists no paths, only a count.
real='Hooks need review\n2 hooks are new or changed.\nHooks can run outside the sandbox after you trust them.\n\u203a 1. Review hooks\n  2. Trust all and continue\n  3. Continue without trusting (hooks won'"'"'t run)\nenter confirm \u00b7 esc skip'
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash .codex/guard.sh"},{"type":"command","command":"bash .codex/guard.sh x"}]}]}}\n' > "$repo/.codex/hooks.json"
git -C "$repo" add -A; git -C "$repo" -c user.name=t -c user.email=t@t commit -qm two
git -C "$repo" update-ref refs/remotes/origin/main HEAD
out=$(hooks_run "$real"); rc=$?
check "real screen, 2 commands identical to main: selects option 2" "$([ $rc = 0 ] && grep -q -- 'terminal send.*--text 2 .*--enter' "$tmp/calls.log" && [ "$(echo "$out" | tail -1)" = "ctx_1 term_x ready" ]; echo $?)"
echo ' ' >> "$repo/.codex/hooks.json"
out=$(hooks_run "$real"); rc=$?
check "real screen, hooks file differs from main: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
git -C "$repo" checkout -q -- .
out=$(hooks_run "${real/2 hooks/3 hooks}"); rc=$?
check "real screen says 3 hooks, file has 2: exit 4, prints both counts" "$([ $rc = 4 ] && ! sent_choice && echo "$out" | grep -q '3 hooks.*2 commands'; echo $?)"
echo '# tampered' >> "$repo/.codex/guard.sh"
out=$(hooks_run "$real"); rc=$?
check "real screen, referenced script changed: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice && echo "$out" | grep -q 'guard.sh'; echo $?)"
git -C "$repo" checkout -q -- .
out=$(hooks_run "${real/2 hooks/0 hooks}"); rc=$?
check "real screen with 0 hooks: exit 4" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
out=$(hooks_run "${real/2 hooks/many hooks}"); rc=$?
check "real screen with a non-numeric count: exit 4" "$([ $rc = 4 ] && ! sent_choice; echo $?)"
out=$(hooks_run 'garbage hooks are new or changed lorem ipsum'); rc=$?
check "garbage text: exit 4, nothing selected" "$([ $rc = 4 ] && ! sent_choice; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
