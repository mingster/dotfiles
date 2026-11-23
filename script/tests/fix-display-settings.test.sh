#!/usr/bin/env bash
# Tests for script/fix-display-settings.sh (#1682).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$ROOT/script/fix-display-settings.sh"
CHECK="$ROOT/script/check-display-settings.sh"
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
# A python3 only PATH proves the fixer needs no jq
nojq="$TMP/bin"; mkdir -p "$nojq"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$nojq/python3"
for t in bash sed dirname; do ln -s "$(command -v "$t")" "$nojq/$t"; done
run_fix() { PATH="$nojq" "$FIX" "$@"; }

H="$TMP/home"
mkdir -p "$H/.claude" "$H/orca/p1" "$H/orca/p2"
printf '{"env":{"TOKEN":"s3cret"},"verbose":true,"spinnerTipsEnabled":false,"tui":"default","hooks":{"a":[1,2]}}\n' > "$H/.claude/settings.json"
chmod 640 "$H/.claude/settings.json"
printf '{"verbose":false,"spinnerTipsEnabled":false,"prefersReducedMotion":true,"tui":"fullscreen"}\n' > "$H/orca/p1/settings.json"
cp "$H/orca/p1/settings.json" "$TMP/p1.before"
printf '{"verbose":true}\n' > "$TMP/target.json"
ln -s "$TMP/target.json" "$H/orca/p2/settings.json"
printf 'not json{' > "$H/bad.json"
cp "$H/bad.json" "$TMP/bad.before"

out=$(run_fix "$H/.claude/settings.json" "$H/orca/p1/settings.json" "$H/orca/p2/settings.json" "$H/bad.json"); rc=$?
[ "$rc" = 1 ] && ok "exits 1 only because of the invalid file" || bad "rc=$rc"
grep -q "^fixed $H/.claude/settings.json$" <<<"$out" && ok "drifted file is fixed" || bad "no fixed line: $out"
"$CHECK" "$H/.claude/settings.json" >/dev/null && ok "check-display-settings finds no drift after the fix" || bad "drift remains"
python3 -I - "$H/.claude/settings.json" <<'PY' && ok "other keys untouched" || bad "other keys changed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["env"] == {"TOKEN": "s3cret"} and d["hooks"] == {"a": [1, 2]}
assert list(d)[:2] == ["env", "verbose"], list(d)
PY
[ "$(stat -c %a "$H/.claude/settings.json" 2>/dev/null || stat -f %Lp "$H/.claude/settings.json")" = 640 ] && ok "file mode kept" || bad "file mode changed"
[ -z "$(find "$H/.claude" -name '.settings.*')" ] && ok "no temp file left" || bad "temp file left"
cmp -s "$H/orca/p1/settings.json" "$TMP/p1.before" && grep -q "^ok $H/orca/p1/settings.json$" <<<"$out" && ok "clean file not rewritten" || bad "clean file touched"
[ -L "$H/orca/p2/settings.json" ] && [ "$(cat "$TMP/target.json")" = '{"verbose":true}' ] && grep -q "^skip $H/orca/p2/settings.json (symlink)$" <<<"$out" && ok "symlink skipped, target unchanged" || bad "symlink handling: $out"
cmp -s "$H/bad.json" "$TMP/bad.before" && grep -q "^fail $H/bad.json (unreadable" <<<"$out" && ok "invalid JSON reported, not overwritten" || bad "invalid JSON handling: $out"
printf '[1,2]\n' > "$H/arr.json"
run_fix "$H/arr.json" >/dev/null; [ "$?" = 1 ] && [ "$(cat "$H/arr.json")" = '[1,2]' ] && ok "non-object JSON reported, not overwritten" || bad "non-object JSON"
out=$(run_fix "$H/.claude/settings.json"); [ "$?" = 0 ] && [ "$out" = "ok $H/.claude/settings.json" ] && ok "second run is a no-op" || bad "second run: $out"
out=$(run_fix "$H/missing.json"); [ "$?" = 1 ] && ok "missing file fails" || bad "missing file: $out"
printf '{"verbose":0,"spinnerTipsEnabled":0,"prefersReducedMotion":1,"tui":"fullscreen"}\n' > "$H/num.json"
run_fix "$H/num.json" >/dev/null; "$CHECK" "$H/num.json" >/dev/null && ok "0 and 1 are not accepted as false and true" || bad "type confusion"
run_fix --help | grep -q '^Usage: fix-display-settings.sh' && ok "--help prints usage" || bad "--help"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
