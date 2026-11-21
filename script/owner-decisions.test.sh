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
# gh issue view <n> -R <repo> --json body,comments. Issues 90 to 99 without a fixture are "could not resolve".
echo "$3" >>"$FIX/asked"
f="$FIX/$3.json"
[ -f "$f" ] && cat "$f" && exit 0
case "$3" in 9[0-9]) echo "GraphQL: Could not resolve to an issue or pull request with the number of $3." >&2 ;; *) echo "connection reset" >&2 ;; esac
exit 1
STUB
chmod +x "$tmp/bin/gh"
export FIX="$tmp" PATH="$tmp/bin:$PATH" OWNER_ASKS_LOG="$tmp/asks.md"
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

run o/r 199
[ "$rc" -eq 2 ] && grep -q 'cannot read #199' <<<"$se" && ok "gh failure exits 2, not 1" || bad ghfail "rc=$rc se=$se"

echo '{"body":"Blocked by #198.","comments":[]}' >"$tmp/5.json"
run o/r 5
[ "$rc" -eq 2 ] && grep -q 'cannot read #198' <<<"$se" && ok "failing linked issue read exits 2, not 1" || bad linkedfail "rc=$rc se=$se"

echo '{"body":"See #98.","comments":[{"body":"Owner decision: own wins."}]}' >"$tmp/6.json"
run o/r 6
[ "$rc" -eq 0 ] && grep -q '^#6: Owner decision: own wins' <<<"$so" && ok "dead ref does not drop the own decision" || bad deadown "rc=$rc so=$so se=$se"

echo '{"body":"See #97 and #4.","comments":[]}' >"$tmp/7.json"
run o/r 7
[ "$rc" -eq 0 ] && grep -q '^#4: Owner decision: skip it' <<<"$so" && ok "dead ref first does not hide a later linked decision" || bad deadfirst "rc=$rc so=$so se=$se"

echo '{"body":"See #198.","comments":[]}' >"$tmp/8.json"
run o/r 8
[ "$rc" -eq 2 ] && ok "non resolve linked failure with no decision exits 2" || bad transient "rc=$rc"

echo '{"body":"Cross repo other/repo#98 and url x/y#97.","comments":[]}' >"$tmp/9.json"
: >"$tmp/asked"
run o/r 9
[ "$rc" -eq 1 ] && ! grep -qE '^9[78]$' "$tmp/asked" && ok "owner/repo#N is not read as a local issue" || bad crossrepo "rc=$rc asked=$(tr '\n' ' ' <"$tmp/asked")"

printf 'asked #12 about X, owner said use B\nasked #123 other\n' >"$tmp/asks.md"
echo '{"body":"Question.","comments":[]}' >"$tmp/12.json"
run o/r 12
[ "$rc" -eq 0 ] && grep -q '^asks log: asked #12 ' <<<"$so" && ! grep -q '#123' <<<"$so" && ok "owner asks log line for the issue counts" || bad askslog "rc=$rc so=$so"
echo '{"body":"Question.","comments":[]}' >"$tmp/13.json"
run o/r 13
[ "$rc" -eq 1 ] && ok "asks log without the issue number exits 1" || bad askslognone "rc=$rc so=$so"
rm -f "$tmp/asks.md"

run o/r
[ "$rc" -eq 2 ] && ok "missing argument exits 2" || bad usage "rc=$rc"
run o/r abc
[ "$rc" -eq 2 ] && ok "non numeric issue exits 2" || bad numeric "rc=$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
