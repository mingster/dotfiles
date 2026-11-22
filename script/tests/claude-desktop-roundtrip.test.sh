#!/usr/bin/env bash
# backup-claude-desktop.sh and setup-claude-desktop.sh round trip the home path through __HOME__.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
# shellcheck source=lib/asdf-pin.sh
. "$(dirname "$0")/lib/asdf-pin.sh"
export HOME="$tmp/Users/mt"; DOTFILES="$tmp/dotfiles"; export DOTFILES
unset XDG_CONFIG_HOME
mkdir -p "$HOME" "$DOTFILES/init"
case "$OSTYPE" in
  darwin*) support="$HOME/Library/Application Support/Claude"; mkdir -p "$HOME/Applications/Claude.app" ;;
  *) support="$HOME/.config/Claude" ;;
esac
mkdir -p "$support"
live="$support/claude_desktop_config.json"
tracked="$DOTFILES/init/claude_desktop_config.json"
sibling="$tmp/Users/mtx/x"
jq -n --arg h "$HOME" --arg s "$sibling" '{
  coworkUserFilesPath: ($h + "/Claude"), exact: $h, sibling: $s,
  "quote\"d": "a \"b\" c",
  preferences: {sidebarMode: "chat", localAgentModeTrustedFolders: [($h + "/secret")],
    bypassPermissionsGateByAccount: {a: true}, remoteToolsDeviceName: "box", epitaxyPrefs: {x: 1}}}' >"$live"
jq 'del(.preferences.localAgentModeTrustedFolders, .preferences.bypassPermissionsGateByAccount, .preferences.remoteToolsDeviceName, .preferences.epitaxyPrefs)' "$live" >"$tmp/expected.json"

bash "$here/backup-claude-desktop.sh" >"$tmp/out" 2>&1 || fail "backup failed: $(cat "$tmp/out")"
[ "$(jq '.preferences | keys' -c "$tracked")" = '["sidebarMode"]' ] || fail "local keys not stripped: $(jq -c .preferences "$tracked")"
[ "$(jq -r .coworkUserFilesPath "$tracked")" = "__HOME__/Claude" ] || fail "home not replaced"
[ "$(jq -r .exact "$tracked")" = "__HOME__" ] || fail "exact home not replaced"
[ "$(jq -r .sibling "$tracked")" = "$sibling" ] || fail "sibling path rewritten: $(jq -r .sibling "$tracked")"

rm "$live"
bash "$here/setup-claude-desktop.sh" >"$tmp/out" 2>&1 || fail "setup failed: $(cat "$tmp/out")"
[ "$(jq -S . "$live")" = "$(jq -S . "$tmp/expected.json")" ] || fail "restore differs from original"
echo "ok: claude-desktop round trip"
