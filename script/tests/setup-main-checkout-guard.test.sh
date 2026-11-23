#!/usr/bin/env bash
# The nine scripts that wire the live home refuse to run from a linked worktree (#1543).
# Each runs from a worktree's script folder with DOTFILES set to that worktree, the way a
# worker's shell does. The refusal names the main checkout and nothing under the home changes.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

main="$tmp/main"
wt="$tmp/wt"
mkdir -p "$main"
git -C "$main" init -q
echo x >"$main/README"
git -C "$main" add README
git -C "$main" -c user.email=test@example.invalid -c user.name=test commit -qm init
git -C "$main" worktree add -q "$wt" -b guard-test
cp -R "$root/script" "$wt/script"
main_p=$(cd "$main" && pwd -P)
wt_p=$(cd "$wt" && pwd -P)

home="$tmp/home"
mkdir -p "$home"
home_p=$(cd "$home" && pwd -P)

scripts="setup-zed setup-orca setup-grok setup-cursor link-cursor-user link-cursor-hooks setup-vscode setup-antigravity setup-claude-desktop"
for name in $scripts; do
  out=$(HOME="$home" DOTFILES_REAL_HOME="$home" DOTFILES="$wt" bash "$wt/script/$name.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ]; then ok "$name exits 1 from a worktree"; else bad "$name exit $rc from a worktree: $out"; fi
  want="$name: refusing to wire $home from $wt_p; run it from the main checkout $main_p"
  if [ "$out" = "$want" ]; then ok "$name names the main checkout"; else bad "$name message: $out"; fi
  left=$(find "$home" -mindepth 1 | wc -l | tr -d ' ')
  if [ "$left" = 0 ]; then ok "$name wrote nothing under home"; else bad "$name left $left entries under home"; fi
done

# Control: the main checkout (reached as ~/dotfiles) passes the guard and writes its link.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/zed"; chmod +x "$tmp/bin/zed"
ln -s "$main" "$home/dotfiles"
mkdir -p "$main/ide/zed"; echo '{}' >"$main/ide/zed/settings.json"
out=$(HOME="$home" DOTFILES_REAL_HOME="$home" DOTFILES="$home/dotfiles" PATH="$tmp/bin:$PATH" bash "$root/script/setup-zed.sh" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -L "$home/.config/zed/settings.json" ] && ! echo "$out" | grep -q refusing; then
  ok "main checkout passes the guard and links zed settings"
else
  bad "main checkout control: rc=$rc out=$out"
fi

git -C "$main" worktree remove --force "$wt" 2>/dev/null

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
