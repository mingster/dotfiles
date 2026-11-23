#!/usr/bin/env bash
# Tests for script/check-display-settings.sh (#1409).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/check-display-settings.sh"
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

"$SCRIPT" "$ROOT/.agents/claude/settings.json" >/dev/null && ok "tracked source has the four keys" || bad "tracked source drifted"

echo '{"verbose":true,"spinnerTipsEnabled":false,"prefersReducedMotion":true,"tui":"fullscreen","env":{"SECRET":"hunter2"}}' > "$TMP/clean.json"
out=$("$SCRIPT" "$TMP/clean.json"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "matching host exits 0" || bad "matching host (rc=$rc, out=$out)"

echo '{"verbose":false,"spinnerTipsEnabled":false,"tui":"default","env":{"SECRET":"hunter2"}}' > "$TMP/drift.json"
out=$("$SCRIPT" "$TMP/drift.json"); rc=$?
[ "$rc" = 1 ] && ok "drifted host exits 1" || bad "drifted host (rc=$rc)"
want='display key verbose: false
display key prefersReducedMotion: missing
display key tui: "default"'
[ "$out" = "$want" ] && ok "names each drifted key" || bad "output: $out"
case "$out" in *hunter2*) bad "leaked other values" ;; *) ok "no other values printed" ;; esac

echo '{}' > "$TMP/empty.json"
out=$("$SCRIPT" "$TMP/empty.json"); [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ] && ok "empty file reports all four" || bad "empty file"
"$SCRIPT" "$TMP/missing.json" >/dev/null 2>&1; [ "$?" = 2 ] && ok "missing file exits 2" || bad "missing file"
echo 'not json' > "$TMP/bad.json"
"$SCRIPT" "$TMP/bad.json" >/dev/null 2>&1; [ "$?" = 2 ] && ok "unreadable file exits 2" || bad "unreadable file"
: > "$TMP/zero.json"
"$SCRIPT" "$TMP/zero.json" >/dev/null 2>&1; [ "$?" = 2 ] && ok "zero-byte file exits 2" || bad "zero-byte file"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
