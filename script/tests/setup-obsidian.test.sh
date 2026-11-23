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

# Intel install: the DMG lives in a temp dir, the volume is detached when the copy fails, an empty URL stops early (#1598).
istub="$tmp/intel-stub" ihome="$tmp/intel-home" apps="$tmp/apps" calls="$tmp/calls"
mkdir -p "$istub" "$ihome" "$apps"
cp "$stub"/* "$istub"/
printf '#!/bin/sh\n[ "$1" = "-m" ] && echo x86_64 || echo Darwin\n' >"$istub/uname"
cat >"$istub/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >>"$CALLS"
case "$*" in
  *api.github.com*) [ -n "${EMPTY_URL:-}" ] || echo '"browser_download_url": "https://example.test/Obsidian.dmg"' ;;
  *) while [ $# -gt 0 ]; do [ "$1" = -o ] && : >"$2"; shift; done ;;
esac
STUB
cat >"$istub/hdiutil" <<'STUB'
#!/bin/sh
echo "hdiutil $*" >>"$CALLS"
if [ "$1" = attach ]; then
  while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mkdir -p "$2/Obsidian.app"; shift; done
fi
exit 0
STUB
printf '#!/bin/sh\necho "cp $*" >>"$CALLS"\nexit 1\n' >"$istub/cp"
chmod +x "$istub"/*
# The script gates on $OSTYPE, which bash sets itself (an env value is ignored), so the Intel
# branch only runs on a real Mac. Set it inside bash and source the script so Linux CI reaches it too.
irun() { : >"$calls"; env HOME="$ihome" PATH="$istub:$PATH" CALLS="$calls" OBSIDIAN_APPLICATIONS_DIR="$apps" "$@" bash -c 'OSTYPE=darwin22.0; . "$1"' _ "$script" >"$tmp/iout" 2>&1; }

DESC="a failing copy stops the script"
irun env; check test $? -ne 0
DESC="a failing copy still detaches the volume it attached"
check grep -q '^hdiutil detach' "$calls"
DESC="the DMG is downloaded to a temp dir, not a fixed /tmp path"
check bash -c "grep -q '^curl .* -o ' '$calls' && ! grep -q -- '-o /tmp/Obsidian.dmg' '$calls' && ! grep -q '/Volumes/Obsidian' '$calls'"
DESC="the temp dir is gone after the failure"
dmg=$(sed -n 's/^curl .* -o \(.*\)$/\1/p' "$calls" | head -1)
check test -n "$dmg" -a ! -e "$dmg"

DESC="an empty download URL stops with a setup-obsidian message"
irun env EMPTY_URL=1; rc=$?
check bash -c "[ $rc -ne 0 ] && grep -q '^setup-obsidian: .*URL' '$tmp/iout'"
DESC="an empty download URL never reaches the download or hdiutil"
check bash -c "! grep -q '^hdiutil' '$calls' && [ \$(grep -c '^curl' '$calls') -eq 1 ]"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
