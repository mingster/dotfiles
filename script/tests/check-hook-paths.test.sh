#!/usr/bin/env bash
# Tests for script/check-hook-paths.sh (#1416).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/check-hook-paths.sh"
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/dotfiles/script"
touch "$HOME/dotfiles/script/present.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cat > "$TMP/stale.json" <<'J'
{"env":{"SECRET":"hunter2"},"hooks":{"SessionStart":[{"hooks":[
 {"type":"command","command":"$HOME/dotfiles/script/present.sh"},
 {"type":"command","command":"~/dotfiles/script/agent-project-autoinit.sh --x"}]}]}}
J
out=$("$SCRIPT" "$TMP/stale.json"); rc=$?
[ "$rc" = 1 ] && ok "stale hook exits 1" || bad "stale hook exits 1 (rc=$rc)"
[ "$out" = "stale hook SessionStart: ~/dotfiles/script/agent-project-autoinit.sh" ] && ok "names the stale path only" || bad "output: $out"
case "$out" in *hunter2*|*present.sh*) bad "leaked other values" ;; *) ok "no other values printed" ;; esac

cat > "$TMP/clean.json" <<'J'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ${HOME}/dotfiles/script/present.sh"},{"type":"command","command":"echo hi"}]}]}}
J
out=$("$SCRIPT" "$TMP/clean.json"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "clean file exits 0" || bad "clean file (rc=$rc, out=$out)"

echo '{}' > "$TMP/none.json"
"$SCRIPT" "$TMP/none.json" >/dev/null && ok "no hooks exits 0" || bad "no hooks"
"$SCRIPT" "$TMP/missing.json" >/dev/null 2>&1; [ "$?" = 2 ] && ok "missing file exits 2" || bad "missing file"

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
