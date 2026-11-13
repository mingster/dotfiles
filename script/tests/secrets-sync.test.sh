#!/usr/bin/env bash
# Tests for script/secrets-sync.sh and the gate fallback in env-peek.py. Fake sudo and a fake gate record
# what they are called with; nothing real is read or run as root.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$ROOT/script/secrets-sync.sh"
PEEK="$ROOT/templates/agent-team/.claude/bin/env-peek.py"
TMP="$(mktemp -d)"
trap 'chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$TMP/bin"
printf '%s\n' '#!/bin/sh' 'echo "FAKEGATE $*"' >"$TMP/gate"
printf '%s\n' '#!/bin/sh' "echo \"sudo \$*\" >>\"$TMP/sudo.log\"" '[ "$1" = -n ] && shift' 'exec "$@"' >"$TMP/bin/sudo"
chmod +x "$TMP/gate" "$TMP/bin/sudo"

# secrets-sync.sh
out=$(SECRETS_GATE="$TMP/missing" bash "$SYNC" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "skipped" <<<"$out"; then ok "no gate installed: skipped, exit 0"; else bad "no gate: rc $rc $out"; fi
out=$(SECRETS_GATE="$TMP/gate" bash "$SYNC" --bogus 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag rc $rc"; fi
out=$(SECRETS_GATE="$TMP/gate" PATH="$TMP/bin:$PATH" bash "$SYNC" 2>&1)
if [ "$out" = "FAKEGATE sync" ] && [ "$(cat "$TMP/sudo.log")" = "sudo -n $TMP/gate sync" ]; then
  ok "plain sync is sudo -n gate sync (the passwordless entry)"; else bad "plain sync: $out / $(cat "$TMP/sudo.log")"; fi
rm -f "$TMP/sudo.log"
out=$(SECRETS_GATE="$TMP/gate" bash "$SYNC" --delete 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "--delete is refused"; else bad "--delete rc $rc"; fi
out=$(SECRETS_GATE="$TMP/gate" PATH="$TMP/bin:$PATH" bash "$SYNC" --dry-run 2>&1)
if [ "$out" = "FAKEGATE sync --dry-run" ] && [ "$(cat "$TMP/sudo.log")" = "sudo $TMP/gate sync --dry-run" ]; then
  ok "flags go through plain sudo (Touch ID)"; else bad "dry run: $out / $(cat "$TMP/sudo.log")"; fi
if ! grep -qE 'rsync|find |jq ' "$SYNC"; then ok "secrets-sync.sh no longer reads the folder itself"; else bad "secrets-sync.sh still touches the folder"; fi

# env-peek.py falls back to the gate when the file cannot be opened
printf 'PLAIN=1\n' >"$TMP/readable.env"
printf 'x\n' >"$TMP/locked"
chmod 000 "$TMP/locked"
peek() { SECRETS_GATE="$1" PATH="$TMP/bin:$PATH" python3 -I "$PEEK" "$2"; }
if [ "$(id -u)" -ne 0 ]; then
  out=$(peek "$TMP/gate" "$TMP/locked" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "FAKEGATE fingerprint $TMP/locked" ]; then ok "unreadable file: fingerprint through the gate"; else bad "gate fallback: rc $rc $out"; fi
  out=$(peek "$TMP/nogate" "$TMP/locked" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grep -q "Permission denied" <<<"$out"; then ok "unreadable file, no gate: permission denied"; else bad "no gate: rc $rc $out"; fi
fi
out=$(peek "$TMP/gate" "$TMP/readable.env" 2>&1)
if [ "$out" = "PLAIN = 1" ]; then ok "readable file never calls the gate"; else bad "readable: $out"; fi
out=$(peek "$TMP/gate" "$TMP/absent" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && ! grep -q FAKEGATE <<<"$out"; then ok "missing file does not call the gate"; else bad "missing: rc $rc $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
