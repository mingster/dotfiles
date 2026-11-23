#!/usr/bin/env bash
# setup-claude-desktop.sh keeps machine-local keys and refuses an invalid destination (#1525).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tests=0

# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Linux branch with a temp HOME so the real Claude Desktop config is never touched.
export HOME="$tmp/home"
unset XDG_CONFIG_HOME
support="$HOME/.config/Claude"
mkdir -p "$support" "$tmp/dotfiles/init"
cp "$root/init/claude_desktop_config.json" "$root/init/claude_config.json" "$tmp/dotfiles/init/"
run() { DOTFILES="$tmp/dotfiles" OSTYPE=linux-gnu bash "$root/script/setup-claude-desktop.sh" 2>&1; }

# Valid destination: tracked keys merge in, the machine-local key stays.
printf '{"preferences":{"localAgentModeTrustedFolders":["/zzz"]}}\n' >"$support/claude_desktop_config.json"
run >/dev/null || fail "valid merge exited non-zero: $(run || true)"
python3 - "$support/claude_desktop_config.json" <<'PY' || fail 'merge lost the local key or the tracked key'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["preferences"]["localAgentModeTrustedFolders"] == ["/zzz"]
assert d["preferences"]["sidebarMode"] == "chat"
PY
tests=$((tests + 1))

# Invalid destination: non-zero exit, names the file, file untouched.
bad='{"preferences":{"localAgentModeTrustedFolders":["/zzz"]},'
printf '%s' "$bad" >"$support/claude_desktop_config.json"
if out=$(run); then fail 'invalid desktop config exited 0'; fi
[[ "$out" == *claude_desktop_config.json* ]] || fail "message does not name the file: $out"
[[ "$(cat "$support/claude_desktop_config.json")" == "$bad" ]] || fail 'invalid desktop config was rewritten'
tests=$((tests + 1))

# Same for config.json.
printf '{"preferences":{"localAgentModeTrustedFolders":["/zzz"]}}\n' >"$support/claude_desktop_config.json"
printf '{"oauth:tokenCache": "x",' >"$support/config.json"
if out=$(run); then fail 'invalid config.json exited 0'; fi
[[ "$out" == *config.json* ]] || fail "message does not name config.json: $out"
[[ "$(cat "$support/config.json")" == '{"oauth:tokenCache": "x",' ]] || fail 'invalid config.json was rewritten'
tests=$((tests + 1))

# A path with a double quote must not break the script.
q="$tmp/do\"tfiles"
mkdir -p "$q/init"
cp "$root/init/"claude_*config.json "$q/init/"
printf '{}\n' >"$support/config.json"
DOTFILES="$q" OSTYPE=linux-gnu bash "$root/script/setup-claude-desktop.sh" >/dev/null 2>&1 || fail 'quoted path broke the script'
tests=$((tests + 1))

printf 'PASS: %s tests\n' "$tests"
