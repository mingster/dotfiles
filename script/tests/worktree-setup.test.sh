#!/usr/bin/env bash
# Tests for worktree-setup.sh: a stale worktree reaches origin/main, the main checkout stays untouched,
# and the install runs only when node_modules is missing.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
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
export DOTFILES="$tmp/dotfiles"
mkdir -p "$DOTFILES/script"
cp "$script" "$DOTFILES/script/worktree-setup.sh"
cp "$here/../link-agent-team-roles.sh" "$DOTFILES/script/link-agent-team-roles.sh"
chmod +x "$DOTFILES/script/link-agent-team-roles.sh"
mkdir -p "$DOTFILES/templates/agent-team/.claude/agents"
for r in elon architect-pm fullstack-dev qa-sdet release-manager sales-marketing secops-finops support-csm; do
  printf 'role\n' > "$DOTFILES/templates/agent-team/.claude/agents/$r.md"
done
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
(cd "$tmp/wt" && bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "hook exits 0"
[ "$(git -C "$tmp/wt" rev-parse HEAD)" = "$new" ] && ok || bad "worktree reaches fresh origin/main"
[ "$(git -C "$tmp/main" rev-parse HEAD)" = "$before" ] && ok || bad "main checkout HEAD unchanged"
[ "$(cat "$tmp/main/package.json")" = dirty ] && ok || bad "dirty main file untouched"
[ "$(wc -l < "$BUN_LOG" | tr -d ' ')" = 1 ] && ok || bad "install ran once"

mkdir -p "$tmp/wt/docs/agents" "$tmp/home"
printf 'facts\n' > "$tmp/wt/docs/agents/team-facts.md"
ln -snf "$DOTFILES" "$tmp/home/dotfiles"
(cd "$tmp/wt" && HOME="$tmp/home" bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "team link run exits 0"
[ -L "$tmp/wt/.claude/agents/elon.md" ] && ok || bad "links roles when team-facts exists"

# checkout with eight regular role files: setup must exit 0, leave git clean, not touch roles
git -C "$tmp/main" worktree add -q "$tmp/wt2" -b w2 origin/main
mkdir -p "$tmp/wt2/docs/agents" "$tmp/wt2/.claude/agents"
printf 'facts\n' > "$tmp/wt2/docs/agents/team-facts.md"
for r in elon architect-pm fullstack-dev qa-sdet release-manager sales-marketing secops-finops support-csm; do
  printf 'tracked-%s\n' "$r" > "$tmp/wt2/.claude/agents/$r.md"
done
git -C "$tmp/wt2" add -A && git -C "$tmp/wt2" commit -qm 'regular roles'
(cd "$tmp/wt2" && HOME="$tmp/home" bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "regular roles: hook exits 0"
[ -z "$(git -C "$tmp/wt2" status --porcelain)" ] && ok || bad "regular roles: git status clean"
for r in elon architect-pm fullstack-dev qa-sdet release-manager sales-marketing secops-finops support-csm; do
  grep -qxF "tracked-$r" "$tmp/wt2/.claude/agents/$r.md" && ok || bad "regular roles: $r unchanged"
done

# node_modules present: no second install (wt2 setup may have installed once)
bun_after_wt2=$(wc -l < "$BUN_LOG" | tr -d ' ')
(cd "$tmp/wt" && HOME="$tmp/home" bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "second run exits 0"
[ "$(wc -l < "$BUN_LOG" | tr -d ' ')" = "$bun_after_wt2" ] && ok || bad "no install when node_modules exists"

# a worktree with its own commit is not moved
echo mine > "$tmp/wt/mine"; g "$tmp/wt" add -A; g "$tmp/wt" commit -qm mine
echo three > "$tmp/origin/f"; g "$tmp/origin" commit -qam three
mine=$(git -C "$tmp/wt" rev-parse HEAD)
(cd "$tmp/wt" && HOME="$tmp/home" bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "diverged run exits 0"
[ "$(git -C "$tmp/wt" rev-parse HEAD)" = "$mine" ] && ok || bad "own commits kept"

# a project in a subfolder (package.json under web/) gets its install there
mkdir "$tmp/wt/web"; echo '{}' > "$tmp/wt/web/package.json"
(cd "$tmp/wt" && HOME="$tmp/home" bash "$DOTFILES/script/worktree-setup.sh") && ok || bad "subfolder run exits 0"
[ -d "$tmp/wt/web/node_modules" ] && ok || bad "install ran in web/"
[ "$(wc -l < "$BUN_LOG" | tr -d ' ')" = $((bun_after_wt2 + 1)) ] && ok || bad "one install for web/"

echo "worktree-setup: $pass passed, $fail failed"
[ "$fail" = 0 ]
