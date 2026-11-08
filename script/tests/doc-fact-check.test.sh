#!/usr/bin/env bash
# Tests for script/doc-fact-check.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
check="$here/doc-fact-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

git -C "$tmp" init -q
git -C "$tmp" config user.email fixture@example.invalid
git -C "$tmp" config user.name fixture
printf 'alpha\nkeep\nbeta\n' > "$tmp/README.md"
mkdir -p "$tmp/docs"
printf '# Guide\nunique-keepers\n' > "$tmp/docs/guide.md"
git -C "$tmp" add .
git -C "$tmp" commit -qm base
base=$(git -C "$tmp" rev-parse HEAD)

printf 'alpha\nmoved-keepers\nbeta\n' > "$tmp/README.md"
printf '# Guide\nunique-keepers\nkeep\n' > "$tmp/docs/guide.md"
git -C "$tmp" add .
git -C "$tmp" commit -qm head
head=$(git -C "$tmp" rev-parse HEAD)

set +e
out=$(bash "$check" --repo "$tmp" --base "$base" --head "$head" 2>&1)
ec=$?
set -e
[ "$ec" -eq 0 ] && [ -z "$out" ] && ok "reworded line still in corpus" || bad "reworded pass ec=$ec out=$out"

git -C "$tmp" checkout -q "$base"
printf 'alpha\nFACT-760-ORPHAN\nbeta\n' > "$tmp/README.md"
git -C "$tmp" add README.md
git -C "$tmp" commit -qm orphan
head_orphan=$(git -C "$tmp" rev-parse HEAD)
printf 'alpha\nbeta\n' > "$tmp/README.md"
git -C "$tmp" add README.md
git -C "$tmp" commit -qm drop
head2=$(git -C "$tmp" rev-parse HEAD)
set +e
out=$(bash "$check" --repo "$tmp" --base "$head_orphan" --head "$head2" -- README.md 2>&1)
ec=$?
set -e
[ "$ec" -eq 1 ] && grep -q 'FACT-760-ORPHAN' <<<"$out" && ok "removed orphan line flagged" || bad "orphan line ec=$ec out=$out"

echo "doc-fact-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
