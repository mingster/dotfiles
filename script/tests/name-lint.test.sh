#!/usr/bin/env bash
# Tests for script/name-lint.sh, .githooks/commit-msg, checks-local.sh and ship.sh name checks.
# A temp pattern file with a fake name stands in for the private one.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=$(cd "$here/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

printf 'zorkmid\n\nplugh\n' >"$tmp/names.pattern"
export NO_PROJECT_NAMES_FILE="$tmp/names.pattern"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# name-lint.sh text
out=$(echo "fix the Zorkmid deploy" | bash "$here/name-lint.sh" text "PR title" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '"Zorkmid"' <<<"$out" && grep -q "Reword" <<<"$out"; then ok "text: match fails and names the word"; else bad "text match" "rc=$rc $out"; fi
echo "plain words" | bash "$here/name-lint.sh" text x >/dev/null 2>&1 && ok "text: clean passes" || bad "text clean" "failed"
out=$(echo "zorkmid" | NO_PROJECT_NAMES_FILE="$tmp/none" bash "$here/name-lint.sh" text x 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(wc -l <<<"$out" | tr -d ' ')" -eq 1 ] && grep -q warning -i <<<"$out" || grep -q "no pattern file" <<<"$out"; then ok "no pattern file: one warning, allow"; else bad "no pattern file" "rc=$rc $out"; fi

# Repo fixture with the hook and scripts
r="$tmp/repo"
mkdir -p "$r/script/tests/lib" "$r/.githooks"
cp "$src/script/name-lint.sh" "$src/script/checks-local.sh" "$src/script/select-changed-script-tests.sh" "$r/script/"
cp "$src/script/tests/lib/asdf-pin.sh" "$r/script/tests/lib/"
cp "$src/.githooks/commit-msg" "$r/.githooks/"
git -C "$r" init -q -b main
git -C "$r" add -A && git -C "$r" commit -qm base --no-verify
git -C "$r" config core.hooksPath .githooks

# 1. commit-msg hook
echo a >"$r/a.txt"; git -C "$r" add -A
out=$(git -C "$r" commit -qm "feat: add zorkmid support" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q '"zorkmid"' <<<"$out" && [ "$(git -C "$r" rev-list --count HEAD)" = 1 ]; then ok "hook rejects a commit with a pattern word"; else bad "hook reject" "rc=$rc $out"; fi
git -C "$r" commit -qm "feat: add support" && ok "hook allows a clean commit" || bad "hook clean" "rejected"

# 2. checks-local on a bad branch (commit made with --no-verify)
git -C "$r" checkout -qb topic
echo b >"$r/b.txt"; git -C "$r" add -A
git -C "$r" commit -qm "mention plugh" --no-verify
out=$(bash "$r/script/checks-local.sh" --base main 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q '"plugh"' <<<"$out"; then ok "checks-local fails on a bad commit message"; else bad "checks-local message" "rc=$rc $out"; fi
git -C "$r" reset -q --soft HEAD~1; git -C "$r" commit -qm "clean message"
echo "the zorkmid file" >"$r/c.txt"; git -C "$r" add -A; git -C "$r" commit -qm "add c"
out=$(bash "$r/script/name-lint.sh" branch main 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "c.txt" <<<"$out"; then ok "branch lint fails on a bad changed file"; else bad "branch file" "rc=$rc $out"; fi

# 3. ship.sh refuses a PR title or body
# shellcheck disable=SC1091
. "$here/tests/lib/merge-fixture.sh"
mf_setup
trap 'mf_teardown; rm -rf "$tmp"' EXIT
cd "$MF_REPO" || exit 1
mf_pr_add 1 feat-title "Body"
jq '.title = "feat: zorkmid thing"' "$MF_GH_DIR/pr-1.json" >"$MF_GH_DIR/p.tmp" && mv "$MF_GH_DIR/p.tmp" "$MF_GH_DIR/pr-1.json"
out=$(bash "$here/ship.sh" --repo example/repo --pr 1 --dry-run 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "title" <<<"$out" && grep -q "zorkmid" <<<"$out"; then ok "ship refuses a PR title with a pattern word"; else bad "ship title" "rc=$rc $out"; fi
mf_pr_add 2 feat-body "Notes about plugh"
out=$(bash "$here/ship.sh" --repo example/repo --pr 2 --dry-run 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "body" <<<"$out" && grep -q "plugh" <<<"$out"; then ok "ship refuses a PR body with a pattern word"; else bad "ship body" "rc=$rc $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
