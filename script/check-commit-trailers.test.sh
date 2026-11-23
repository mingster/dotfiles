#!/usr/bin/env bash
# Tests for script/check-commit-trailers.sh and the template copy. Fixtures are inline commit messages.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
chk="$here/check-commit-trailers.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
# shellcheck disable=SC1091
. "$here/tests/lib/git-identity.sh"
use_test_git_identity "$tmp"

run() { bash "$chk" "$@" >"$tmp/so" 2>"$tmp/se"; rc=$?; so=$(cat "$tmp/so"); se=$(cat "$tmp/se"); }
msg() { printf '%b' "$2" >"$tmp/$1"; }

msg good 'feat: x\n\nBody.\n\nOwner-approved: mingster 2026-11-16 (issue 1)\nCo-Authored-By: A <a@b.c>\n'
run --file "$tmp/good"
[ "$rc" -eq 0 ] && [ "$so" = "1 checked, 0 problems" ] && [ -z "$se" ] && ok "trailers in one block pass" || bad "good" "rc=$rc so=$so se=$se"

msg none 'feat: x\n\nJust a body.\n'
run --file "$tmp/none"
[ "$rc" -eq 0 ] && ok "no trailers passes" || bad "none" "rc=$rc $se"

msg blank 'feat: x\n\nBody.\n\nOwner-approved: mingster 2026-11-16 (issue 1)\n\nCo-Authored-By: A <a@b.c>\n'
run --file "$tmp/blank"
[ "$rc" -eq 1 ] && [ "$so" = "1 checked, 1 problems" ] && grep -q "^$tmp/blank:5: not a git trailer" <<<"$se" && ! grep -q ":7:" <<<"$se" \
  && ok "blank line before Co-Authored-By fails and names the line" || bad "blank" "rc=$rc so=$so se=$se"

# The real past mistake (a project commit, 6868a8ffd20a): a blank line between Owner-approved: and Co-Authored-By:.
msg real 'chore: name checker scripts check-<topic> (refs dotfiles#1123)\n\nOwner-approved: mingster 2026-11-16\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>'
run --file "$tmp/real"
[ "$rc" -eq 1 ] && grep -q ":3: not a git trailer" <<<"$se" && ok "fails on the real past commit message" || bad "real mistake" "rc=$rc $se"

msg lower 'feat: x\n\nBody.\n\nrefs: #1\n\nCloses: #2\n'
run --file "$tmp/lower"
[ "$rc" -eq 1 ] && grep -q ":5:" <<<"$se" && ok "keys match without regard to case" || bad "lower" "rc=$rc $se"

msg comment 'feat: x\n\nBody.\n\nRefs: #1\n# Please enter the commit message\n'
run --file "$tmp/comment"
[ "$rc" -eq 0 ] && ok "comment lines are ignored" || bad "comment" "rc=$rc $se"

# Prose that starts with a trailer key in an earlier paragraph is not a trailer (#1504).
msg prose 'fix: thing\n\nBody text here\nCloses: #5 is mentioned\n\nCo-Authored-By: A <a@b>\n'
run --file "$tmp/prose"
[ "$rc" -eq 0 ] && [ "$so" = "1 checked, 0 problems" ] && [ -z "$se" ] && ok "prose line starting with Closes: in a middle paragraph passes" || bad "prose" "rc=$rc so=$so se=$se"
msg prose2 'fix: thing\n\nRefs: this is only prose about the cause.\nIt goes on.\n\nMore prose.\n\nCo-Authored-By: A <a@b>\n'
run --file "$tmp/prose2"
[ "$rc" -eq 0 ] && ok "a prose paragraph opening with Refs: passes" || bad "prose2" "rc=$rc $se"
# A trailer-shaped line that ends the paragraph before the trailer block is not prose (#1553).
msg misplaced 'fix: thing\n\nSome prose about the change.\nOwner-approved: Name 2026-11-23\n\nCo-Authored-By: A <a@b>\n'
run --file "$tmp/misplaced"
[ "$rc" -eq 1 ] && grep -q ":4: not a git trailer" <<<"$se" && ok "Owner-approved ending a mixed paragraph before the trailer block fails" || bad "misplaced" "rc=$rc so=$so se=$se"
msg prose3 'fix: thing\n\nWe saw it.\nCloses: #5 is mentioned\n\nCo-Authored-By: A <a@b>\n'
run --file "$tmp/prose3"
[ "$rc" -eq 0 ] && ok "prose Closes: line right before the trailer block passes" || bad "prose3" "rc=$rc se=$se"
msg crlf 'fix: x\r\n\r\nBody.\r\n\r\nOwner-approved: mingster 2026-11-16\r\nCo-Authored-By: A <a@b.c>\r\n'
run --file "$tmp/crlf"
[ "$rc" -eq 0 ] && [ -z "$se" ] && ok "CRLF line endings pass" || bad "crlf" "rc=$rc se=$se"
msg crlfbad 'fix: x\r\n\r\nOwner-approved: mingster 2026-11-16\r\n\r\nCo-Authored-By: A <a@b.c>\r\n'
run --file "$tmp/crlfbad"
[ "$rc" -eq 1 ] && grep -q ":3: not a git trailer" <<<"$se" && ok "CRLF message with a blank line before a trailer still fails" || bad "crlfbad" "rc=$rc se=$se"
msg twoblank 'fix: x\n\nOwner-approved: mingster 2026-11-16\n\n\nCo-Authored-By: A <a@b.c>\n'
run --file "$tmp/twoblank"
[ "$rc" -eq 1 ] && grep -q ":3: " <<<"$se" && ok "two blank lines before a trailer still fail" || bad "twoblank" "rc=$rc se=$se"
msg midblank 'fix: x\n\nBody.\n\nRefs: #1\n\nOwner-approved: mingster 2026-11-16\n\nCo-Authored-By: A <a@b.c>\n'
run --file "$tmp/midblank"
[ "$rc" -eq 1 ] && grep -q ":5:" <<<"$se" && grep -q ":7:" <<<"$se" && ok "a run of trailer only paragraphs before the last is reported" || bad "midblank" "rc=$rc se=$se"

# a commit range
r="$tmp/repo"; git init -q -b main "$r"
git -C "$r" commit -q --allow-empty -m base
git -C "$r" commit -q --allow-empty -F "$tmp/good"
git -C "$r" commit -q --allow-empty -F "$tmp/blank"
mkdir "$r/script"; cp "$chk" "$r/script/"
( cd "$r" && bash script/check-commit-trailers.sh --commits HEAD~2..HEAD >"$tmp/so" 2>"$tmp/se" ); rc=$?
[ "$rc" -eq 1 ] && grep -qE "^[0-9a-f]{12}:5: " "$tmp/se" && [ "$(cat "$tmp/so")" = "2 checked, 1 problems" ] && ok "range: only the bad commit is reported" || bad "range" "rc=$rc $(cat "$tmp/so") $(cat "$tmp/se")"
run_in_repo() { ( cd "$r" && bash script/check-commit-trailers.sh "$@" >"$tmp/so" 2>"$tmp/se" ); rc=$?; so=$(cat "$tmp/so"); }
run_in_repo --commits HEAD..HEAD
[ "$rc" -eq 0 ] && [ "$so" = "0 checked, 0 problems" ] && ok "empty range passes" || bad "empty range" "rc=$rc $so"

run
[ "$rc" -eq 2 ] && ok "no input is a usage error" || bad "usage" "rc=$rc"
run --bogus
[ "$rc" -eq 2 ] && ok "unknown flag is a usage error" || bad "bogus" "rc=$rc"
run --file "$tmp/missing"
[ "$rc" -eq 2 ] && ok "missing file is a usage error" || bad "missing file" "rc=$rc"

# the commit-msg hook rejects the blank line case
h="$tmp/hookrepo"; mkdir -p "$h/script" "$h/.githooks"
cp "$chk" "$here/check-project-names.sh" "$h/script/"; cp "$src/.githooks/commit-msg" "$h/.githooks/"
git init -q -b main "$h"; git -C "$h" config core.hooksPath .githooks
out=$(git -C "$h" commit -q --allow-empty -F "$tmp/blank" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q "not a git trailer" <<<"$out" && ok "hook rejects a blank line before a trailer" || bad "hook blank" "rc=$rc $out"
git -C "$h" commit -q --allow-empty -F "$tmp/good" && ok "hook allows correct trailers" || bad "hook good" "rejected"

# the template copy matches, so adopted repos run the same check
cmp -s "$chk" "$src/templates/agent-team/bin/check-commit-trailers.sh" && ok "template copy of the checker is identical" || bad "template checker" "differs"
# the template hook calls bin/check-commit-trailers.sh, the place an adopted repo gets the checker
t="$tmp/adopted"; mkdir -p "$t/bin" "$t/.githooks"
cp "$src/templates/agent-team/bin/check-commit-trailers.sh" "$t/bin/"; cp "$src/templates/agent-team/.githooks/commit-msg" "$t/.githooks/"
git init -q -b main "$t"; git -C "$t" config core.hooksPath .githooks
out=$(git -C "$t" commit -q --allow-empty -F "$tmp/blank" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q "not a git trailer" <<<"$out" && ok "template hook rejects a blank line before a trailer" || bad "template hook" "rc=$rc $out"
git -C "$t" commit -q --allow-empty -F "$tmp/good" && ok "template hook allows correct trailers" || bad "template hook good" "rejected"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
