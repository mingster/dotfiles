#!/usr/bin/env bash
# Tests for script/check-guard-false-positives.sh (#1135).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/script/check-guard-false-positives.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

out="$(bash "$SCRIPT" 2>"$TMP/err")"
rc=$?
if [ "$rc" -eq 0 ] && grep -q ' 0 problems$' <<<"$out" && [ ! -s "$TMP/err" ]; then
  ok "seeded fixtures pass"
else
  bad "seeded fixtures pass (rc=$rc out=$out err=$(cat "$TMP/err"))"
fi

for need in allow/commit-message-heredoc.txt allow/issue-comment-heredoc.txt deny/heredoc-fed-to-bash.txt deny/heredoc-fed-to-ssh.txt; do
  [ -f "$ROOT/templates/agent-team/.claude/hooks/tests/fixtures/$need" ] && ok "seeded $need" || bad "seeded $need"
done

# A heredoc fed to bash is refused, so as an allow fixture it flips.
mkdir -p "$TMP/flip/allow" "$TMP/flip/deny"
printf '%s\n' "bash <<'EOF'" "bash bin/deploy-raw.sh" "EOF" >"$TMP/flip/allow/runs-a-guarded-script.txt"
# Plain prose to a file is allowed, so as a deny fixture it flips.
printf '%s\n' "cat > note.md <<'EOF'" "bin/deploy-raw.sh is named here." "EOF" >"$TMP/flip/deny/only-mentions-it.txt"
out="$(bash "$SCRIPT" "$TMP/flip" 2>"$TMP/err")"
rc=$?
if [ "$rc" -eq 1 ] \
  && grep -qF "$TMP/flip/allow/runs-a-guarded-script.txt:1: allow fixture is blocked" "$TMP/err" \
  && grep -qF "$TMP/flip/deny/only-mentions-it.txt:1: deny fixture passes" "$TMP/err" \
  && grep -q '2 fixtures, 2 problems$' <<<"$out"; then
  ok "flipped fixtures exit 1 and name each file"
else
  bad "flipped fixtures exit 1 and name each file (rc=$rc out=$out err=$(cat "$TMP/err"))"
fi

bash "$SCRIPT" a b >/dev/null 2>&1; [ $? -eq 2 ] && ok "too many arguments exits 2" || bad "too many arguments exits 2"
bash "$SCRIPT" "$TMP/missing" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing fixtures dir exits 2" || bad "missing fixtures dir exits 2"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
