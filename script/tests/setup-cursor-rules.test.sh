#!/usr/bin/env bash
# setup-cursor.sh: ~/.cursor/rules ends up a link to the dotfiles rules for a missing path, an existing link and a real folder (backed up, never nested).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$here/script/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

df="$tmp/dotfiles"
mkdir -p "$df/script/lib" "$df/ide/cursor/rules" "$tmp/bin"
cp "$here/script/setup-cursor.sh" "$df/script/"
cp "$here/script/lib/dotfiles-source.sh" "$df/script/lib/"
ln -s "$(command -v id)" "$tmp/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$df/script/link-cursor-user.sh"
cp "$df/script/link-cursor-user.sh" "$df/script/link-cursor-hooks.sh"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/brew"; printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/cursor"
chmod +x "$tmp/bin/"*
touch "$df/ide/cursor/rules/github.mdc"

run() { HOME="$1" DOTFILES="$df" PATH="$tmp/bin:$PATH" bash "$df/script/setup-cursor.sh" 2>&1; }
linked() { [ -L "$1/.cursor/rules" ] && [ -f "$1/.cursor/rules/github.mdc" ] && [ ! -e "$1/.cursor/rules/rules" ]; }

h1="$tmp/h1"; mkdir -p "$h1"
run "$h1" >/dev/null; check "missing path is linked" "$(linked "$h1" && echo 0 || echo 1)"

h2="$tmp/h2"; mkdir -p "$h2/.cursor"; ln -s "$tmp/elsewhere" "$h2/.cursor/rules"
run "$h2" >/dev/null; check "existing link is repointed" "$(linked "$h2" && echo 0 || echo 1)"

h3="$tmp/h3"; mkdir -p "$h3/.cursor/rules"; echo mine > "$h3/.cursor/rules/mine.mdc"
out=$(run "$h3"); rc=$?
check "real folder: exit 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)"
check "real folder: now a link, not nested" "$(linked "$h3" && echo 0 || echo 1)"
check "real folder: user rule kept in a backup" "$(cat "$h3"/.cursor/rules.bak-*/mine.mdc 2>/dev/null | grep -q mine && echo 0 || echo 1)"
check "real folder: backup is named in the output" "$(echo "$out" | grep -q 'backed up' && echo 0 || echo 1)"

echo "setup-cursor-rules: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
