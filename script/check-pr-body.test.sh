#!/usr/bin/env bash
# Tests for script/check-pr-body.sh (#1676): the pr-body-gate check, run before a PR opens.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-pr-body.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

good() {
  cat <<'B'
Closes #5

Builder: agent=claude model=claude-sonnet-5-5

## Self-check
$ bash script/checks-local.sh 2>&1 | tail -3
all checks passed
B
}
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

good >"$TMP/good.md"
run "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "a full body passes" || bad "full body (rc=$rc, $out)"

grep -v '^## Self-check' "$TMP/good.md" >"$TMP/nosc.md"
run "$TMP/nosc.md"
if [ "$rc" -eq 1 ] && grep -qF "## Self-check" <<<"$out"; then ok "a body with no Self-check heading is refused and names the section"; else bad "no Self-check (rc=$rc, $out)"; fi

sed '/^\$ bash/d;/^all checks/d' "$TMP/good.md" >"$TMP/empty.md"
run "$TMP/empty.md"
if [ "$rc" -eq 1 ] && grep -qF "## Self-check" <<<"$out" && grep -qi "command" <<<"$out"; then ok "an empty Self-check is refused"; else bad "empty Self-check (rc=$rc, $out)"; fi

grep -v '^Builder:' "$TMP/good.md" >"$TMP/nob.md"
run "$TMP/nob.md"
if [ "$rc" -eq 1 ] && grep -qF "Builder:" <<<"$out"; then ok "a body with no Builder line is refused and names it"; else bad "no Builder (rc=$rc, $out)"; fi

run --issue 5 "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "--issue with its closing line passes" || bad "--issue pass (rc=$rc, $out)"
run --issue 6 "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "Closes #6" <<<"$out"; then ok "--issue without its closing line is refused"; else bad "--issue 6 (rc=$rc, $out)"; fi

run --issue '#6' "$TMP/good.md"
[ "$rc" -eq 1 ] && ok "--issue '#6' is read as 6 and refused without its closing line" || bad "hash issue (rc=$rc, $out)"
run --issue abc "$TMP/good.md"
[ "$rc" -eq 2 ] && ok "a non numeric --issue is a usage error" || bad "abc (rc=$rc)"

# --title runs check-pr-body-issues.sh (#1688): a body that skips a title issue fails.
run --title "fix: thing (#5)" "$TMP/good.md"
[ "$rc" -eq 0 ] && ok "--title whose issue the body closes passes" || bad "title pass (rc=$rc, $out)"
run --title "fix: thing (#5) (#7)" "$TMP/good.md"
if [ "$rc" -eq 1 ] && grep -qF "#7" <<<"$out"; then ok "--title naming an issue the body skips is refused"; else bad "title skip (rc=$rc, $out)"; fi

run "$TMP/missing.md"
[ "$rc" -eq 2 ] && ok "a missing file is a usage error" || bad "missing file (rc=$rc)"
run
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
