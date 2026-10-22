#!/usr/bin/env bash
# Tests for on-worker-done.sh --dry-run with a stub usage gate. bash 3.2 compatible.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/gate" <<'GATE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_DIR/gate.log"
[ "${GATE_RC:-0}" = 0 ] || exit "$GATE_RC"
echo "${GATE_OUT:---agent cursor --model gpt-5.6-sol-high}"
GATE
chmod +x "$tmp/gate"
export FAKE_DIR="$tmp" ON_WORKER_DONE_USAGE_GATE="$tmp/gate"
head=0123456789abcdef0123456789abcdef01234567
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
run() { "$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 --head "$head" --author-family "${1:-claude}" --worktree /wt --run run_1 2>"$tmp/err"; }

out=$(run); rc=$?
check "gate ok: exit 0" "$rc"
check "gate ok: non-claude family" "$(echo "$out" | grep -q -- '--agent cursor'; echo $?)"
check "gate ok: no fallback note" "$(! grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"
check "reviewer task title for pane color" "$(echo "$out" | grep -q -- '--task-title "reviewer - PR 42"'; echo $?)"
check "gate asked to avoid the author family" "$(grep -q -- 'pick --role reviewer --avoid-family claude' "$tmp/gate.log"; echo $?)"

out=$(GATE_RC=3 run); rc=$?
check "gate blocked: exit 0" "$rc"
check "gate blocked: claude opus high" "$(echo "$out" | grep -q -- '--agent claude --model opus --effort high'; echo $?)"
check "gate blocked: prints cross-family unavailable" "$(grep -q 'cross-family unavailable' "$tmp/err"; echo $?)"

out=$(GATE_RC=4 run)
check "gate error also falls back" "$(echo "$out" | grep -q -- '--agent claude --model opus'; echo $?)"

run cursor >/dev/null
check "cursor author avoids gpt" "$(grep -q -- '--avoid-family gpt' "$tmp/gate.log"; echo $?)"

"$here/on-worker-done.sh" --dry-run --repo o/n --pr 42 >/dev/null 2>&1
check "missing args exit nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr x --head "$head" --author-family claude --worktree /wt --run r >/dev/null 2>&1
check "bad pr exits nonzero" "$([ $? -ne 0 ]; echo $?)"
"$here/on-worker-done.sh" --dry-run --repo o/n --pr 1 --head "$head" --author-family gpt --worktree /wt --run r >/dev/null 2>&1
check "bad family exits nonzero" "$([ $? -ne 0 ]; echo $?)"

run >/dev/null
brief=$(ls -t "${TMPDIR:-/tmp}"/reviewer-brief.* | head -1)
re='^Verdict: PASS\|PASS\+NOTES\|FAIL head=[0-9a-f]{40} verifier=<your dispatch id> author=unknown$'
check "brief has the verdict line template with the head" "$(grep -E "$re" "$brief" | grep -q "head=$head"; echo $?)"
rm -f "$brief"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
