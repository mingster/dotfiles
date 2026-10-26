#!/usr/bin/env bash
# Tests for bun-pin-check.sh with a fake runner and fake bun (no network). bash 3.2 compatible.
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#!/usr/bin/env bash\necho "${FAKE_HOST_BUN:-}"\n' > "$tmp/run"   # called as: run <host> bun --version
printf '#!/usr/bin/env bash\necho "${FAKE_LOCAL_BUN:-1.4.0}"\n' > "$tmp/bun"
chmod +x "$tmp/run" "$tmp/bun"
export BUN_PIN_RUN="$tmp/run" PATH="$tmp:$PATH"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
repo() { rm -rf "$tmp/r"; mkdir -p "$tmp/r/web"; [ -z "${2:-}" ] || echo "$2" > "$tmp/r/$1"; }
warn() { "$here/bun-pin-check.sh" remote1 "$tmp/r" 2>&1; }

repo package.json '{"packageManager":"bun@1.4.2"}'
out=$(FAKE_HOST_BUN=1.3.9 warn); rc=$?
check "older than pin: one warning naming host, version and pin" "$([ $rc = 0 ] && [ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] && echo "$out" | grep -q 'remote1 has bun 1.3.9, older than the repo pin 1.4.2'; echo $?)"
out=$(FAKE_HOST_BUN=1.4.2 warn); check "equal to pin: silent" "$([ -z "$out" ]; echo $?)"
out=$(FAKE_HOST_BUN=1.10.0 warn); check "newer than pin (1.10 > 1.4): silent" "$([ -z "$out" ]; echo $?)"

repo package.json '{"engines":{"bun":">=1.4.0"}}'
out=$(FAKE_HOST_BUN=1.3.9 warn); check "engines.bun is read as the pin" "$(echo "$out" | grep -q 'pin 1.4.0'; echo $?)"
repo web/package.json '{"packageManager":"bun@1.5.0+abc"}'
out=$(FAKE_HOST_BUN=1.4.9 warn); check "pin falls back to web/package.json (build suffix ignored)" "$(echo "$out" | grep -q 'pin 1.5.0'; echo $?)"
repo package.json '{"packageManager":"bun@1.4.2"}'; echo '{"packageManager":"bun@9.0.0"}' > "$tmp/r/web/package.json"
out=$(FAKE_HOST_BUN=1.4.2 warn); check "root pin wins over web/" "$([ -z "$out" ]; echo $?)"

repo package.json '{"name":"x"}'
out=$(FAKE_HOST_BUN=1.3.9 FAKE_LOCAL_BUN=1.4.0 warn); check "no pin, host differs from this machine: warns" "$(echo "$out" | grep -q 'no pin'; echo $?)"
out=$(FAKE_HOST_BUN=1.4.0 FAKE_LOCAL_BUN=1.4.0 warn); check "no pin, host equals this machine: silent" "$([ -z "$out" ]; echo $?)"
repo; out=$(FAKE_HOST_BUN=1.3.9 FAKE_LOCAL_BUN=1.4.0 warn); check "no package.json counts as no pin" "$(echo "$out" | grep -q 'no pin'; echo $?)"

repo package.json '{"packageManager":"bun@1.4.2"}'
out=$(FAKE_HOST_BUN= warn); rc=$?; check "unreadable host version: warns, exit 0" "$([ $rc = 0 ] && echo "$out" | grep -q 'cannot read bun version'; echo $?)"
check "--version prints the host version" "$([ "$(FAKE_HOST_BUN=v1.3.9 "$here/bun-pin-check.sh" --version remote1)" = 1.3.9 ]; echo $?)"
"$here/bun-pin-check.sh" >/dev/null 2>&1; check "bad usage exits 2" "$([ $? = 2 ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
