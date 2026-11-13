#!/usr/bin/env bash
# Behavioral tests for script/secrets-gate.sh against a fake folder in a temp dir. No root, no real credential.
# A fake sudo and a fake ssh stand in for the real ones; rsync is the real one, run between two temp folders.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/script/secrets-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$TMP/home/rel/sub" "$TMP/rhome/rel" "$TMP/bin" "$TMP/outside"
D="$TMP/home/rel"
R="$TMP/rhome/rel"
printf 'fake-value-1\n' >"$D/a.key"
printf 'fake-value-2\n' >"$D/sub/b.key"
printf 'fake-value-3\n' >"$D/c.key"
printf 'outside-value\n' >"$TMP/outside/o.key"
ln -s "$TMP/outside/o.key" "$D/link.key"
ln -s "$TMP/outside" "$D/linkdir"

printf 'DIR=%s\nREL=rel\nOWNER=tester\nHOSTS=hostA\nDEPLOY=a.key\n' "$D" >"$TMP/send.conf"
printf 'DIR=%s\nREL=rel\nOWNER=tester\nHOSTS=\nDEPLOY=\n' "$R" >"$TMP/recv.conf"

# fake sudo: drop -n and "-u user -H", run the rest
printf '%s\n' '#!/bin/sh' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -n) shift ;; -u) shift 2 ;; -H) shift ;; *) break ;; esac' \
  'done' \
  'exec "$@"' >"$TMP/bin/sudo"
# fake ssh: ignore options and host, run the remote command locally as the receiving side
printf '%s\n' '#!/bin/sh' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac' \
  'done' \
  'shift' \
  "HOME=\"$TMP/rhome\" SECRETS_GATE_CONF=\"$TMP/recv.conf\" SECRETS_GATE_SELF=\"$GATE\" exec sh -c \"\$*\"" >"$TMP/bin/ssh"
chmod +x "$TMP/bin/sudo" "$TMP/bin/ssh"

g() { SECRETS_GATE_CONF="$TMP/send.conf" SECRETS_GATE_SELF="$GATE" PATH="$TMP/bin:$PATH" bash "$GATE" "$@"; }
r() { SECRETS_GATE_CONF="$TMP/recv.conf" PATH="$TMP/bin:$PATH" bash "$GATE" receive "$@"; }

LAST_OUT=
# expect_rc <label> <rc> <command...>
expect_rc() {
  local label=$1 want=$2 rc
  shift 2
  LAST_OUT=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$label (rc $rc, want $want: $LAST_OUT)"; else ok "$label"; fi
}

# Fingerprint
expect_rc "fingerprint prints size and fp for a file" 0 g fingerprint a.key
want_fp=$(shasum -a 256 <"$D/a.key" | cut -c1-8)
[[ "$LAST_OUT" == "a.key: not a dotenv file; 13 bytes, fp $want_fp" ]] && ok "fingerprint line is exact" || bad "fingerprint line: $LAST_OUT"
[[ "$LAST_OUT" != *fake-value* ]] && ok "fingerprint never prints content" || bad "fingerprint printed content"
expect_rc "fingerprint takes an absolute path inside the folder" 0 g fingerprint "$D/sub/b.key"
expect_rc "fingerprint refuses dot dot" 2 g fingerprint "sub/../a.key"
expect_rc "fingerprint refuses a path outside the folder" 2 g fingerprint "$TMP/outside/o.key"
expect_rc "fingerprint refuses a symlinked file" 2 g fingerprint link.key
expect_rc "fingerprint refuses a symlinked directory" 2 g fingerprint linkdir/o.key
expect_rc "fingerprint refuses a directory" 2 g fingerprint sub
expect_rc "fingerprint refuses no argument" 2 g fingerprint
expect_rc "fingerprint refuses two arguments" 2 g fingerprint a.key c.key

# Refusals of everything else
expect_rc "no command is refused" 2 g
expect_rc "unknown command is refused" 2 g cat a.key
expect_rc "a shell word is refused" 2 g sh -c 'cat a.key'
expect_rc "list is refused" 2 g ls
expect_rc "copy is refused" 2 g cp a.key "$TMP/x"
[[ ! -e "$TMP/x" ]] && ok "refused copy wrote nothing" || bad "copy wrote a file"

# deploy-read
expect_rc "deploy-read prints a listed file" 0 g deploy-read a.key
[[ "$LAST_OUT" == "fake-value-1" ]] && ok "deploy-read prints that file" || bad "deploy-read output: $LAST_OUT"
expect_rc "deploy-read refuses a file off the list" 2 g deploy-read c.key
expect_rc "deploy-read refuses a path" 2 g deploy-read sub/b.key
expect_rc "deploy-read refuses a dot name" 2 g deploy-read ..
expect_rc "deploy-read refuses no name" 2 g deploy-read

# sync: real rsync from the folder into the receiving folder, through the fake ssh and the gate's receive
expect_rc "sync unknown flag is refused" 2 g sync --exclude x
rm "$D/link.key"
expect_rc "sync pushes the folder" 0 g sync
sync_out=$LAST_OUT
[[ -f "$R/a.key" && -f "$R/sub/b.key" ]] && ok "sync copied the files" || bad "sync copied nothing: $sync_out"
[[ "$(stat -f %Lp "$R/a.key" 2>/dev/null || stat -c %a "$R/a.key")" == 600 ]] && ok "fleet copy files are 600" || bad "fleet copy mode"
[[ "$sync_out" != *fake-value* ]] && ok "sync output has no content" || bad "sync printed content"
[[ "$sync_out" == *a.key* ]] && ok "sync output lists changed names" || bad "sync output has no names: $sync_out"
printf 'changed\n' >"$D/a.key"
expect_rc "sync dry run succeeds" 0 g sync --dry-run
[[ "$(cat "$R/a.key")" == fake-value-1 ]] && ok "dry run changed nothing" || bad "dry run wrote"
printf 'stale\n' >"$R/stale.key"
expect_rc "sync --delete removes what the source lacks" 0 g sync --delete
[[ ! -e "$R/stale.key" ]] && ok "stale file removed" || bad "stale file kept"
mkdir -p "$TMP/few"
printf 'x\n' >"$TMP/few/only.key"
sed "s#^DIR=.*#DIR=$TMP/few#" "$TMP/send.conf" >"$TMP/few.conf"
expect_rc "sync --delete refuses a source with under 3 files" 1 env SECRETS_GATE_CONF="$TMP/few.conf" PATH="$TMP/bin:$PATH" bash "$GATE" sync --delete

# receive: only the server side, only the configured folder
expect_rc "receive without --server is refused" 2 r -a . "$R/"
expect_rc "receive to another folder is refused" 2 r --server -vlogDtpre.iLsfxCIvu . "$TMP/outside/"
expect_rc "receive with a path option is refused" 2 r --server --log-file=/tmp/x -vlogDtpre.iLsfxCIvu . "$R/"
expect_rc "receive with another long option is refused" 2 r --server --rsh=sh . "$R/"
expect_rc "receive with a source other than dot is refused" 2 r --server -vlogDtpre.iLsfxCIvu "$TMP/outside" "$R/"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
