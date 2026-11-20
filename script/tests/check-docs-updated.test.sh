#!/usr/bin/env bash
# check-docs-updated.sh: a script change needs a doc or a `Docs: none, <reason>` body line.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-docs-updated.sh"
passed=0 failed=0

# expect <pass|fail> <name> <body> <file>...
expect() {
  local want=$1 name=$2 body=$3 got=pass out
  shift 3
  out=$(bash "$check" --body "$body" "$@" 2>&1) || got=fail
  if [ "$got" = "$want" ]; then passed=$((passed + 1)); echo "ok   $name"
  else failed=$((failed + 1)); echo "FAIL $name (wanted $want)"; echo "$out"; fi
}

expect pass "script change with a doc" "" script/foo.sh docs/agents/foo.md
expect pass "script change with README" "" script/foo.sh README.md
expect pass "script change with release notes" "" script/foo.sh RELEASE-NOTES.md
expect pass "script change with a .md beside it" "" script/foo.py script/NOTES.md
expect pass "template change with a template .md" "" templates/agent-team/x.sh templates/agent-team/docs/agents/team.md
expect fail "script change without a doc" "" script/foo.sh
expect fail "script change with a .md elsewhere in script" "" script/foo.sh script/tests/NOTES.md
expect fail "template change without a doc" "" templates/agent-team/x.sh
expect fail "script change with only a changelog.d fragment" "" script/foo.sh changelog.d/1-foo.md
expect fail "script change with only CHANGELOG.md" "" script/foo.sh CHANGELOG.md
expect pass "Docs: none with a reason" $'Intro\nDocs: none, internal refactor' script/foo.sh
expect fail "Docs: none without a reason" "Docs: none," script/foo.sh
expect fail "Docs: none not at line start" "see Docs: none, x" script/foo.sh
expect pass "docs only" "" docs/agents/foo.md
expect pass "no files" ""
expect pass "unrelated paths" "" .github/workflows/x.yml

# --base and --head read the git diff.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q -b main
git -C "$tmp" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m base
git -C "$tmp" checkout -q -b topic
mkdir -p "$tmp/script"; echo x >"$tmp/script/a.sh"
git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@example.invalid -c user.name=t commit -qm change
if (cd "$tmp" && bash "$check" --base main --head topic --body "" >/dev/null 2>&1); then
  failed=$((failed + 1)); echo "FAIL --base/--head script change without doc"
else passed=$((passed + 1)); echo "ok   --base/--head script change without doc fails"; fi
mkdir -p "$tmp/docs"; echo y >"$tmp/docs/a.md"
git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@example.invalid -c user.name=t commit -qm doc
if (cd "$tmp" && bash "$check" --base main --head topic --body "" >/dev/null 2>&1); then
  passed=$((passed + 1)); echo "ok   --base/--head with a doc passes"
else failed=$((failed + 1)); echo "FAIL --base/--head with a doc"; fi

echo "passed $passed, failed $failed"
[ "$failed" -eq 0 ]
