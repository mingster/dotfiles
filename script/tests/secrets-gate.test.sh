#!/usr/bin/env bash
# Behavioral tests for script/secrets-gate.sh against a fake folder in a temp dir. No root, no real credential.
# A fake sudo and a fake ssh stand in for the real ones; rsync is the real one, run between two temp folders.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${SG_TEST_GATE:-$ROOT/script/secrets-gate.sh}"
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
printf 'fake-key\n' >"$TMP/id_ed25519"
printf 'hostA ssh-ed25519 AAAAfake\n' >"$TMP/known_hosts"

# fake sudo: drop -n and "-u user -H", run the rest
printf '%s\n' '#!/bin/sh' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -n) shift ;; -u) shift 2 ;; -H) shift ;; *) break ;; esac' \
  'done' \
  'exec "$@"' >"$TMP/bin/sudo"
# fake ssh: log the options, then ignore them and the host and run the remote command locally as the receiving side
printf '%s\n' '#!/bin/sh' \
  "echo \"\$*\" >>\"$TMP/ssh.log\"" \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o|-F) shift 2 ;; -*) shift ;; *) break ;; esac' \
  'done' \
  'shift' \
  "HOME=\"$TMP/rhome\" SECRETS_GATE_CONF=\"$TMP/recv.conf\" SECRETS_GATE_SELF=\"$GATE\" exec sh -c \"\$*\"" >"$TMP/bin/ssh"
chmod +x "$TMP/bin/sudo" "$TMP/bin/ssh"

g() { SECRETS_GATE_CONF="$TMP/send.conf" SECRETS_GATE_SELF="$GATE" PATH="$TMP/bin:$PATH" bash "$GATE" "$@"; }

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
expect_rc "sync --delete is refused (the passwordless receive never deletes)" 2 g sync --delete
rm "$D/link.key"
expect_rc "sync pushes the folder" 0 g sync
sync_out=$LAST_OUT
[[ -f "$R/a.key" && -f "$R/sub/b.key" ]] && ok "sync copied the files" || bad "sync copied nothing: $sync_out"
[[ "$(stat -f %Lp "$R/a.key" 2>/dev/null || stat -c %a "$R/a.key")" == 600 ]] && ok "fleet copy files are 600" || bad "fleet copy mode"
[[ "$(stat -f %Lp "$R/sub" 2>/dev/null || stat -c %a "$R/sub")" == 700 ]] && ok "fleet copy dirs are 700" || bad "fleet copy dir mode"
[[ "$sync_out" != *fake-value* ]] && ok "sync output has no content" || bad "sync printed content"
[[ "$sync_out" == *a.key* ]] && ok "sync output lists changed names" || bad "sync output has no names: $sync_out"
[[ -z "$(find "$R" -name '.stage*')" ]] && ok "no staging folder left behind" || bad "staging left: $(find "$R" -name '.stage*')"
printf 'changed\n' >"$D/a.key"
expect_rc "sync dry run succeeds" 0 g sync --dry-run
[[ "$(cat "$R/a.key")" == fake-value-1 ]] && ok "dry run changed nothing" || bad "dry run wrote"
printf 'stale\n' >"$R/stale.key"
expect_rc "sync again updates the file" 0 g sync
[[ "$(cat "$R/a.key")" == changed ]] && ok "sync overwrote the changed file" || bad "changed file not copied"
[[ -e "$R/stale.key" ]] && ok "receive never deletes" || bad "receive deleted a file"

# sync's ssh ignores everything the owner account can edit
ssh_line=$(head -1 "$TMP/ssh.log")
for want in "-F /dev/null" "IdentitiesOnly=yes" "IdentityFile=$TMP/id_ed25519" "UserKnownHostsFile=$TMP/known_hosts" \
            "GlobalKnownHostsFile=/dev/null" "StrictHostKeyChecking=yes" "ProxyCommand=none" "ControlPath=none" "tester@hostA"; do
  [[ "$ssh_line" == *"$want"* ]] && ok "ssh has $want" || bad "ssh lacks $want: $ssh_line"
done
mv "$TMP/known_hosts" "$TMP/known_hosts.keep"
expect_rc "sync without a root owned known_hosts fails" 1 g sync
mv "$TMP/known_hosts.keep" "$TMP/known_hosts"
sed 's#^HOSTS=.*#HOSTS=-oProxyCommand=x hostA#' "$TMP/send.conf" >"$TMP/badhost.conf"
: >"$TMP/ssh.log"
out=$(SECRETS_GATE_CONF="$TMP/badhost.conf" SECRETS_GATE_SELF="$GATE" PATH="$TMP/bin:$PATH" bash "$GATE" sync --dry-run 2>&1)
if [[ "$out" == *"bad host name"* ]] && ! grep -q ProxyCommand=x "$TMP/ssh.log"; then ok "an option shaped host is skipped"; else bad "bad host: $out"; fi

# receive takes no caller option: a fake rsync records the argv the gate really runs
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$@\" >\"$TMP/rsync.argv\"" 'exit 0' >"$TMP/fakersync"
chmod +x "$TMP/fakersync"
rr() { SG_RSYNC="$TMP/fakersync" SECRETS_GATE_CONF="$TMP/recv.conf" PATH="$TMP/bin:$PATH" bash "$GATE" receive "$@"; }
expect_rc "receive with hostile arguments still runs" 0 rr --server -rlKLkogD --delete --rsync-path=/bin/sh --log-file=/tmp/x . "$TMP/outside/"
real_r=$(cd "$R" && pwd -P)
got=$(sed "s#$real_r/\.stage\.[A-Za-z0-9]*/#STAGE/#" "$TMP/rsync.argv")
want_argv=$(printf '%s\n' --server -rt --log-format=%i . STAGE/)
[[ "$got" == "$want_argv" ]] && ok "rsync runs with the fixed argument list only" || bad "argv: $got"
expect_rc "receive with no arguments runs the same" 0 rr
[[ -z "$(ls -A "$TMP/outside" | grep -v '^o.key$')" ]] && ok "receive did not use the caller destination" || bad "caller destination used"

# The attack from the FAIL Verdict: push 1 plants a symlink to an outside folder, push 2 (keep-dirlinks) writes through it
mkdir -p "$TMP/atk/src1" "$TMP/atk/src2/evil" "$TMP/atk/out"
ln -s "$TMP/atk/out" "$TMP/atk/src1/evil"
printf 'pwn\n' >"$TMP/atk/src2/evil/pwn"
printf '%s\n' '#!/bin/sh' \
  'while [ "$#" -gt 0 ]; do case "$1" in -o|-F) shift 2 ;; -*) shift ;; *) break ;; esac; done' \
  'shift' \
  "HOME=\"$TMP/rhome\" SECRETS_GATE_CONF=\"$TMP/recv.conf\" SECRETS_GATE_SELF=\"$GATE\" exec sh -c \"\$*\"" >"$TMP/atk/ssh"
chmod +x "$TMP/atk/ssh"
APATH="$TMP/bin:/usr/bin:/bin"
push() { # push <rsync flags> <src> <extra rsync-path args>
  PATH="$APATH" /usr/bin/rsync "$1" -e "$TMP/atk/ssh" --rsync-path="sudo -n bash $GATE receive${3:-}" "$2"/ h:"$R"/ >/dev/null 2>&1
}
push -rl "$TMP/atk/src1"
push -rK "$TMP/atk/src2"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "symlink plus keep-dirlinks push wrote nothing outside the folder" || bad "ESCAPE: $(ls -A "$TMP/atk/out")"
[[ -z "$(find "$R" -type l)" ]] && ok "no symlink landed in the folder" || bad "symlink in the folder: $(find "$R" -type l)"
push -rK "$TMP/atk/src2" " --server -rlK"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "extra -K sent as an argument changes nothing" || bad "ESCAPE with -K: $(ls -A "$TMP/atk/out")"

# a link that is already in the folder is replaced by the file, never followed
ln -s "$TMP/atk/out" "$R/linkdir"
mkdir -p "$TMP/atk/src3"
printf 'x\n' >"$TMP/atk/src3/linkdir"
push -rt "$TMP/atk/src3"
[[ -f "$R/linkdir" && ! -L "$R/linkdir" && -z "$(ls -A "$TMP/atk/out")" ]] && ok "an existing link is replaced, not followed" || bad "link followed or kept"
rm -f "$R/linkdir"
ln -s "$TMP/atk/out" "$R/evil"
mkdir -p "$TMP/atk/src4/evil"
printf 'y\n' >"$TMP/atk/src4/evil/deep.key"
push -rt "$TMP/atk/src4"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "a link as a parent directory is not written through" || bad "ESCAPE via parent link: $(ls -A "$TMP/atk/out")"
rm -rf "$R/evil"

# The gate starts with an absolute interpreter and resets the environment before any other command
[[ "$(head -1 "$GATE")" == "#!/bin/bash" ]] && ok "shebang is /bin/bash" || bad "shebang: $(head -1 "$GATE")"
first_cmd=$(grep -vE '^[[:space:]]*(#|$)' "$GATE" | head -1)
if [[ "$first_cmd" == *'/usr/bin/id -u'* && "$first_cmd" == *SG_CLEAN* ]]; then ok "the first command is the root re-exec"; else bad "first command: $first_cmd"; fi
if grep -qF 'exec /usr/bin/env -i SG_CLEAN=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash' "$GATE"; then ok "root re-exec has an empty environment and a system PATH"; else bad "no env -i re-exec"; fi
if ! grep -qE '(^|[^/A-Za-z_])id -u' "$GATE"; then ok "id is called by absolute path"; else bad "bare id call"; fi
if ! grep -qE 'homebrew|/usr/local' "$GATE"; then ok "no user writable folder on the root PATH"; else bad "user writable path in the gate"; fi
if grep -qE '^[[:space:]]*rsync_bin=/usr/bin/rsync' "$GATE"; then ok "rsync is an absolute path chosen on purpose"; else bad "rsync path not pinned"; fi
if ! grep -qE '(^|[^/A-Za-z_.-])rsync (--server|-)' "$GATE"; then ok "no bare rsync call"; else bad "bare rsync call"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
