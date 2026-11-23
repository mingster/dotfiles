#!/usr/bin/env bash
# check-main-fix.sh: a PR that closes a 'main red: <run id>' issue needs 'Fixes main: <run id>' in its body (#1677).
set -u
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
body() { printf '%s\n' "$1" > "$tmp/body.md"; }
run() { bash "$here/check-main-fix.sh" --body-file "$tmp/body.md" --issue-title "$1" 2>&1; }

body $'Closes #5\n\nFixes main: 4242\n'
run 'main red: 4242' >/dev/null && ok "matching line passes" || bad "matching line refused"
body $'Closes #5\n'
out=$(run 'main red: 4242'); [ $? -eq 1 ] && grep -q 'Fixes main: 4242' <<<"$out" && ok "missing line refused, names the line" || bad "missing line: $out"
body $'Fixes main: 1111\n'
run 'main red: 4242' >/dev/null; [ $? -eq 1 ] && ok "other run id refused" || bad "other run id passed"
body $'no line\n'
run 'an ordinary issue' >/dev/null && ok "ordinary issue needs nothing" || bad "ordinary issue refused"
out=$(bash "$here/check-main-fix.sh" --help 2>&1); [ $? -eq 0 ] && grep -q Usage <<<"$out" && ok "--help prints usage" || bad "--help"
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
