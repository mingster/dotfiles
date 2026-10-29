#!/usr/bin/env bash
# Tests for on-worker-done.sh --dry-run with a stub usage gate. bash 3.2 compatible.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/gate" <<'GATE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_DIR/gate.log"
[ "${GATE_RC:-0}" = 0 ] || exit "$GATE_RC"
echo "${GATE_OUT:---agent codex --model gpt-6.1-sol --effort medium}"
GATE
chmod +x "$tmp/gate"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca" <<'ORCA'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/orca.log"
exit 0
ORCA
chmod +x "$tmp/bin/orca"
export FAKE_DIR="$tmp" ON_WORKER_DONE_USAGE_GATE="$tmp/gate" PATH="$tmp/bin:$PATH"
: > "$tmp/orca.log"
head=0123456789abcdef0123456789abcdef01234567
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
run() { "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-family "${1:-claude}" --worktree /wt --run run_1 2>"$tmp/err"; }

out=$(run); rc=$?
check "gate ok: exit 0" "$rc"
check "gate ok: cross-family agent flags" "$(echo "$out" | grep -q -- '--agent codex'; echo $?)"
check "gate ok: no fallback note" "$(! grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"
check "reviewer task title for pane color" "$(echo "$out" | grep -q -- '--task-title "reviewer - PR 42"'; echo $?)"
check "gate asked to avoid the author family" "$(grep -q -- 'pick --role reviewer --avoid-family claude' "$tmp/gate.log"; echo $?)"

out=$(GATE_RC=3 run); rc=$?
check "gate blocked: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "gate blocked: no worker-start line" "$(! echo "$out" | grep -q 'worker-start'; echo $?)"
check "gate blocked: prints cross-family unavailable" "$(grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

GATE_RC=4 run >/dev/null 2>"$tmp/err"; rc=$?
check "gate error: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "gate error: no opus fallback" "$(! grep -q 'opus' "$tmp/err"; echo $?)"

GATE_RC=3 GATE_OUT= run 2>"$tmp/err" >/dev/null; rc=$?
check "live path blocked: exit nonzero" "$([ "$rc" -ne 0 ]; echo $?)"
check "live path blocked: no orca worker-start" "$(! grep -q worker-start "$tmp/orca.log"; echo $?)"

run cursor >/dev/null
check "cursor author avoids gpt" "$(grep -q -- '--avoid-family gpt' "$tmp/gate.log"; echo $?)"
run codex >/dev/null
check "codex author avoids gpt" "$(grep -q -- '--avoid-family gpt' "$tmp/gate.log"; echo $?)"

"$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 >/dev/null 2>&1
check "missing args exit nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr x --head "$head" --author-family claude --worktree /wt --run r >/dev/null 2>&1
check "bad pr exits nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr 1 --head "$head" --author-family gpt --worktree /wt --run r >/dev/null 2>&1
check "bad family exits nonzero" "$([ $? -ne 0 ]; echo $?)"

# Shared family across providers: Antigravity Claude vs Claude reviewer
rc=0
GATE_OUT="--agent claude --model claude-3-5-sonnet" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model claude-3-5-sonnet --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "shared claude family across antigravity and claude rejected" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Shared family across providers: Antigravity GPT vs Codex reviewer
rc=0
GATE_OUT="--agent codex --model gpt-6.1-sol" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model gpt-4o --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "shared gpt family across antigravity and codex rejected" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Unknown author model blocks independence acceptance
rc=0
GATE_OUT="--agent codex --model gpt-6.1-sol" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model unknown-model-x --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "unknown author model blocks independence acceptance" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

# Unknown verifier model blocks independence acceptance
rc=0
GATE_OUT="--agent codex --model mystery-model-v9" \
  "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-provider antigravity --author-model gemini-3.8-flash --worktree /wt --run run_1 >/dev/null 2>"$tmp/err" || rc=$?
check "unknown verifier model blocks independence acceptance" "$([ "$rc" -ne 0 ] && grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

run >/dev/null
brief=$(ls -t "${TMPDIR:-/tmp}"/reviewer-brief.* | head -1)
re='^Verdict: PASS\|PASS\+NOTES\|FAIL head=[0-9a-f]{40} verifier=<your dispatch id> author=unknown$'
check "brief has the verdict line template with the head" "$(grep -E "$re" "$brief" | grep -q "head=$head"; echo $?)"
check "brief records author and verifier families separately from provider" "$(grep -q 'Author: provider=' "$brief" && grep -q 'family=' "$brief" && grep -q 'Verifier: provider=' "$brief"; echo $?)"
rm -f "$brief"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
