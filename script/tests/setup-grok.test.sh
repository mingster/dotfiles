#!/usr/bin/env bash
# setup-grok.sh adds missing keys to a grok config and never changes keys the file already has.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
export HOME="$tmp/home"; mkdir -p "$HOME"
# shellcheck source=tests/lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
run() { GROK_CONFIG="$tmp/config.toml" DOTFILES="$here/.." bash "$here/setup-grok.sh" >/dev/null || fail "run"; }
has() { grep -qxF "$1" "$tmp/config.toml" || fail "missing: $1"; }

run
has '[ui]'; has 'kitty_keyboard = "query"'; has '[ui.notifications]'; has 'condition = "always"'

printf '[cli]\nshow_tips = false\n\n[ui]\nyolo = false\nkitty_keyboard = "off"\n\n[models]\ndefault = "x"\n' >"$tmp/config.toml"
run
has 'kitty_keyboard = "off"'; has 'yolo = false'; has 'default = "x"'; has 'condition = "always"'
[ "$(grep -c kitty_keyboard "$tmp/config.toml")" = 1 ] || fail "kitty_keyboard duplicated"
awk '/^\[ui\]/{u=1;next} /^\[/{u=0} u&&/kitty_keyboard/{f=1} END{exit !f}' "$tmp/config.toml" || fail "key outside [ui]"

printf '[ui]\nyolo = false\n\n[ui.notifications]\ncondition = "never"\n' >"$tmp/config.toml"
run
has 'condition = "never"'; has 'kitty_keyboard = "query"'
before=$(cat "$tmp/config.toml"); run
[ "$before" = "$(cat "$tmp/config.toml")" ] || fail "second run changed the file"
echo "ok: setup-grok"
