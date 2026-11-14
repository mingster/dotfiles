#!/usr/bin/env bash
# After agent-team.sh machine and project under a temp HOME, no file an agent loads
# contains a literal {{PROJECT_NAME}} (refs #807).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/agent-team.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/scratch"
git -C "$TMP/scratch" init -q
git -C "$TMP/scratch" remote add origin https://github.com/example/scratch.git

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

timeout 120 bash "$SCRIPT" machine >"$TMP/machine.log" 2>&1 && ok "machine exits 0" || bad "machine failed: $(tail -3 "$TMP/machine.log")"
timeout 120 bash "$SCRIPT" project "$TMP/scratch" >"$TMP/project.log" 2>&1 && ok "project exits 0" || bad "project failed: $(tail -3 "$TMP/project.log")"

# -R follows the symlinks machine creates into the templates.
hits=$(grep -rl -R '{{PROJECT_NAME}}' "$HOME/.claude/agents" "$HOME/.claude/hooks" "$TMP/scratch/docs" "$TMP/scratch/.claude" 2>/dev/null || true)
if [ -z "$hits" ]; then
  ok "no loaded file contains {{PROJECT_NAME}}"
else
  bad "{{PROJECT_NAME}} survives in: $hits"
fi

[ -f "$HOME/.claude/agents/elon.md" ] && [ ! -L "$HOME/.claude/agents/elon.md" ] && ok "user level role is a rendered copy" || bad "user level role is not a rendered copy"
grep -q 'CEO of this project' "$HOME/.claude/agents/elon.md" && ok "elon role reads 'this project'" || bad "elon role not rendered"
grep -q 'scratch is run' "$TMP/scratch/docs/agents/team.md" && ok "project team.md names the project" || bad "project team.md not rendered"

timeout 120 bash "$SCRIPT" check "$TMP/scratch" >"$TMP/check.log" 2>&1 && ok "check passes on rendered docs" || bad "check failed: $(tail -3 "$TMP/check.log")"

timeout 120 bash "$SCRIPT" machine >"$TMP/machine2.log" 2>&1 && ! grep -q '^\(wrote\|linked\)' "$TMP/machine2.log" && ok "machine rerun rewrites nothing" || bad "machine rerun not idempotent"

# Stale copy: a template edit after machine must fail check; rerunning machine fixes it.
# The template edit is undone by the EXIT trap.
BAK="$TMP/elon.md.bak"
TPL="$ROOT/templates/agent-team/.claude/agents/elon.md"
cp "$TPL" "$BAK"
trap 'cp "$BAK" "$TPL"; rm -rf "$TMP"' EXIT
printf 'A new rule line.\n' >>"$TPL"
timeout 120 bash "$SCRIPT" check "$TMP/scratch" >"$TMP/check2.log" 2>&1 && bad "check passes with a stale user level copy" || { grep -q 'stale copy' "$TMP/check2.log" && ok "check reports a stale user level copy" || bad "check failed without naming the stale copy"; }
timeout 120 bash "$SCRIPT" machine >"$TMP/machine3.log" 2>&1
grep -q '^wrote' "$TMP/machine3.log" && ok "machine rewrites the stale copy" || bad "machine did not rewrite the stale copy"
timeout 120 bash "$SCRIPT" check "$TMP/scratch" >"$TMP/check3.log" 2>&1 && ok "check passes after machine rerun" || bad "check still fails: $(tail -3 "$TMP/check3.log")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
