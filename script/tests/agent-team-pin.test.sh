#!/usr/bin/env bash
# sync records the dotfiles commit it rendered from in .claude/agent-team-pin, and check --pinned checks the
# project against the template at that commit, so a later template merge does not fail the project (#1247).
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
expect() { # <label> <want rc 0|nonzero> <rc>
  if { [ "$2" = 0 ] && [ "$3" -eq 0 ]; } || { [ "$2" != 0 ] && [ "$3" -ne 0 ]; }; then ok "$1"; else bad "$1 (rc=$3)"; cat "$TMP/out"; fi
}
git_q() { git -c user.name=t -c user.email=t@example.invalid -C "$@"; }

DF="$TMP/dotfiles"
mkdir -p "$DF"
cp -R "$ROOT/script" "$ROOT/templates" "$ROOT/.agents" "$DF/"
git -C "$DF" init -q -b main
git_q "$DF" add -A
git_q "$DF" commit -qm X
X=$(git -C "$DF" rev-parse HEAD)

PROJ="$TMP/proj"
mkdir -p "$PROJ"
printf '# Proj\n' >"$PROJ/AGENTS.md"
git -C "$PROJ" init -q -b main
git -C "$PROJ" remote add origin https://github.com/example-org/proj.git
DOTFILES="$DF" bash "$DF/script/agent-team.sh" sync "$PROJ" >"$TMP/out" 2>&1 || { cat "$TMP/out"; bad "sync at X"; }

pin=$(cat "$PROJ/.claude/agent-team-pin" 2>/dev/null)
[ "$pin" = "$X" ] && ok "sync writes pin = dotfiles HEAD" || bad "sync writes pin = dotfiles HEAD (got '$pin')"
grep -q 'integer expression' "$TMP/out" && bad "sync runs without a shell error" || ok "sync runs without a shell error"

# A dry-run sync leaves the pin alone.
printf 'keep\n' >"$PROJ/.claude/agent-team-pin"
DOTFILES="$DF" bash "$DF/script/agent-team.sh" sync "$PROJ" --dry-run >"$TMP/out" 2>&1
[ "$(cat "$PROJ/.claude/agent-team-pin")" = keep ] && grep -q "would write .claude/agent-team-pin = $X" "$TMP/out" \
  && ok "a dry-run sync does not write the pin" || bad "a dry-run sync does not write the pin"
printf '%s\n' "$X" >"$PROJ/.claude/agent-team-pin"

check() { DOTFILES="$DF" bash "$DF/script/agent-team.sh" check "$@" "$PROJ" >"$TMP/out" 2>&1; }

rc=0; check || rc=$?; expect "plain check passes right after sync" 0 "$rc"
rc=0; check --pinned || rc=$?; expect "pinned check passes right after sync" 0 "$rc"

# Template change at Y, the project still at X.
printf '\nA template change after the sync.\n' >>"$DF/templates/agent-team/docs/agents/team.md"
git_q "$DF" commit -qam Y
rc=0; check || rc=$?; expect "plain check fails after a template change" 1 "$rc"
grep -q 'template-managed file drifted: docs/agents/team.md' "$TMP/out" && ok "plain check names the drifted file" || bad "plain check names the drifted file"
rc=0; check --pinned || rc=$?; expect "pinned check passes after a template change" 0 "$rc"

# A hand edit of a template-managed file still fails at the pin.
cp "$PROJ/docs/agents/team.md" "$TMP/team.md"
printf '\nhand edit\n' >>"$PROJ/docs/agents/team.md"
rc=0; check --pinned || rc=$?; expect "pinned check fails a hand edit of team.md" 1 "$rc"
grep -q 'template-managed file drifted: docs/agents/team.md' "$TMP/out" && ok "pinned check names the hand edited file" || bad "pinned check names the hand edited file"
cp "$TMP/team.md" "$PROJ/docs/agents/team.md"

# A pin the dotfiles history does not hold.
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 >"$PROJ/.claude/agent-team-pin"
rc=0; check --pinned || rc=$?; expect "pinned check fails an unknown pin" 1 "$rc"
grep -q 'not in the dotfiles history' "$TMP/out" && ok "unknown pin is reported as drift" || bad "unknown pin is reported as drift"

# No pin: today's check against the current template.
rm -f "$PROJ/.claude/agent-team-pin"
rc=0; check --pinned || rc=$?; expect "no pin falls back to the current check (fails at Y)" 1 "$rc"
grep -q 'template-managed file drifted: docs/agents/team.md' "$TMP/out" && ok "fallback reports the current drift" || bad "fallback reports the current drift"
git -C "$DF" checkout -q "$X"
rc=0; check --pinned || rc=$?; expect "no pin falls back to the current check (passes at X)" 0 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
