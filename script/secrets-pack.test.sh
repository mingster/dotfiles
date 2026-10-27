#!/usr/bin/env bash
# Round trip on a throwaway fake directory only. Never point this at real secrets.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass + 1)); echo "ok   $DESC"; else fail=$((fail + 1)); echo "FAIL $DESC"; fi; }

mkdir -p "$tmp/fake/sub"
echo "fake-value-1" >"$tmp/fake/a.txt"
echo "fake-value-2" >"$tmp/fake/sub/b.txt"
phrase="correct horse battery staple fake"

DESC="pack writes an image from stdin passphrase"
printf '%s\n' "$phrase" | bash "$here/secrets-pack.sh" "$tmp/fake" "$tmp/out.dmg" >"$tmp/pack.out" 2>&1
check test -f "$tmp/out.dmg"
DESC="pack output does not contain the passphrase"
check test -z "$(grep -F "$phrase" "$tmp/pack.out")"
DESC="pack refuses to overwrite"
printf '%s\n' "$phrase" | bash "$here/secrets-pack.sh" "$tmp/fake" "$tmp/out.dmg" >/dev/null 2>&1; rc=$?
check test "$rc" -ne 0
DESC="image does not store plain file contents"
check test -z "$(grep -a -c 'fake-value-1' "$tmp/out.dmg" | grep -v '^0$')"

DESC="wrong passphrase is refused and nothing is written"
printf 'wrong\n' | bash "$here/secrets-unpack.sh" "$tmp/out.dmg" "$tmp/bad" >"$tmp/bad.out" 2>&1; rc=$?
check test "$rc" -ne 0 -a ! -e "$tmp/bad/a.txt"
DESC="right passphrase restores every file"
printf '%s\n' "$phrase" | bash "$here/secrets-unpack.sh" "$tmp/out.dmg" "$tmp/back" >"$tmp/ok.out" 2>&1
check diff -r "$tmp/fake" "$tmp/back"
DESC="unpacked directory is private (700)"
check test "$(stat -f %Lp "$tmp/back")" = 700
DESC="unpack output does not contain the passphrase"
check test -z "$(grep -F "$phrase" "$tmp/ok.out")"
DESC="no mounted image is left behind"
check test -z "$(mount | grep -F "$tmp")"
DESC="scripts never take the passphrase as an argument or variable from outside"
# shellcheck disable=SC2016
check test -z "$(grep -n -E 'PASS(PHRASE|WORD)?=|--pass|\$2.*pass' "$here/secrets-pack.sh" "$here/secrets-unpack.sh")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
