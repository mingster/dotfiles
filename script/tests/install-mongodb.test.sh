#!/usr/bin/env bash
# mac/install_mongodb.sh adds the replication block once, however often it runs (#1453).
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1"; exit 1; }
mkdir -p "$tmp/bin"
for c in brew mongosh mongod; do printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done
conf="$tmp/mongod.conf"
printf 'systemLog:\n  path: /tmp/x.log\n' >"$conf"
run() { PATH="$tmp/bin:$PATH" MONGOD_CONF="$conf" bash "$root/mac/install_mongodb.sh" >/dev/null 2>&1; }

run || fail "run 1"
run || fail "run 2"
[ "$(grep -c '^replication:' "$conf")" = 1 ] || fail "expected one replication: line, got $(grep -c '^replication:' "$conf")"
[ "$(grep -c 'replSetName' "$conf")" = 1 ] || fail "expected one replSetName line"
echo "ok: install_mongodb"
