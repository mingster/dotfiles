#!/usr/bin/env bash
# contribute-to-agents.sh writes dated entries under the notes folder and refuses topics that
# are empty, contain a slash, or start with a dot.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DOTFILES="$TMP/dot"
NOTES="$DOTFILES/.agents/claude/notes"
SCRIPT="$ROOT/script/contribute-to-agents.sh"
pass=0 fail=0
check() { if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $CASE"; fi; }

CASE="new topic is created"
"$SCRIPT" demo "first note" >/dev/null 2>&1
check test -f "$NOTES/demo.md"
CASE="new topic has header"
check test "$(head -n1 "$NOTES/demo.md")" = "# demo"
CASE="new topic has dated entry"
check grep -q "^## $(date '+%Y-%m-%d')$" "$NOTES/demo.md"
CASE="entry text written"
check grep -q '^first note$' "$NOTES/demo.md"

CASE="second call appends"
"$SCRIPT" demo "second note" >/dev/null 2>&1
check grep -q '^second note$' "$NOTES/demo.md"
CASE="second call keeps first note"
check grep -q '^first note$' "$NOTES/demo.md"
CASE="header not repeated"
check test "$(grep -c '^# demo$' "$NOTES/demo.md")" = 1

before="$(find "$TMP" -type f | sort)"
for bad in "" "../../escape" "a/b" ".hidden" ".."; do
  CASE="bad topic '$bad' exits 1"
  "$SCRIPT" "$bad" "x" >/dev/null 2>"$TMP/err"
  rc=$?
  check test "$rc" -eq 1
  CASE="bad topic '$bad' prints usage"
  check grep -q '^Usage:' "$TMP/err"
done
CASE="bad topics write nothing"
check test "$before" = "$(find "$TMP" -type f -not -name err | sort)"
CASE="no escape file"
check test ! -e "$DOTFILES/escape.md"

CASE="--help exits 0"
"$SCRIPT" --help >"$TMP/out" 2>&1 </dev/null
check test "$?" -eq 0
CASE="-h exits 0"
"$SCRIPT" -h >/dev/null 2>&1 </dev/null
check test "$?" -eq 0
CASE="--help prints usage"
check grep -q '^Usage:' "$TMP/out"
CASE="-x exits 1"
"$SCRIPT" -x "text" >/dev/null 2>"$TMP/err" </dev/null
check test "$?" -eq 1
CASE="-x prints usage"
check grep -q '^Usage:' "$TMP/err"
CASE="three arguments exit 1"
"$SCRIPT" demo a b >/dev/null 2>"$TMP/err" </dev/null
check test "$?" -eq 1
CASE="three arguments print usage"
check grep -q '^Usage:' "$TMP/err"
CASE="three arguments add nothing"
check test "$(grep -c '^a$' "$NOTES/demo.md")" = 0
CASE="no flag-named note files"
check test -z "$(find "$NOTES" -name '-*')"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
