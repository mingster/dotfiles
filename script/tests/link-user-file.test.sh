#!/usr/bin/env bash
# link_user_file backs up a real file once before linking; setup-vscode, setup-antigravity and
# link-cursor-user all use it. A re-run changes nothing (refs #1430).
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }

for s in setup-vscode setup-antigravity link-cursor-user; do
  grep -q 'link_user_file' "$here/$s.sh" || fail "$s does not use link_user_file"
  ! grep -Eq '^[[:space:]]*ln -sfn .*(settings|keybindings)\.json' "$here/$s.sh" || fail "$s still runs a bare ln -sfn on a User file"
done

# Helper alone.
# shellcheck source=../lib/link-user-file.sh
. "$here/lib/link-user-file.sh"
mkdir -p "$tmp/src" "$tmp/dest"
echo new >"$tmp/src/settings.json"
echo mine >"$tmp/dest/settings.json"
link_user_file "$tmp/src/settings.json" "$tmp/dest/settings.json" >/dev/null || fail "helper run 1"
[ -L "$tmp/dest/settings.json" ] && [ "$tmp/dest/settings.json" -ef "$tmp/src/settings.json" ] || fail "helper did not link"
[ "$(find "$tmp/dest" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = 1 ] || fail "expected one backup"
grep -q mine "$tmp"/dest/settings.json.bak.* || fail "backup lost content"
link_user_file "$tmp/src/settings.json" "$tmp/dest/settings.json" >/dev/null || fail "helper run 2"
[ "$(find "$tmp/dest" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = 1 ] || fail "re-run made another backup"

# Real script with a temp HOME and an existing real settings.json.
export HOME="$tmp/home"; export DOTFILES="$root"; unset XDG_CONFIG_HOME
case "$(uname -s)" in
  Darwin) user="$HOME/Library/Application Support/Cursor/User" ;;
  *) user="$HOME/.config/Cursor/User" ;;
esac
mkdir -p "$user"; echo '{"mine":true}' >"$user/settings.json"
bash "$here/link-cursor-user.sh" >/dev/null || fail "link-cursor-user run 1"
[ "$(find "$user" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = 1 ] || fail "cursor: expected one backup"
grep -q mine "$user"/settings.json.bak.* || fail "cursor: backup lost content"
[ -L "$user/settings.json" ] || fail "cursor: settings.json not a link"
bash "$here/link-cursor-user.sh" >/dev/null 2>&1 || fail "link-cursor-user run 2"
[ "$(find "$user" -name '*.bak.*' | wc -l | tr -d ' ')" = 1 ] || fail "cursor: re-run made another backup"
echo "ok: link-user-file"
