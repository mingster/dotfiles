#!/usr/bin/env bash
# grok-trust.sh writes a trusted folder entry once (#1312).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/wt1" "$tmp/wt2"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

export GROK_HOME=$tmp/grok
bash "$here/../grok-trust.sh" "$tmp/wt1" >/dev/null || bad "first run failed"
real=$(cd "$tmp/wt1" && pwd -P)
grep -qxF "[folders.\"$real\"]" "$GROK_HOME/trusted_folders.toml" && ok "entry written" || bad "entry missing"
bash "$here/../grok-trust.sh" "$tmp/wt1" "$tmp/wt2" >/dev/null || bad "second run failed"
[ "$(grep -c "^\[folders" "$GROK_HOME/trusted_folders.toml")" = 2 ] && ok "idempotent, second folder added" || bad "duplicate or missing entry"
bash "$here/../grok-trust.sh" "$tmp/nope" >/dev/null 2>&1 && bad "missing dir accepted" || ok "missing dir refused"
exit $fail
