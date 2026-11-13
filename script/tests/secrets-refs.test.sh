#!/usr/bin/env bash
# Tests for script/secrets-refs.sh: file:line only, never the matched text, never inside a secrets folder.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFS="$ROOT/script/secrets-refs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

P="$TMP/proj"
mkdir -p "$P/secrets" "$P/sub" "$P/.git"
printf 'one\nread the secrets folder TOPSECRETWORD here\nthree\nsecrets again\n' >"$P/deploy.sh"
printf 'nothing here\n' >"$P/sub/clean.txt"
printf 'secrets/inside the folder\n' >"$P/secrets/key"
printf 'secrets in git\n' >"$P/.git/config"
printf 'secrets/linked\n' >"$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$P/sub/link"

out=$(bash "$REFS" "$P" secrets 2>&1); rc=$?
real=$(cd "$P" && pwd -P)
if [ "$rc" -eq 0 ]; then ok "exit 0"; else bad "rc $rc: $out"; fi
if [ "$(sort <<<"$out")" = "$(printf '%s\n%s\n' "$real/deploy.sh:2" "$real/deploy.sh:4")" ]; then ok "prints file:line for each match"; else bad "output: $out"; fi
if ! grep -q "TOPSECRETWORD" <<<"$out"; then ok "never prints the matched text"; else bad "printed text"; fi
if ! grep -qE "/secrets/|\.git/|elsewhere" <<<"$out"; then ok "skips secrets, .git and symlinks"; else bad "searched too far: $out"; fi
out=$(bash "$REFS" "$P" nomatch-anywhere 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "no match prints nothing, exit 0"; else bad "no match: rc $rc $out"; fi
out=$(bash "$REFS" "$P/secrets" key 2>&1); rc=$?
if [ "$rc" -eq 2 ] && ! grep -q "inside the folder" <<<"$out"; then ok "refuses a secrets folder as the dir"; else bad "inside folder: rc $rc $out"; fi
ln -s "$P/secrets" "$TMP/viaLink"
out=$(bash "$REFS" "$TMP/viaLink" key 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "refuses a symlink to a secrets folder"; else bad "symlink dir: rc $rc $out"; fi
out=$(bash "$REFS" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "wrong argument count exits 2"; else bad "no args rc $rc"; fi
out=$(bash "$REFS" -r secrets 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "an option instead of a dir exits 2"; else bad "option rc $rc"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
