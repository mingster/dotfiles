#!/usr/bin/env bash
# Behavioral tests for script/secrets-gate.sh against fake folders in a temp dir. No root, no real credential.
# A fake ssh stands in for the forced command on the receiver; rsync is the real one, run between two temp folders.
# Attacks replayed here come from the FAIL Verdicts on PR 936 (issue 922).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${SG_TEST_GATE:-$ROOT/script/secrets-gate.sh}"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
# Every external call runs under a timeout so a hang fails fast instead of eating the CI job.
TMO=${SG_TEST_TIMEOUT:-60}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sha8() { { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-8; }

mkdir -p "$TMP/home/rel/sub" "$TMP/rhome/rel" "$TMP/bin" "$TMP/outside"
D="$TMP/home/rel"
R="$TMP/rhome/rel"
chmod 700 "$D" "$D/sub" "$R"
printf 'fake-value-1\n' >"$D/a.key"
printf 'fake-value-2\n' >"$D/sub/b.key"
printf 'fake-value-3\n' >"$D/c.key"
printf 'outside-value\n' >"$TMP/outside/o.key"

printf 'DIR=%s\nHOSTS=hostA\nDEPLOY=a.key\n' "$D" >"$TMP/send.conf"
printf 'DIR=%s\nHOSTS=\nDEPLOY=\n' "$R" >"$TMP/recv.conf"
printf 'fake-key\n' >"$TMP/id_ed25519"
printf 'hostA ssh-ed25519 AAAAfake\n' >"$TMP/known_hosts"

# fake ssh: log the options, then act as sshd with a forced command: ignore the client's command, run the gate's receive
printf '%s\n' '#!/bin/sh' \
  "echo \"\$*\" >>\"$TMP/ssh.log\"" \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o|-F) shift 2 ;; -*) shift ;; *) break ;; esac' \
  'done' \
  'shift' \
  "SSH_ORIGINAL_COMMAND=\"\$*\" SECRETS_GATE_CONF=\"$TMP/recv.conf\" exec bash \"$GATE\" receive" >"$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"

g() { SECRETS_GATE_CONF="$TMP/send.conf" PATH="$TMP/bin:$PATH" timeout "$TMO" bash "$GATE" "$@"; }

LAST_OUT=
# expect_rc <label> <rc> <command...>
expect_rc() {
  local label=$1 want=$2 rc
  shift 2
  if [ "$(type -t "$1")" = function ]; then LAST_OUT=$("$@" 2>&1); else LAST_OUT=$(timeout "$TMO" "$@" 2>&1); fi; rc=$?
  [ "$rc" -eq 124 ] && LAST_OUT="timed out after ${TMO}s: $LAST_OUT"
  if [ "$rc" -ne "$want" ]; then bad "$label (rc $rc, want $want: $LAST_OUT)"; else ok "$label"; fi
}

# Fingerprint
expect_rc "fingerprint prints size and fp for a file" 0 g fingerprint a.key
want_fp=$(sha8 <"$D/a.key")
[[ "$LAST_OUT" == "a.key: not a dotenv file; 13 bytes, fp $want_fp" ]] && ok "fingerprint line is exact" || bad "fingerprint line: $LAST_OUT"
[[ "$LAST_OUT" != *fake-value* ]] && ok "fingerprint never prints content" || bad "fingerprint printed content"
expect_rc "fingerprint takes an absolute path inside the folder" 0 g fingerprint "$D/sub/b.key"
expect_rc "fingerprint refuses dot dot" 2 g fingerprint "sub/../a.key"
expect_rc "fingerprint refuses a path outside the folder" 2 g fingerprint "$TMP/outside/o.key"
expect_rc "fingerprint refuses a directory" 2 g fingerprint sub
expect_rc "fingerprint refuses no argument" 2 g fingerprint
expect_rc "fingerprint refuses two arguments" 2 g fingerprint a.key c.key
printf 'dash\n' >"$D/-n"
expect_rc "fingerprint takes a leading dash name" 0 g fingerprint -n
rm -f "$D/-n"

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
sed 's#^DEPLOY=.*#DEPLOY=*#' "$TMP/send.conf" >"$TMP/glob.conf"
out=$(SECRETS_GATE_CONF="$TMP/glob.conf" timeout "$TMO" bash "$GATE" deploy-read c.key 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "a star on the deploy list matches no file" || bad "glob deploy list: rc $rc $out"

# run <helper>: a fixed helper in <gate dir>/helpers reads the folder through SECRETS_GATE_FOLDER
H="$TMP/helpers"
mkdir -p "$H"; chmod 755 "$H"
printf '%s\n' '#!/bin/sh' 'f="${SECRETS_GATE_FOLDER:-}/a.key"' '[ -n "${SECRETS_GATE_FOLDER:-}" ] && [ -r "$f" ] || { echo "no folder" >&2; exit 3; }' \
  'echo "a.key lines=$(wc -l <"$f" | tr -d " ") args=$*"' >"$H/peek"
printf '%s\n' '#!/bin/sh' 'echo "folder=${SECRETS_GATE_FOLDER:-} uid=${SECRETS_GATE_CALLER_UID:-} user=${SECRETS_GATE_CALLER_USER:-} home=${SECRETS_GATE_CALLER_HOME:-} leak=${SG_LEAK:-}"' >"$H/env"
chmod 755 "$H/peek" "$H/env"
expect_rc "run executes a trusted helper" 0 g run peek x y
[[ "$LAST_OUT" == "a.key lines=1 args=x y" ]] && ok "run prints only the helper's safe output" || bad "run output: $LAST_OUT"
[[ "$LAST_OUT" != *fake-value* ]] && ok "run output holds no credential content" || bad "run printed content"
expect_rc "run passes --help to the helper, not the gate usage" 0 g run peek --help
[[ "$LAST_OUT" == "a.key lines=1 args=--help" ]] && ok "the helper got --help" || bad "run --help output: $LAST_OUT"
out=$(SG_LEAK=1 SUDO_UID=4242 SUDO_USER="$(id -un)" SECRETS_GATE_CONF="$TMP/send.conf" timeout "$TMO" bash "$GATE" run env 2>&1)
[[ "$out" == "folder=$D uid=4242 user=$(id -un) home=/"*" leak=" && "$out" != *"home=/ "* ]] && ok "the helper gets the folder and caller ids in a clean environment" || bad "helper env: $out"
out=$(SUDO_UID='1;x' SUDO_USER='-x' SECRETS_GATE_CONF="$TMP/send.conf" timeout "$TMO" bash "$GATE" run env 2>&1)
[[ "$out" == "folder=$D uid= user= home= leak=" ]] && ok "caller ids that are not plain are not passed" || bad "bad caller ids passed: $out"
expect_rc "the helper alone, without the gate, has no folder" 3 sh "$H/peek"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$D"
  expect_rc "a direct read fails when the folder is closed to the caller" 1 cat "$D/a.key"
  chmod 700 "$D"
fi
expect_rc "run without a helper name is refused" 2 g run
expect_rc "run of a missing helper is refused" 2 g run nope
for name in .. ../peek sub/peek /bin/sh .peek -peek 'pe ek' 'pe*'; do
  expect_rc "run refuses the name '$name'" 2 g run "$name"
done
ln -s "$H/peek" "$H/linked"
expect_rc "run refuses a symlinked helper" 2 g run linked
rm -f "$H/linked"
cp "$H/peek" "$H/gw"; chmod 775 "$H/gw"
expect_rc "run refuses a group writable helper" 2 g run gw
chmod 757 "$H/gw"
expect_rc "run refuses a world writable helper" 2 g run gw
chmod 644 "$H/gw"
expect_rc "run refuses a helper that is not executable" 2 g run gw
rm -f "$H/gw"
mkdir "$H/adir"
expect_rc "run refuses a directory" 2 g run adir
rmdir "$H/adir"
chmod 775 "$H"
expect_rc "run refuses a helpers folder others can write" 2 g run peek
chmod 755 "$H"
mv "$H" "$TMP/helpers.real"; ln -s "$TMP/helpers.real" "$H"
expect_rc "run refuses a symlinked helpers folder" 2 g run peek
rm -f "$H"; mv "$TMP/helpers.real" "$H"
chmod 755 "$D"
expect_rc "run checks the folder first" 1 g run peek
chmod 700 "$D"

# run refuses a helper whose owner uid is not the trusted uid, or whose stat fails. A fake stat on PATH answers
# for the helper only and hands every other path to the real stat. Non-root runs use PATH as given (no reset).
REAL_STAT=$(command -v stat)
mkdir -p "$TMP/fakebin"
printf '%s\n' '#!/bin/sh' \
  "for a in \"\$@\"; do [ \"\$a\" = \"$H/peek\" ] && { echo '99999 755'; exit 0; }; done" \
  "exec \"$REAL_STAT\" \"\$@\"" >"$TMP/fakebin/stat"
chmod +x "$TMP/fakebin/stat"
expect_rc "run refuses a helper owned by an untrusted uid" 2 env PATH="$TMP/fakebin:$PATH" SECRETS_GATE_CONF="$TMP/send.conf" bash "$GATE" run peek
[[ "$LAST_OUT" == *"refused: run: peek is not owned by uid"* ]] && ok "the refusal names the untrusted owner" || bad "owner refusal text: $LAST_OUT"
printf '%s\n' '#!/bin/sh' \
  "for a in \"\$@\"; do [ \"\$a\" = \"$H/peek\" ] && exit 1; done" \
  "exec \"$REAL_STAT\" \"\$@\"" >"$TMP/fakebin/stat"
expect_rc "run refuses a helper that cannot be stat'd" 2 env PATH="$TMP/fakebin:$PATH" SECRETS_GATE_CONF="$TMP/send.conf" bash "$GATE" run peek
[[ "$LAST_OUT" == *"refused: run: cannot stat peek"* ]] && ok "the refusal names the failed stat" || bad "stat refusal text: $LAST_OUT"
rm -f "$TMP/fakebin/stat"

# The folder is checked on every use: root controlled path, mode 700, no link inside
chmod 755 "$D"
expect_rc "a folder with mode 755 is refused" 1 g fingerprint a.key
chmod 700 "$D"
chmod 777 "$TMP/home"
expect_rc "a parent others can write is refused" 1 g fingerprint a.key
chmod 700 "$TMP/home"
ln -s "$D" "$TMP/linkfolder"
printf 'DIR=%s\nHOSTS=hostA\nDEPLOY=\n' "$TMP/linkfolder" >"$TMP/linkfolder.conf"
out=$(SECRETS_GATE_CONF="$TMP/linkfolder.conf" timeout "$TMO" bash "$GATE" fingerprint a.key 2>&1); rc=$?
[[ "$rc" -eq 1 && "$out" == *"symlink"* ]] && ok "a folder that is a symlink is refused" || bad "link folder: rc $rc $out"
mkdir -p "$TMP/real"; chmod 700 "$TMP/real"; mv "$D" "$TMP/real/rel"; ln -s "$TMP/real" "$TMP/linkparent"
printf 'DIR=%s/rel\nHOSTS=hostA\nDEPLOY=\n' "$TMP/linkparent" >"$TMP/linkparent.conf"
out=$(SECRETS_GATE_CONF="$TMP/linkparent.conf" timeout "$TMO" bash "$GATE" fingerprint a.key 2>&1); rc=$?
[[ "$rc" -eq 1 && "$out" == *"symlink"* ]] && ok "a folder under a symlinked parent is refused" || bad "link parent: rc $rc $out"
mv "$TMP/real/rel" "$D"
ln -s "$TMP/outside/o.key" "$D/link.key"
expect_rc "a symlink inside the folder refuses fingerprint" 1 g fingerprint a.key
expect_rc "a symlink inside the folder refuses sync" 1 g sync
rm "$D/link.key"
ln -s "$TMP/outside" "$D/linkdir"
expect_rc "a symlinked directory inside the folder refuses deploy-read" 1 g deploy-read a.key
rm "$D/linkdir"
mkdir -p "$TMP/oth"; chmod 700 "$TMP/oth"
expect_rc "check-path accepts a trusted path" 0 bash "$GATE" check-path "$TMP/oth"
expect_rc "check-path refuses a symlinked path" 1 bash "$GATE" check-path "$TMP/linkparent"
expect_rc "check-path refuses a relative path" 1 bash "$GATE" check-path "oth"
expect_rc "check-path refuses dot dot" 1 bash "$GATE" check-path "$TMP/oth/../oth"

# sync: real rsync from the folder into the receiving folder, through the fake ssh and the gate's receive
expect_rc "sync unknown flag is refused" 2 g sync --exclude x
expect_rc "sync --delete is refused" 2 g sync --delete
: >"$TMP/ssh.log"
expect_rc "sync pushes the folder" 0 g sync
sync_out=$LAST_OUT
[[ -f "$R/a.key" && -f "$R/sub/b.key" ]] && ok "sync copied the files" || bad "sync copied nothing: $sync_out"
[[ "$(mode "$R/a.key")" == 600 ]] && ok "fleet copy files are 600" || bad "fleet copy mode"
[[ "$(mode "$R/sub")" == 700 ]] && ok "fleet copy dirs are 700" || bad "fleet copy dir mode"
[[ "$sync_out" != *fake-value* ]] && ok "sync output has no content" || bad "sync printed content"
[[ "$sync_out" == *a.key* ]] && ok "sync output lists changed names" || bad "sync output has no names: $sync_out"
[[ -z "$(find "$R" -name '.stage*')" ]] && ok "no staging folder left behind" || bad "staging left: $(find "$R" -name '.stage*')"
printf 'changed\n' >"$D/a.key"
ssh_line=$(head -1 "$TMP/ssh.log")
: >"$TMP/ssh.log"
expect_rc "sync dry run succeeds" 0 g sync --dry-run
[[ "$LAST_OUT" == *a.key* && "$LAST_OUT" != *changed* ]] && ok "dry run lists names only" || bad "dry run output: $LAST_OUT"
[[ ! -s "$TMP/ssh.log" ]] && ok "dry run contacts no host" || bad "dry run called ssh"
[[ "$(cat "$R/a.key")" == fake-value-1 ]] && ok "dry run changed nothing" || bad "dry run wrote"
printf 'stale\n' >"$R/stale.key"
expect_rc "sync again updates the file" 0 g sync
[[ "$(cat "$R/a.key")" == changed ]] && ok "sync overwrote the changed file" || bad "changed file not copied"
[[ ! -e "$R/stale.key" ]] && ok "receive removes a file the source does not have" || bad "stale file kept"

# mirror: a file removed on the source goes from the receiver, with the folder it leaves empty
mkdir -p "$R/old/deep"; printf 'old\n' >"$R/old/deep/o.key"; printf 'x\n' >"$R/.DS_Store"
mkfifo "$R/pipe"
mkdir -p "$R/.stage.other"; printf 'x\n' >"$R/.stage.other/x"
mv "$D/sub/b.key" "$TMP/b.keep"
expect_rc "sync after a source removal succeeds" 0 g sync
[[ ! -e "$R/sub/b.key" && ! -e "$R/sub" ]] && ok "the removed file and its empty folder are gone" || bad "removed file or folder kept"
[[ ! -e "$R/old" ]] && ok "a receiver only tree is removed" || bad "receiver only tree kept"
[[ ! -e "$R/.DS_Store" && ! -e "$R/pipe" ]] && ok "stray and special files are removed" || bad "stray or special file kept"
[[ -f "$R/.stage.other/x" ]] && ok "another staging folder is not touched" || bad "staging folder touched"
[[ -f "$R/a.key" && -f "$R/c.key" && -d "$R" ]] && ok "source files stay" || bad "source files lost"
rm -rf "$R/.stage.other"
# a folder replaced by a file, and back, lands in one sync
printf 'now-a-file\n' >"$D/swap"
mkdir -p "$R/swap"; printf 'x\n' >"$R/swap/in"
expect_rc "sync turns a receiver folder into a file" 0 g sync
[[ -f "$R/swap" && "$(cat "$R/swap")" == now-a-file ]] && ok "folder to file mirrored in one sync" || bad "folder to file not mirrored"
rm -f "$D/swap"; mkdir "$D/swap"; printf 'inner\n' >"$D/swap/in"
expect_rc "sync turns a receiver file into a folder" 0 g sync
[[ "$(cat "$R/swap/in" 2>/dev/null)" == inner ]] && ok "file to folder mirrored in one sync" || bad "file to folder not mirrored"
rm -rf "$D/swap"; mv "$TMP/b.keep" "$D/sub/b.key"
expect_rc "sync restores the folder" 0 g sync

# the dry run says receivers drop the rest
expect_rc "sync dry run for the mirror note" 0 g sync --dry-run
[[ "$LAST_OUT" == *"receivers drop anything not in this list"* ]] && ok "dry run says receivers drop the rest" || bad "dry run note: $LAST_OUT"

# wipe guard and links: a fake rsync fills the staging folder (its last argument) as the case needs
printf '%s\n' '#!/bin/sh' 'for s; do :; done' 'eval "$SG_FAKE"' >"$TMP/stagersync"
chmod +x "$TMP/stagersync"
# fr <shell run as rsync, with $s the staging folder>
fr() { SG_FAKE="$1" SG_RSYNC="$TMP/stagersync" SECRETS_GATE_CONF="$TMP/recv.conf" timeout "$TMO" bash "$GATE" receive; }
snap() { (cd "$R" && find -P . | LC_ALL=C sort); }
before=$(snap)
expect_rc "receive with an empty stage fails" 1 fr ':'
[[ "$(snap)" == "$before" ]] && ok "an empty stage deletes nothing" || bad "empty stage changed the folder"
expect_rc "receive with only ignored files staged fails" 1 fr 'printf x >"$s.DS_Store"; mkdir "$s.stage.x"; printf x >"$s.stage.x/f"'
[[ "$(snap)" == "$before" ]] && ok "a stage of ignored files deletes nothing" || bad "ignored only stage changed the folder"
expect_rc "receive fails when rsync fails" 1 fr 'printf x >"${s}new"; exit 23'
[[ "$(snap)" == "$before" ]] && ok "a failed rsync deletes nothing" || bad "failed rsync changed the folder"
mkdir -p "$TMP/target/dir"; printf 'safe\n' >"$TMP/target/file"; printf 'safe\n' >"$TMP/target/dir/in"
plant="printf new >\"\${s}a.key\"; printf in >\"\${s}c.key\"; rm -f '$R/c.key'"
plant="$plant; ln -s '$TMP/target/file' '$R/c.key'; ln -s '$TMP/target/file' '$R/flink'; ln -s '$TMP/target/dir' '$R/dlink'"
expect_rc "receive removes links that appear in the folder" 0 fr "$plant"
[[ ! -L "$R/flink" && ! -L "$R/dlink" ]] && ok "planted links are removed" || bad "planted link kept"
[[ ! -L "$R/c.key" && "$(cat "$R/c.key")" == in ]] && ok "a link at a source name becomes the source file" || bad "link at a source name kept"
[[ "$(cat "$TMP/target/file")" == safe && "$(cat "$TMP/target/dir/in")" == safe ]] && ok "link targets are untouched" || bad "link target changed"
expect_rc "sync restores the folder after the guard cases" 0 g sync

# sync's ssh ignores everything the owner account can edit, and logs in as root
for want in "-F /dev/null" "IdentitiesOnly=yes" "IdentityFile=$TMP/id_ed25519" "UserKnownHostsFile=$TMP/known_hosts" \
            "GlobalKnownHostsFile=/dev/null" "StrictHostKeyChecking=yes" "ProxyCommand=none" "ControlPath=none" "root@hostA"; do
  # rsync hands the login to ssh as user@host on some builds and as -l user host on others
  [[ "$ssh_line" == *"$want"* || ( "$want" == root@hostA && "$ssh_line" == *"-l root hostA"* ) ]] && ok "ssh has $want" || bad "ssh lacks $want: $ssh_line"
done
mv "$TMP/known_hosts" "$TMP/known_hosts.keep"
expect_rc "sync without a root owned known_hosts fails" 1 g sync
mv "$TMP/known_hosts.keep" "$TMP/known_hosts"
sed 's#^HOSTS=.*#HOSTS=-oProxyCommand=x user@hostA#' "$TMP/send.conf" >"$TMP/badhost.conf"
: >"$TMP/ssh.log"
out=$(SECRETS_GATE_CONF="$TMP/badhost.conf" PATH="$TMP/bin:$PATH" timeout "$TMO" bash "$GATE" sync 2>&1)
if [[ "$out" == *"bad host name"* ]] && ! grep -q ProxyCommand=x "$TMP/ssh.log" && ! grep -q 'user@hostA' "$TMP/ssh.log"; then ok "an option shaped or user@ host is skipped"; else bad "bad host: $out"; fi

# A hostile ~/.ssh/config (ProxyCommand, HostName) steers nothing: real ssh, real rsync, a name that cannot resolve
mkdir -p "$TMP/evilhome/.ssh"
printf 'Host *\n  ProxyCommand touch %s/proxy-ran\n  HostName 127.0.0.1\n  Port 1\n  User attacker\n' "$TMP/evilhome" >"$TMP/evilhome/.ssh/config"
sed 's#^HOSTS=.*#HOSTS=nohost.invalid#' "$TMP/send.conf" >"$TMP/invalid.conf"
out=$(HOME="$TMP/evilhome" SECRETS_GATE_CONF="$TMP/invalid.conf" timeout "$TMO" bash "$GATE" sync 2>&1)
[[ ! -e "$TMP/evilhome/proxy-ran" ]] && ok "a user ssh config is not read (no ProxyCommand ran)" || bad "user ssh config ran a command"
[[ "$out" != *"attacker"* && "$out" != *"127.0.0.1"* ]] && ok "a user ssh config does not redirect the host" || bad "user ssh config used: $out"

# receive takes no caller option, and the client's command line is ignored: a fake rsync records the argv
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$@\" >\"$TMP/rsync.argv\"" 'for s; do :; done' 'printf x >"${s}argv.key"' >"$TMP/fakersync"
chmod +x "$TMP/fakersync"
rr() { SG_RSYNC="$TMP/fakersync" SECRETS_GATE_CONF="$TMP/recv.conf" SSH_ORIGINAL_COMMAND="rsync --server -rlKLkogD --delete --rsync-path=/bin/sh . $TMP/outside/" timeout "$TMO" bash "$GATE" receive "$@"; }
expect_rc "receive with an argument is refused" 2 rr -K
expect_rc "receive with a hostile client command line still runs the fixed list" 0 rr
got=$(sed "s#$R/\.stage\.[A-Za-z0-9]*/#STAGE/#" "$TMP/rsync.argv")
want_argv=$(printf '%s\n' --server -rt --log-format=%i . STAGE/)
[[ "$got" == "$want_argv" ]] && ok "rsync runs with the fixed argument list only" || bad "argv: $got"
[[ -z "$(ls -A "$TMP/outside" | grep -v '^o.key$')" ]] && ok "receive did not use the caller destination" || bad "caller destination used"

# Attack replays. push <rsync flags> <src>: a worker with its own rsync client reaching the forced command.
mkdir -p "$TMP/atk/src1" "$TMP/atk/src2/evil" "$TMP/atk/out"
ln -s "$TMP/atk/out" "$TMP/atk/src1/evil"
printf 'pwn\n' >"$TMP/atk/src2/evil/pwn"
APATH="$TMP/bin:/usr/bin:/bin"
# timeout is not in /usr/bin on every host, so resolve it before PATH is trimmed.
TIMEOUT_BIN=$(command -v timeout)
# The receiver's fixed flags (no -l) disagree with a client that sends links, so on some rsync builds that push stalls
# instead of failing. A stall counts as a refusal here: what matters is that nothing lands outside, which is asserted
# on the files after each push. The short timeout keeps the stall cheap.
PUSH_TMO=${SG_TEST_PUSH_TIMEOUT:-10}
push() { PATH="$APATH" "$TIMEOUT_BIN" "$PUSH_TMO" /usr/bin/rsync "$1" -e ssh "$2"/ "h:$R"/ >/dev/null 2>&1; }
# two push symlink then keep-dirlinks
push -rl "$TMP/atk/src1"
push -rK "$TMP/atk/src2"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "symlink plus keep-dirlinks push wrote nothing outside the folder" || bad "ESCAPE: $(ls -A "$TMP/atk/out")"
[[ -z "$(find "$R" -type l)" ]] && ok "no symlink landed in the folder" || bad "symlink in the folder: $(find "$R" -type l)"
# option injection through the remote command: the forced command ignores it (the fake ssh does the same)
PATH="$APATH" "$TIMEOUT_BIN" "$PUSH_TMO" /usr/bin/rsync -rK -e ssh --rsync-path="/opt/x --server -rlK --delete" "$TMP/atk/src2"/ "h:$R"/ >/dev/null 2>&1
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "an injected --rsync-path option changes nothing" || bad "ESCAPE with injected options: $(ls -A "$TMP/atk/out")"

# a link planted in the folder before setup, leading dash directory: the gate refuses to receive at all
ln -s "$TMP/atk/out" "$R/-x"
mkdir -p "$TMP/atk/src5/-x"
printf 'pwn\n' >"$TMP/atk/src5/-x/pwn"
push -rt "$TMP/atk/src5"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "a planted -x link is not written through" || bad "ESCAPE via -x link: $(ls -A "$TMP/atk/out")"
expect_rc "receive refuses while a link sits in the folder" 1 env SECRETS_GATE_CONF="$TMP/recv.conf" bash "$GATE" receive
rm -f "$R/-x"
ln -s "$TMP/atk/out" "$R/x*"
mkdir -p "$TMP/atk/src6/x1" "$TMP/atk/src6/x*"
printf 'pwn\n' >"$TMP/atk/src6/x*/pwn"
push -rt "$TMP/atk/src6"
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "a planted x* link is not written through" || bad "ESCAPE via x* link: $(ls -A "$TMP/atk/out")"
rm -f "$R/x*"

# leading dash and glob names land as plain files, in place
rm -rf "$TMP/atk/src7"; mkdir -p "$TMP/atk/src7/-x" "$TMP/atk/src7/x*" "$TMP/atk/src7/x1"
printf 'a\n' >"$TMP/atk/src7/-x/pwn"; printf 'b\n' >"$TMP/atk/src7/x*/pwn"; printf 'c\n' >"$TMP/atk/src7/--rsh=x"; printf 'd\n' >"$TMP/atk/src7/-rf"
printf 'e\n' >"$TMP/atk/src7/x1/keep"
push -rt "$TMP/atk/src7"
if [[ -f "$R/-x/pwn" && -f "$R/x*/pwn" && -f "$R/--rsh=x" && -f "$R/-rf" && -f "$R/x1/keep" ]]; then ok "dash and glob names land as plain files"; else bad "dash or glob name lost: $(ls -A "$R")"; fi
[[ -z "$(ls -A "$TMP/atk/out")" ]] && ok "dash and glob names wrote nothing outside" || bad "ESCAPE via names: $(ls -A "$TMP/atk/out")"
[[ -z "$(find "$R" -name '.stage*')" ]] && ok "no staging folder left behind after the attacks" || bad "staging left"

# an existing link is refused before anything is written (the check covers the whole folder)
ln -s "$TMP/atk/out" "$R/linkdir"
mkdir -p "$TMP/atk/src3"; printf 'x\n' >"$TMP/atk/src3/linkdir"
push -rt "$TMP/atk/src3"
[[ -L "$R/linkdir" && -z "$(ls -A "$TMP/atk/out")" ]] && ok "an existing link stays refused and nothing is written through it" || bad "link followed"
rm -f "$R/linkdir"

# The gate starts with an absolute interpreter and resets the environment before any other command
[[ "$(head -1 "$GATE")" == "#!/bin/bash" ]] && ok "shebang is /bin/bash" || bad "shebang: $(head -1 "$GATE")"
first_cmd=$(grep -vE '^[[:space:]]*(#|$)' "$GATE" | head -1)
if [[ "$first_cmd" == *'/usr/bin/id -u'* && "$first_cmd" == *SG_CLEAN* ]]; then ok "the first command is the root re-exec"; else bad "first command: $first_cmd"; fi
reexec=$(grep -E '^[[:space:]]*exec /usr/bin/env -i ' "$GATE" | head -1)
if [[ "$reexec" == *'env -i SG_CLEAN=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin SUDO_UID="${SUDO_UID:-}" SUDO_USER="${SUDO_USER:-}" /bin/bash "$0" "$@"' ]]; then
  ok "root re-exec has an empty environment, a system PATH and only the sudo caller ids"
else bad "re-exec line: $reexec"; fi
if ! grep -qE '(^|[^/A-Za-z_])id -u' "$GATE"; then ok "id is called by absolute path"; else bad "bare id call"; fi
# a fake id first on PATH that claims root must not change what the gate believes
mkdir -p "$TMP/fakebin"; printf '%s\n' '#!/bin/sh' 'echo 0' >"$TMP/fakebin/id"; chmod +x "$TMP/fakebin/id"
out=$(PATH="$TMP/fakebin:$PATH" SECRETS_GATE_CONF="$TMP/send.conf" timeout "$TMO" bash "$GATE" fingerprint a.key 2>&1)
[[ "$out" == a.key:* ]] && ok "a fake id on PATH does not make the gate think it is root" || bad "fake id changed behaviour: $out"
if ! grep -qE 'homebrew|/usr/local' "$GATE"; then ok "no user writable folder on the root PATH"; else bad "user writable path in the gate"; fi
if grep -qE '^[[:space:]]*rsync_bin=/usr/bin/rsync' "$GATE"; then ok "rsync is an absolute path chosen on purpose"; else bad "rsync path not pinned"; fi
if ! grep -qE '(^|[^/A-Za-z_.-])rsync (--server|-)' "$GATE"; then ok "no bare rsync call"; else bad "bare rsync call"; fi
if grep -qE '^set -f' "$GATE"; then ok "globbing is off"; else bad "globbing not disabled"; fi
if [ -z "$(grep -E '(^|[^A-Za-z_-])(mv|mkdir|rm|cat|chmod) ' "$GATE" | grep -vE '^[[:space:]]*#' | grep -vE -- '(mv -f --|mkdir --|rm -f --|rm -rf --|cat --|chmod --)')" ]; then
  ok "every mv, mkdir, rm, cat and chmod has -- before the names"
else bad "a command lacks --: $(grep -E '(^|[^A-Za-z_-])(mv|mkdir|rm|cat|chmod) ' "$GATE" | grep -vE -- '--' | head -3)"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
