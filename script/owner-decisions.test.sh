#!/usr/bin/env bash
# Tests for script/owner-decisions.sh. A gh stub serves canned issue JSON from $FIX/<n>.json.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh issue view <n> -R <repo> --json body,comments
f="$FIX/$3.json"
[ -f "$f" ] && cat "$f" || { echo "not found" >&2; exit 1; }
STUB
chmod +x "$tmp/bin/gh"
export FIX="$tmp" PATH="$tmp/bin:$PATH"
run() { bash "$here/owner-decisions.sh" "$@" >"$tmp/so" 2>"$tmp/se"; rc=$?; so=$(cat "$tmp/so"); se=$(cat "$tmp/se"); }

echo '{"body":"Question.","comments":[{"body":"Owner decision: use A."}]}' >"$tmp/1.json"
run o/r 1
[ "$rc" -eq 0 ] && grep -q '^#1: Owner decision: use A' <<<"$so" && ok "answered issue exits 0 and prints the decision" || bad answered "rc=$rc so=$so"

echo '{"body":"Question.","comments":[{"body":"I think we should A."},{"body":"Not an Owner decision: line"}]}' >"$tmp/2.json"
run o/r 2
[ "$rc" -eq 1 ] && [ -z "$so" ] && ok "unanswered issue exits 1 and prints nothing" || bad unanswered "rc=$rc so=$so"

echo '{"body":"Blocked by #4 and itself #3.","comments":[]}' >"$tmp/3.json"
echo '{"body":"","comments":[{"body":"Owner decision: skip it."}]}' >"$tmp/4.json"
run o/r 3
[ "$rc" -eq 0 ] && grep -q '^#4: Owner decision: skip it' <<<"$so" && ok "decision on a linked issue counts" || bad linked "rc=$rc so=$so"

run o/r 99
[ "$rc" -eq 2 ] && grep -q 'cannot read #99' <<<"$se" && ok "gh failure exits 2, not 1" || bad ghfail "rc=$rc se=$se"

echo '{"body":"Blocked by #98.","comments":[]}' >"$tmp/5.json"
run o/r 5
[ "$rc" -eq 2 ] && grep -q 'cannot read #98' <<<"$se" && ok "failing linked issue read exits 2, not 1" || bad linkedfail "rc=$rc se=$se"

run o/r
[ "$rc" -eq 2 ] && ok "missing argument exits 2" || bad usage "rc=$rc"
run o/r abc
[ "$rc" -eq 2 ] && ok "non numeric issue exits 2" || bad numeric "rc=$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
