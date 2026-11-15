#!/usr/bin/env bash
# Tests for script/check-project-names.sh and its callers: the commit-msg hook, checks-local.sh, ship.sh.
# Fixtures are inline and use a fake name in a temp pattern file.
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
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
printf 'zorkmid\n\nplugh\n' >"$tmp/names.pattern"
export NO_PROJECT_NAMES_FILE="$tmp/names.pattern"
chk="$here/check-project-names.sh"

# run <args...>: sets rc, so (stdout) and se (stderr)
run() { bash "$chk" "$@" >"$tmp/so" 2>"$tmp/se"; rc=$?; so=$(cat "$tmp/so"); se=$(cat "$tmp/se"); }

# Checker: valid, each failure, missing pattern file, usage
printf 'clean text\nsecond line\n' >"$tmp/clean.txt"
printf 'ok line\nthe Zorkmid host\n' >"$tmp/dirty.txt"
run --file "$tmp/clean.txt"
[ "$rc" -eq 0 ] && [ "$so" = "1 checked, 0 problems" ] && [ -z "$se" ] && ok "clean file passes with a summary" || bad "clean" "rc=$rc so=$so se=$se"
run --file "$tmp/dirty.txt"
[ "$rc" -eq 1 ] && [ "$so" = "1 checked, 1 problems" ] && grep -qE "^$tmp/dirty.txt:2: private name" <<<"$se" && ! grep -qi zorkmid <<<"$se" \
  && ok "dirty file: source:line on stderr, word hidden, exit 1" || bad "dirty" "rc=$rc so=$so se=$se"
run --show-match --file "$tmp/dirty.txt"
grep -q '"Zorkmid"' <<<"$se" && ok "--show-match names the word" || bad "show-match" "$se"
run --allow-missing --file "$tmp/clean.txt"
NO_PROJECT_NAMES_FILE="$tmp/none" run --file "$tmp/clean.txt"
[ "$rc" -eq 1 ] && grep -q "pattern file missing" <<<"$se" && ok "missing pattern file fails" || bad "missing" "rc=$rc $se"
NO_PROJECT_NAMES_FILE="$tmp/none" run --allow-missing --file "$tmp/clean.txt"
[ "$rc" -eq 0 ] && grep -q SKIPPED <<<"$so" && ok "--allow-missing skips with one line" || bad "allow-missing" "rc=$rc $so"
run
[ "$rc" -eq 2 ] && ok "no input is a usage error" || bad "usage" "rc=$rc"
run --bogus
[ "$rc" -eq 2 ] && ok "unknown flag is a usage error" || bad "bogus" "rc=$rc"

# Fixture repo: checker, hook, checks-local
r="$tmp/repo"
mkdir -p "$r/script/tests/lib" "$r/.githooks"
cp "$chk" "$src/script/checks-local.sh" "$src/script/select-changed-script-tests.sh" "$r/script/"
cp "$src/script/tests/lib/asdf-pin.sh" "$r/script/tests/lib/"
cp "$src/.githooks/commit-msg" "$r/.githooks/"
git -C "$r" init -q -b main
git -C "$r" add -A && git -C "$r" commit -qm base --no-verify
git -C "$r" config core.hooksPath .githooks

echo a >"$r/a.txt"; git -C "$r" add -A
out=$(git -C "$r" commit -qm "feat: add zorkmid support" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q '"zorkmid"' <<<"$out" && [ "$(git -C "$r" rev-list --count HEAD)" = 1 ] && ok "hook rejects a commit with a pattern word" || bad "hook reject" "rc=$rc $out"
git -C "$r" commit -qm "feat: add support" && ok "hook allows a clean commit" || bad "hook clean" "rejected"
out=$(NO_PROJECT_NAMES_FILE="$tmp/none" git -C "$r" commit -q --allow-empty -m "zorkmid" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q SKIPPED <<<"$out" && ok "hook without a pattern file warns and allows" || bad "hook missing" "rc=$rc $out"
git -C "$r" reset -q --hard HEAD~1

git -C "$r" checkout -qb topic
# fake gh: no PR unless $tmp/pr.json exists
mkdir "$tmp/bin"
printf '#!/bin/sh\n[ -f "%s/pr.json" ] && cat "%s/pr.json" || exit 1\n' "$tmp" "$tmp" >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
cl() { PATH="$tmp/bin:$PATH" bash "$r/script/checks-local.sh" --base main 2>&1; }
echo b >"$r/b.txt"; git -C "$r" add -A; git -C "$r" commit -qm "mention plugh" --no-verify
out=$(cl); rc=$?
[ "$rc" -ne 0 ] && grep -q '"plugh"' <<<"$out" && ok "checks-local fails on a bad commit message" || bad "checks-local message" "rc=$rc $out"
git -C "$r" reset -q --soft HEAD~1; git -C "$r" commit -qm "clean message"
echo "the zorkmid file" >"$r/c.txt"; git -C "$r" add -A; git -C "$r" commit -qm "add c"
out=$(cl); rc=$?
[ "$rc" -ne 0 ] && grep -q "c.txt:1:" <<<"$out" && ok "checks-local fails on a bad changed file" || bad "checks-local file" "rc=$rc $out"
git -C "$r" reset -q --hard HEAD~1
printf '{"title":"feat: zorkmid","body":"fine"}' >"$tmp/pr.json"
out=$(cl); rc=$?
[ "$rc" -ne 0 ] && grep -q "pr-title.txt:1:" <<<"$out" && ok "checks-local fails on a bad PR title" || bad "checks-local pr title" "rc=$rc $out"
printf '{"title":"feat: ok","body":"line\\nnotes on plugh"}' >"$tmp/pr.json"
out=$(cl); rc=$?
[ "$rc" -ne 0 ] && grep -q "pr-body.txt:2:" <<<"$out" && ok "checks-local fails on a bad PR body" || bad "checks-local pr body" "rc=$rc $out"
rm "$tmp/pr.json"
out=$(NO_PROJECT_NAMES_FILE="$tmp/none" cl); rc=$?
[ "$rc" -ne 0 ] && grep -q "pattern file missing" <<<"$out" && ok "checks-local fails when the pattern file is missing" || bad "checks-local missing" "rc=$rc $out"

# ship.sh refuses a PR title or body
# shellcheck disable=SC1091
. "$here/tests/lib/merge-fixture.sh"
mf_setup
trap 'mf_teardown; rm -rf "$tmp"' EXIT
cd "$MF_REPO" || exit 1
mf_pr_add 1 feat-title "Body"
jq '.title = "feat: zorkmid thing"' "$MF_GH_DIR/pr-1.json" >"$MF_GH_DIR/p.tmp" && mv "$MF_GH_DIR/p.tmp" "$MF_GH_DIR/pr-1.json"
out=$(bash "$here/ship.sh" --repo example/repo --pr 1 --dry-run 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q "pr-1-title.txt:1:" <<<"$out" && ok "ship refuses a PR title with a pattern word" || bad "ship title" "rc=$rc $out"
mf_pr_add 2 feat-body "Notes about plugh"
out=$(bash "$here/ship.sh" --repo example/repo --pr 2 --dry-run 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q "pr-2-body.txt:1:" <<<"$out" && ok "ship refuses a PR body with a pattern word" || bad "ship body" "rc=$rc $out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
