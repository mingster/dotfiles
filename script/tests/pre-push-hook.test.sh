#!/usr/bin/env bash
# Tests for .githooks/pre-push: an agent session cannot push to main, a feature branch push passes,
# and a human push to main passes. A merge through script/ship.sh runs no push, so the hook gets no ref lines.
here=$(cd "$(dirname "$0")" && pwd)
hooks="$here/../../.githooks"
ship="$here/../ship.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck source=lib/git-identity.sh
. "$here/lib/git-identity.sh"
use_test_git_identity "$tmp"
# This test may itself run inside an agent session; start every case with no agent markers.
unset CLAUDECODE ORCA_TERMINAL_HANDLE

git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$tmp/work"
git -C "$tmp/work" config core.hooksPath "$hooks"
git -C "$tmp/work" remote add origin "$tmp/origin.git"
echo one > "$tmp/work/f"; git -C "$tmp/work" add f; git -C "$tmp/work" commit -q --no-verify -m one
git -C "$tmp/work" push -q origin main || { echo "setup: initial push failed"; exit 1; }
base=$(git -C "$tmp/work" rev-parse HEAD)
echo two > "$tmp/work/f"; git -C "$tmp/work" commit -q --no-verify -am two
remote_main() { git -C "$tmp/origin.git" rev-parse refs/heads/main; }

# Agent session, push to main: refused, origin unchanged, message points at ship.sh
out=$(CLAUDECODE=1 git -C "$tmp/work" push origin HEAD:main 2>&1); ec=$?
[ "$ec" != 0 ] && ok || bad "agent push to main is refused"
[ "$(remote_main)" = "$base" ] && ok || bad "agent push to main leaves origin main unchanged"
grep -q 'script/ship.sh' <<<"$out" && ok || bad "refusal names script/ship.sh"

# Orca marker alone also counts as an agent session
out=$(ORCA_TERMINAL_HANDLE=term_test git -C "$tmp/work" push origin HEAD:main 2>&1); ec=$?
[ "$ec" != 0 ] && ok || bad "ORCA_TERMINAL_HANDLE agent push to main is refused"

# Staging is protected too, for repos that have that branch
out=$(CLAUDECODE=1 git -C "$tmp/work" push origin HEAD:staging 2>&1); ec=$?
[ "$ec" != 0 ] && ok || bad "agent push to staging is refused"

# Agent session, push to a feature branch: allowed
CLAUDECODE=1 git -C "$tmp/work" push -q origin HEAD:mingster/feature-x 2>/dev/null && ok || bad "agent push to a feature branch is allowed"
[ "$(git -C "$tmp/origin.git" rev-parse refs/heads/mingster/feature-x)" = "$(git -C "$tmp/work" rev-parse HEAD)" ] && ok || bad "feature branch reached origin"

# Human session, push to main: allowed
git -C "$tmp/work" push -q origin HEAD:main 2>/dev/null && ok || bad "human push to main is allowed"
[ "$(remote_main)" = "$(git -C "$tmp/work" rev-parse HEAD)" ] && ok || bad "human push reached origin main"

# ship.sh merge path: merges go through gh pr merge, and the hook sees no ref lines on a merge.
grep -q 'gh pr merge' "$ship" && ok || bad "ship.sh merges with gh pr merge"
! grep -Eq '(^|[^a-z_])git( -C [^ ]+)? push' "$ship" && ok || bad "ship.sh runs no git push"
printf '' | CLAUDECODE=1 bash "$hooks/pre-push" origin "$tmp/origin.git" && ok || bad "agent session with no pushed refs exits 0"

# install.sh wires core.hooksPath for the dotfiles repo
grep -q 'config core.hooksPath .githooks' "$here/../../install.sh" && ok || bad "install.sh sets core.hooksPath"

echo "pre-push-hook: $pass passed, $fail failed"
[ "$fail" = 0 ]
