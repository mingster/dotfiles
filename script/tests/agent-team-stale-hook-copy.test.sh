#!/usr/bin/env bash
# A kept guard-bash.py or tests/test_guard_bash.py that is an older template release follows the template on
# sync, and check reports it (#1392). A copy no template release ever had is the project's own and stays (#1179).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
git_q() { git -c user.name=t -c user.email=t@example.invalid -C "$@"; }

GUARD=.claude/hooks/guard-bash.py
TEST=.claude/hooks/tests/test_guard_bash.py

# Dotfiles copy with two template releases: OLD (committed) and NEW (one more line in both files).
DF="$TMP/dotfiles"
mkdir -p "$DF"
cp -R "$ROOT/script" "$ROOT/templates" "$ROOT/.agents" "$DF/"
git -C "$DF" init -q -b main
git_q "$DF" add -A
git_q "$DF" commit -qm old
for f in "$GUARD" "$TEST"; do
  mkdir -p "$TMP/old/$(dirname "$f")"
  cp "$DF/templates/agent-team/$f" "$TMP/old/$f"
  printf '\n# new release line\n' >>"$DF/templates/agent-team/$f"
done
git_q "$DF" commit -qam new

mkproj() { # <dir>: a project that keeps guard-bash.py (a project hook loads it)
  mkdir -p "$1/.claude/hooks/tests"
  printf '# Proj\n' >"$1/AGENTS.md"
  printf 'import runpy\nfrom pathlib import Path\n\nrunpy.run_path(str(Path(__file__).with_name("guard-bash.py")))\n' >"$1/.claude/hooks/project-guard.py"
  git -C "$1" init -q -b main
  git -C "$1" remote add origin https://github.com/example-org/proj.git
}
run() { DOTFILES="$DF" bash "$DF/script/agent-team.sh" "$@" >"$TMP/out" 2>&1; }

# 1. Stale stock copies: check reports them, sync refreshes them, check then passes.
P1="$TMP/stale"
mkproj "$P1"
cp "$TMP/old/$GUARD" "$P1/$GUARD"
cp "$TMP/old/$TEST" "$P1/$TEST"
run check "$P1"
grep -qF "kept hook file is a stale template copy: $GUARD" "$TMP/out" \
  && grep -qF "kept hook file is a stale template copy: $TEST" "$TMP/out" \
  && ok "check reports both stale copies" || { bad "check reports both stale copies"; cat "$TMP/out"; }
run sync "$P1" --dry-run
grep -qF "would update $GUARD" "$TMP/out" && cmp -s "$TMP/old/$GUARD" "$P1/$GUARD" \
  && ok "dry run plans the refresh and writes nothing" || { bad "dry run plans the refresh and writes nothing"; cat "$TMP/out"; }
run sync "$P1" || { bad "sync runs"; cat "$TMP/out"; }
cmp -s "$DF/templates/agent-team/$GUARD" "$P1/$GUARD" && cmp -s "$DF/templates/agent-team/$TEST" "$P1/$TEST" \
  && ok "sync writes the template copies" || bad "sync writes the template copies"
run check "$P1"
grep -q "stale template copy" "$TMP/out" && { bad "check passes the stale copy check after sync"; cat "$TMP/out"; } || ok "check passes the stale copy check after sync"

# 2. A customized copy (never a template release) stays.
P2="$TMP/custom"
mkproj "$P2"
{ cat "$TMP/old/$GUARD"; printf '\n# project rule\n'; } >"$P2/$GUARD"
cp "$P2/$GUARD" "$TMP/custom-guard"
run sync "$P2" || { bad "sync runs on a customized copy"; cat "$TMP/out"; }
cmp -s "$TMP/custom-guard" "$P2/$GUARD" && ok "a customized guard-bash.py stays" || bad "a customized guard-bash.py stays"
run check "$P2"
grep -q "stale template copy" "$TMP/out" && bad "check does not flag a customized copy" || ok "check does not flag a customized copy"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
