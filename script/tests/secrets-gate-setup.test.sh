#!/usr/bin/env bash
# Tests for script/secrets-gate-setup.sh. A fake sudo logs every privileged command and runs none of them
# (except copying an installed file into a capture folder), so nothing here touches root files, a real
# folder or the real /opt.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/script/secrets-gate-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$TMP/bin" "$TMP/home/cred" "$TMP/pam" "$TMP/captured"
printf 'fake\n' >"$TMP/home/cred/a.key"
printf '{"dir":"~/cred","hosts":["hostA","hostB"]}\n' >"$TMP/sync.json"

# fake sudo: log the command, say "differs" for cmp so every step acts, copy what `install` would put in place
printf '%s\n' '#!/bin/sh' \
  "echo \"\$*\" >>\"$TMP/sudo.log\"" \
  '[ "$1" = cmp ] && exit 1' \
  'if [ "$1" = install ]; then' \
  '  for a in "$@"; do prev=$cur; cur=$a; done' \
  "  cp \"\$prev\" \"$TMP/captured/\$(basename \"\$cur\")\"" \
  'fi' \
  'exit 0' >"$TMP/bin/sudo"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$TMP/bin/visudo"
chmod +x "$TMP/bin/sudo" "$TMP/bin/visudo"

run() {
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" \
    SG_GATE_DIR="$TMP/opt" SG_SUDOERS_FILE="$TMP/sudoers" SG_PAM_DIR="$TMP/pam" bash "$SETUP" "$@"
}

# Dry run: prints the plan, runs no sudo, changes nothing
out=$(run --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "dry run exits 0"; else bad "dry run rc $rc: $out"; fi
if [ ! -e "$TMP/sudo.log" ]; then ok "dry run ran no sudo"; else bad "dry run called sudo: $(cat "$TMP/sudo.log")"; fi
if [ ! -e "$TMP/opt" ] && [ ! -e "$TMP/sudoers" ] && [ -z "$(ls "$TMP/captured")" ]; then ok "dry run created nothing"; else bad "dry run created files"; fi
for want in "would: create $TMP/opt" "would: install the gate" "would: write the config" "would: hand the folder to root" \
            "would: folder mode 700" "would: install the sudoers entry (role source)" "dry run: nothing changed"; do
  if grep -qF "$want" <<<"$out"; then ok "dry run says: $want"; else bad "dry run lacks: $want"; fi
done
if [ "$(uname -s)" = Darwin ]; then
  if grep -qF "would: enable Touch ID for sudo" <<<"$out"; then ok "dry run says: enable Touch ID"; else bad "dry run lacks the Touch ID step"; fi
fi

# Real run with the fake sudo: the exact privileged commands, nothing else
out=$(run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "run exits 0"; else bad "run rc $rc: $out"; fi
log=$(cat "$TMP/sudo.log" 2>/dev/null)
if grep -qE "^chown -R root:[A-Za-z]+ $TMP/home/cred\$" <<<"$log"; then ok "chown root on the folder"; else bad "no chown: $log"; fi
if grep -qF "chmod 700 $TMP/home/cred" <<<"$log"; then ok "mode 700 on the folder"; else bad "no chmod 700"; fi
if grep -qF "chmod -R go-rwx $TMP/home/cred" <<<"$log"; then ok "group and other removed"; else bad "no go-rwx"; fi
if grep -qE "^install .* $TMP/opt/secrets-gate\$" <<<"$log"; then ok "gate installed into the gate dir"; else bad "gate not installed"; fi
if ! grep -qE "^(rm|cat|cp|mv|tee|rsync) " <<<"$log"; then ok "no read, copy or delete under sudo"; else bad "unexpected sudo command: $log"; fi

# The installed config carries the folder and hosts
conf="$TMP/captured/secrets-gate.conf"
if grep -qx "DIR=$TMP/home/cred" "$conf" && grep -qx "HOSTS=hostA hostB" "$conf" && grep -qx "REL=cred" "$conf"; then
  ok "config has folder, hosts and relative path"; else bad "config: $(cat "$conf" 2>/dev/null)"; fi

# The generated sudoers file: one passwordless entry, the fixed sync only
sud="$TMP/captured/sudoers"
if [ "$(grep -c NOPASSWD "$sud")" -eq 1 ]; then ok "role source: one passwordless entry"; else bad "entries: $(cat "$sud")"; fi
if grep -qE "NOPASSWD: $TMP/opt/secrets-gate sync\$" "$sud"; then ok "the entry is the fixed sync only"; else bad "entry: $(cat "$sud")"; fi
if ! grep -qE "NOPASSWD: ALL|\*" "$sud"; then ok "no wildcard or ALL for source"; else bad "wildcard present"; fi
rm -f "$sud"
run --role receiver >/dev/null 2>&1
if grep -qE "NOPASSWD: $TMP/opt/secrets-gate receive --server \*\$" "$sud"; then ok "role receiver: receive --server entry"; else bad "receiver entry: $(cat "$sud" 2>/dev/null)"; fi
if ! grep -qE "secrets-gate sync\$" "$sud"; then ok "receiver has no sync entry"; else bad "receiver got sync"; fi

# Idempotent: a folder that is already root 700 is not touched again (stat shim reports it)
printf '%s\n' '#!/bin/sh' \
  'case "$*" in *cred*) echo "root 700" ;; *) exec /usr/bin/stat "$@" ;; esac' >"$TMP/bin/stat"
chmod +x "$TMP/bin/stat"
rm -f "$TMP/sudo.log"
out=$(run --dry-run 2>&1)
if grep -qF "ok:    $TMP/home/cred is root owned, mode 700" <<<"$out" || grep -qF "root owned, mode 700" <<<"$out"; then ok "folder already locked is skipped"; else bad "not skipped: $out"; fi
rm -f "$TMP/bin/stat"

# Bad input
out=$(run --role boss 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown role is refused"; else bad "role rc $rc"; fi
out=$(HOME="$TMP/home" SECRETS_SYNC_CONFIG="$TMP/none.json" bash "$SETUP" --dry-run 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then ok "no folder is an error"; else bad "no folder accepted: $out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
