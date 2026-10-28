#!/usr/bin/env bash
# Tests for worktree-setup.sh: a stale worktree reaches origin/main, the main checkout stays untouched,
# and the install runs only when node_modules is missing.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../worktree-setup.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "$*" >> "$BUN_LOG"\nmkdir -p node_modules\n' > "$tmp/bin/bun"
chmod +x "$tmp/bin/bun"
export BUN_LOG="$tmp/bun.log" PATH="$tmp/bin:$PATH"

g() { git -C "$1" "${@:2}" >/dev/null; }
git init -q -b main "$tmp/origin"
echo '{}' > "$tmp/origin/package.json"; g "$tmp/origin" add -A; g "$tmp/origin" commit -qm one
git clone -q "$tmp/origin" "$tmp/main"
echo two > "$tmp/origin/f"; g "$tmp/origin" add -A; g "$tmp/origin" commit -qm two
new=$(git -C "$tmp/origin" rev-parse HEAD)
echo dirty > "$tmp/main/package.json"   # dirty, stale main checkout
before=$(git -C "$tmp/main" rev-parse HEAD)
# Orca creates the worktree from the stale origin/main.
git -C "$tmp/main" worktree add -q "$tmp/wt" -b w origin/main

: > "$BUN_LOG"
(cd "$tmp/wt" && bash "$script") && ok || bad "hook exits 0"
[ "$(git -C "$tmp/wt" rev-parse HEAD)" = "$new" ] && ok || bad "worktree reaches fresh origin/main"
[ "$(git -C "$tmp/main" rev-parse HEAD)" = "$before" ] && ok || bad "main checkout HEAD unchanged"
[ "$(cat "$tmp/main/package.json")" = dirty ] && ok || bad "dirty main file untouched"
[ "$(wc -l < "$BUN_LOG" | tr -d ' ')" = 1 ] && ok || bad "install ran once"

# node_modules present: no second install
(cd "$tmp/wt" && bash "$script") && ok || bad "second run exits 0"
[ "$(wc -l < "$BUN_LOG" | tr -d ' ')" = 1 ] && ok || bad "no install when node_modules exists"

# a worktree with its own commit is not moved
echo mine > "$tmp/wt/mine"; g "$tmp/wt" add -A; g "$tmp/wt" commit -qm mine
echo three > "$tmp/origin/f"; g "$tmp/origin" commit -qam three
mine=$(git -C "$tmp/wt" rev-parse HEAD)
(cd "$tmp/wt" && bash "$script") && ok || bad "diverged run exits 0"
[ "$(git -C "$tmp/wt" rev-parse HEAD)" = "$mine" ] && ok || bad "own commits kept"

echo "worktree-setup: $pass passed, $fail failed"
[ "$fail" = 0 ]
