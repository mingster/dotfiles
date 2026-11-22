#!/usr/bin/env bash
# check-appdir.sh: a clean tree passes; the old folder or --appdir to it fails; the helper, _outdated/ and CHANGELOG.md may name it.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
old="/Applications/""_dev"

repo="$tmp/repo"
mkdir -p "$repo/script/lib" "$repo/_outdated"
git -C "$repo" init -q
echo 'brew install --cask cursor' > "$repo/install.sh"
git -C "$repo" add -A
bash "$here/check-appdir.sh" "$repo" >/dev/null 2>&1
check "a clean tree passes" "$?"

echo "brew install --cask --appdir=$old cursor" > "$repo/bad.sh"
git -C "$repo" add -A
out=$(bash "$here/check-appdir.sh" "$repo" 2>&1)
check "a file with --appdir to the old folder fails" "$([ $? -ne 0 ] && echo 0 || echo 1)"
check "the failure names the file" "$(echo "$out" | grep -q 'bad.sh:1' && echo 0 || echo 1)"
git -C "$repo" rm -qf bad.sh

echo "export PATH=$old/Orca.app/bin:\$PATH" > "$repo/rc"
git -C "$repo" add -A
bash "$here/check-appdir.sh" "$repo" >/dev/null 2>&1
check "a bare path to the old folder fails" "$([ $? -ne 0 ] && echo 0 || echo 1)"
git -C "$repo" rm -qf rc

echo "$old" > "$repo/script/lib/app-path.sh"
echo "$old" > "$repo/_outdated/old.sh"
echo "$old" > "$repo/CHANGELOG.md"
git -C "$repo" add -A
bash "$here/check-appdir.sh" "$repo" >/dev/null 2>&1
check "the helper, _outdated/ and CHANGELOG.md may name it" "$?"

echo "$old" > "$repo/untracked.sh"
bash "$here/check-appdir.sh" "$repo" >/dev/null 2>&1
check "an untracked file is ignored" "$?"

bash "$here/check-appdir.sh" >/dev/null 2>&1
check "this repo passes" "$?"

mkdir -p "$tmp/notgit"
out=$(bash "$here/check-appdir.sh" "$tmp/notgit" 2>&1); rc=$?
check "a dir that is not a git checkout exits 2" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
check "the non-git failure is one line" "$([ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] && echo 0 || echo 1)"

echo "check-appdir: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
