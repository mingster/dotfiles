#!/usr/bin/env bash
# setup-orca.sh links presets.json once, backs up a different file once, and is idempotent on re-run.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
export HOME="$tmp/home"; DOTFILES="$tmp/dotfiles"; export DOTFILES
mkdir -p "$HOME" "$DOTFILES/.orca"
echo '{"a":1}' >"$DOTFILES/.orca/presets.json"
dest="$HOME/.orca/presets.json"
run() { bash "$here/setup-orca.sh" 2>&1; }
baks() { find "$HOME/.orca" -name 'presets.json.bak-*' | wc -l | tr -d ' '; }

out=$(run) || fail "run 1"
[ -L "$dest" ] && [ "$dest" -ef "$DOTFILES/.orca/presets.json" ] || fail "run 1 did not link"
out=$(run) || fail "run 2"
case "$out" in *"already linked"*) ;; *) fail "run 2 missing 'already linked': $out" ;; esac
[ "$(baks)" = 0 ] || fail "run 2 created a backup"
[ "$dest" -ef "$DOTFILES/.orca/presets.json" ] || fail "run 2 changed the link"

rm "$dest"; echo '{"mine":true}' >"$dest"
run >/dev/null || fail "run 3"
[ "$(baks)" = 1 ] || fail "expected one backup, got $(baks)"
grep -q mine "$HOME"/.orca/presets.json.bak-* || fail "backup lost user content"
[ -L "$dest" ] && [ "$dest" -ef "$DOTFILES/.orca/presets.json" ] || fail "run 3 did not link"
run >/dev/null || fail "run 4"
[ "$(baks)" = 1 ] || fail "re-run made another backup"
echo "ok: setup-orca"
