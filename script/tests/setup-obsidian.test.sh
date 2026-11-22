#!/usr/bin/env bash
# script/setup-obsidian.sh with a temp HOME and stubbed installers (refs #1475).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../setup-obsidian.sh"
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass + 1)); echo "ok   $DESC"; else fail=$((fail + 1)); echo "FAIL $DESC"; fi; }

home="$tmp/home" stub="$tmp/stub"
mkdir -p "$home" "$stub"
for tool in brew yay; do printf '#!/bin/sh\nexit 0\n' >"$stub/$tool"; done
printf '#!/bin/sh\n[ "$1" = "-m" ] && echo arm64 || echo Darwin\n' >"$stub/uname"
printf '#!/bin/sh\necho tester\n' >"$stub/mega-whoami"
printf '#!/bin/sh\necho "%s/Documents/Obsidian"\n' "$home" >"$stub/mega-sync"
printf '#!/bin/sh\nexit 0\n' >"$stub/mcp-obsidian"
chmod +x "$stub"/*

run() { env HOME="$home" PATH="$stub:$PATH" bash "$script" >"$tmp/out" 2>&1; }
settings="$home/.claude/settings.local.json"
vault="$home/Documents/Obsidian"

mkdir -p "$home/.claude" "$vault/notes"
echo "keep me" >"$vault/notes/a.md"
cat >"$settings" <<'JSON'
{
  "permissions": {"allow": ["Bash(ls)"]},
  "mcpServers": {"other": {"command": "x", "args": ["y"]}}
}
JSON

DESC="first run exits 0"
run; check test $? -eq 0

DESC="unrelated keys survive"
check python3 - "$settings" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
ok = c["permissions"] == {"allow": ["Bash(ls)"]} and c["mcpServers"]["other"] == {"command": "x", "args": ["y"]}
sys.exit(0 if ok else 1)
PY

DESC="one obsidian entry points at the vault"
check python3 - "$settings" "$vault" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["mcpServers"]["obsidian"]
sys.exit(0 if e["args"] == [sys.argv[2]] and e["command"].endswith("mcp-obsidian") else 1)
PY

cp "$settings" "$tmp/first.json"
DESC="second run exits 0"
run; check test $? -eq 0
DESC="second run leaves settings.local.json byte identical"
check cmp -s "$settings" "$tmp/first.json"

DESC="existing vault content is not emptied"
check test "$(cat "$vault/notes/a.md")" = "keep me"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
