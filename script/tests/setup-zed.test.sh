#!/usr/bin/env bash
# setup-zed.sh links settings.json once and is idempotent on re-run.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
export HOME="$tmp/home"; DOTFILES="$tmp/dotfiles"; export DOTFILES
unset XDG_CONFIG_HOME
mkdir -p "$HOME" "$DOTFILES/ide/zed" "$tmp/bin"
echo '{}' >"$DOTFILES/ide/zed/settings.json"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/zed"; chmod +x "$tmp/bin/zed"
dest="$HOME/.config/zed/settings.json"
run() { PATH="$tmp/bin:$PATH" bash "$here/setup-zed.sh" 2>&1; }

out=$(run) || fail "run 1"
case "$out" in *skipping*) fail "run 1 skipped: $out" ;; esac
[ -L "$dest" ] && [ "$dest" -ef "$DOTFILES/ide/zed/settings.json" ] || fail "run 1 did not link"
before=$(readlink "$dest")
run >/dev/null || fail "run 2"
[ "$(readlink "$dest")" = "$before" ] || fail "run 2 changed the link"
[ "$(find "$HOME/.config/zed" -type f -o -type l | wc -l | tr -d ' ')" = 1 ] || fail "extra files created"
echo "ok: setup-zed"
