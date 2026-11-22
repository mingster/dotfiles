#!/usr/bin/env bash
# setup-antigravity.sh hooks merge: a broken hooks.json fails the run, leaves no .tmp, and prints no success line.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$root/script/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }

mkdir -p "$tmp/home/.gemini/config" "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/agy"; chmod +x "$tmp/bin/agy"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/bin/python3"
hooks="$tmp/home/.gemini/config/hooks.json"
run() { HOME="$tmp/home" DOTFILES="$root" PATH="$tmp/bin:$PATH" bash "$root/script/setup-antigravity.sh" >"$tmp/out" 2>"$tmp/err"; }

printf '{"broken": ' > "$hooks"
run; rc=$?
check "broken hooks.json exits non-zero" "$([ "$rc" != 0 ]; echo $?)"
check "no .tmp left behind" "$([ ! -e "$hooks.tmp" ]; echo $?)"
check "original hooks.json untouched" "$([ "$(cat "$hooks")" = '{"broken": ' ]; echo $?)"
check "no success line" "$(! grep -q 'merged usage-gate hook' "$tmp/out"; echo $?)"
check "error on stderr" "$(grep -q 'setup-antigravity:.*hooks' "$tmp/err"; echo $?)"

echo '{}' > "$hooks"
run
check "valid hooks.json prints the success line" "$(grep -q 'merged usage-gate hook' "$tmp/out"; echo $?)"
check "valid merge leaves no .tmp" "$([ ! -e "$hooks.tmp" ]; echo $?)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
