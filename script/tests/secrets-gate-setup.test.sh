#!/usr/bin/env bash
# Tests for script/secrets-gate-setup.sh. A fake sudo logs every privileged command and runs none of them
# (except copying an installed file into a capture folder, and find, which only reads), so nothing here touches
# root files, a real folder or the real /opt.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/script/secrets-gate-setup.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$TMP/bin" "$TMP/pam" "$TMP/captured" "$TMP/ssh/sshd_config.d" "$TMP/roothome" "$TMP/opt"
chmod 700 "$TMP/opt" "$TMP/roothome"
D="$TMP/data/cred"
mkdir -p "$D"; chmod 700 "$TMP/data" "$D"
printf 'fake\n' >"$D/a.key"
printf '{"hosts":["hostA","hostB"]}\n' >"$TMP/sync.json"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfakefakefake secrets-gate'

# fake sudo: log the command; cmp and cat say "nothing there"; find runs (read only); install copies what it would place
printf '%s\n' '#!/bin/sh' \
  "echo \"\$*\" >>\"$TMP/sudo.log\"" \
  '[ "$1" = cmp ] && exit 1' \
  '[ "$1" = cat ] && exit 1' \
  '[ "$1" = find ] && exec "$@"' \
  'if [ "$1" = install ]; then' \
  '  for a in "$@"; do prev=$cur; cur=$a; done' \
  "  [ -f \"\$prev\" ] && cp \"\$prev\" \"$TMP/captured/\$(basename \"\$cur\")\"" \
  'fi' \
  'exit 0' >"$TMP/bin/sudo"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$TMP/bin/visudo"
printf '%s\n' '#!/bin/sh' 'echo "$* ssh-ed25519 AAAAfake"' >"$TMP/bin/ssh-keyscan"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$TMP/bin/sshd"
chmod +x "$TMP/bin/sudo" "$TMP/bin/visudo" "$TMP/bin/ssh-keyscan" "$TMP/bin/sshd"

run() {
  HOME="$TMP" PATH="$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" SG_TRUST_UID="$(id -u)" \
    SG_GATE_DIR="$TMP/opt" SG_SUDOERS_FILE="$TMP/sudoers" SG_PAM_DIR="$TMP/pam" SG_SSHD_DIR="$TMP/ssh" SG_ROOT_HOME="$TMP/roothome" \
    bash "$SETUP" "$@"
}

# No role, bad role
out=$(run --dry-run 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "a role is required" || bad "no role rc $rc"
out=$(run --role both --dry-run 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "role both is not a thing" || bad "role both rc $rc"

# Source dry run: prints the plan and the sudoers text, runs no sudo, changes nothing
out=$(run --dry-run --role source --dir "$D" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "source dry run exits 0" || bad "source dry run rc $rc: $out"
[ ! -e "$TMP/sudo.log" ] && ok "dry run ran no sudo" || bad "dry run called sudo: $(cat "$TMP/sudo.log")"
[ -z "$(ls "$TMP/captured")" ] && [ ! -e "$TMP/sudoers" ] && ok "dry run created nothing" || bad "dry run created files"
for want in "would: install the gate" "would: write the config" "would: hand the top of the folder to root and lock it" \
            "would: hand every file to root" "would: create the sync's ssh key" "would: write known_hosts" \
            "would: install the sudoers entry" "dry run: nothing changed"; do
  grep -qF "$want" <<<"$out" && ok "dry run says: $want" || bad "dry run lacks: $want"
done
grep -qF "| $(id -un) ALL=(root) NOPASSWD: $TMP/opt/secrets-gate sync" <<<"$out" && ok "dry run prints the exact sudoers entry" || bad "no sudoers entry in the dry run"
grep -qF 'env_reset, secure_path="/usr/bin:/bin:/usr/sbin:/sbin"' <<<"$out" && ok "dry run prints env_reset and secure_path" || bad "no env_reset line"
! grep -q 'NOPASSWD:.*receive' <<<"$out" && ok "source has no passwordless receive entry" || bad "source has a receive entry"
! grep -qE 'NOPASSWD: [^ ]+ sync (\*|--)' <<<"$out" && ok "the sync entry has no wildcard" || bad "wildcard on sync"
if [ "$(uname -s)" = Darwin ]; then
  grep -qF "would: enable Touch ID for sudo" <<<"$out" && ok "dry run says: enable Touch ID" || bad "dry run lacks the Touch ID step"
fi

# Receiver dry run: forced command line, sshd drop in, no sudoers at all
out=$(run --dry-run --role receiver --dir "$D" --pubkey "$KEY" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "receiver dry run exits 0" || bad "receiver dry run rc $rc: $out"
grep -qF "restrict,command=\"$TMP/opt/secrets-gate receive\" $KEY" <<<"$out" && ok "root's key line is restrict plus the fixed receive command" || bad "no forced command line: $out"
grep -qF "PermitRootLogin forced-commands-only" <<<"$out" && ok "sshd drop in limits root to forced commands" || bad "no PermitRootLogin line"
grep -qF "| $(id -un) ALL=(root) NOPASSWD: $TMP/opt/secrets-gate run *" <<<"$out" && ok "receiver dry run prints the run sudoers entry" || bad "receiver has no run entry: $out"
! grep -qE 'NOPASSWD:.*(receive|sync)' <<<"$out" && ok "receiver sudoers has no receive or sync entry" || bad "receiver sudoers grants receive or sync"
! grep -qE "helpers folder|install helper" <<<"$out" && ok "receiver without --helpers installs no helper" || bad "helpers step without --helpers"
[ ! -e "$TMP/sudo.log" ] && ok "receiver dry run ran no sudo" || bad "receiver dry run called sudo"
for bad_key in '' 'ssh-rsa AAAA' "$KEY"$'\n'"command=\"x\" ssh-ed25519 AAAA" 'ssh-ed25519 AAAA;touch x' 'command="/bin/sh" ssh-ed25519 AAAAfake'; do
  out=$(run --dry-run --role receiver --dir "$D" --pubkey "$bad_key" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && ok "receiver refuses pubkey '${bad_key%%$'\n'*}'" || bad "bad pubkey accepted: $bad_key"
done
out=$(run --dry-run --role receiver --dir "$D" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "receiver without a pubkey is refused" || bad "receiver without pubkey rc $rc"

# Real run on a receiver: root's authorized_keys and the drop in are what the dry run said
: >"$TMP/sudo.log"
out=$(run --role receiver --dir "$D" --pubkey "$KEY" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "receiver run exits 0" || bad "receiver run rc $rc: $out"
[ "$(cat "$TMP/captured/authorized_keys" 2>/dev/null)" = "restrict,command=\"$TMP/opt/secrets-gate receive\" $KEY" ] && ok "root's authorized_keys holds only the forced line" || bad "authorized_keys: $(cat "$TMP/captured/authorized_keys" 2>/dev/null)"
[ "$(sed -n 2p "$TMP/captured/100-secrets-gate.conf" 2>/dev/null)" = "PermitRootLogin forced-commands-only" ] && ok "sshd drop in installed" || bad "drop in missing"
grep -q ' -- ' "$TMP/sudo.log" && ok "privileged commands put -- before the names" || bad "no -- in the sudo log"

# --helpers: fixed helpers installed root 755 into <gate dir>/helpers, on both roles
HS="$TMP/hsrc"
mkdir -p "$HS"
printf '#!/bin/sh\necho one\n' >"$HS/peek"; printf '#!/bin/sh\necho two\n' >"$HS/env-check.sh"
: >"$TMP/sudo.log"
out=$(run --dry-run --role receiver --dir "$D" --pubkey "$KEY" --helpers "$HS" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "receiver dry run with --helpers exits 0" || bad "receiver --helpers dry run rc $rc: $out"
for want in "would: create the helpers folder $TMP/opt/helpers (root, 755)" "would: install helper peek (root, 755)" "would: install helper env-check.sh (root, 755)"; do
  grep -qF "$want" <<<"$out" && ok "helpers dry run says: $want" || bad "helpers dry run lacks: $want"
done
[ ! -s "$TMP/sudo.log" ] && [ ! -e "$TMP/opt/helpers" ] && ok "helpers dry run ran no sudo and created nothing" || bad "helpers dry run changed something"
rm -f "$TMP/captured/"*
: >"$TMP/sudo.log"
out=$(run --role receiver --dir "$D" --pubkey "$KEY" --helpers "$HS" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "receiver run with --helpers exits 0" || bad "receiver --helpers run rc $rc: $out"
grep -qE "^install -d -o root -g [^ ]+ -m 755 -- $TMP/opt/helpers\$" "$TMP/sudo.log" && ok "the helpers folder is made root 755" || bad "no helpers folder step: $(cat "$TMP/sudo.log")"
for n in peek env-check.sh; do
  grep -qE "^install -o root -g [^ ]+ -m 755 -- $HS/$n $TMP/opt/helpers/$n\$" "$TMP/sudo.log" && ok "helper $n installed root 755" || bad "helper $n not installed: $(cat "$TMP/sudo.log")"
done
cmp -s "$HS/peek" "$TMP/captured/peek" && ok "the installed helper is the source file" || bad "installed helper differs"
grep -qxF "$(id -un) ALL=(root) NOPASSWD: $TMP/opt/secrets-gate run *" "$TMP/captured/sudoers" && ok "receiver sudoers allows passwordless run" || bad "receiver sudoers: $(cat "$TMP/captured/sudoers" 2>/dev/null)"
! grep -qE 'receive|NOPASSWD:.*sync' "$TMP/captured/sudoers" && ok "receive stays out of the receiver sudoers" || bad "receiver sudoers holds receive or sync"
grep -q 'env_reset, secure_path=' "$TMP/captured/sudoers" && ok "receiver sudoers resets the environment" || bad "receiver sudoers lacks env_reset"
[ "$(cat "$TMP/captured/authorized_keys" 2>/dev/null)" = "restrict,command=\"$TMP/opt/secrets-gate receive\" $KEY" ] && ok "receive stays the forced command only" || bad "authorized_keys changed: $(cat "$TMP/captured/authorized_keys" 2>/dev/null)"

# Refusals: every one must leave sudo untouched
refused() { # <label> <expected text> <args...>
  local label=$1 want=$2 rc o; shift 2
  : >"$TMP/sudo.log"
  o=$(run "$@" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "$want" <<<"$o" && [ ! -s "$TMP/sudo.log" ]; then ok "$label"; else bad "$label (rc $rc, sudo: $(cat "$TMP/sudo.log"), out: $o)"; fi
}
mkdir -p "$TMP/real" "$TMP/data2"; chmod 700 "$TMP/real" "$TMP/data2"
ln -s "$TMP/real" "$TMP/linkparent"
ln -s "$D" "$TMP/linkfolder"
refused "a folder that is a symlink is refused" "symbolic link" --role source --dir "$TMP/linkfolder"
refused "a folder under a symlinked parent is refused" "symlink" --role source --dir "$TMP/linkparent/cred"
chmod 777 "$TMP/data2"
refused "a folder under a parent others can write is refused" "writable" --role source --dir "$TMP/data2/cred"
chmod 700 "$TMP/data2"
o=$(HOME="$TMP" PATH="$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" SG_TRUST_UID=0 SG_GATE_DIR="$TMP/opt" SG_SUDOERS_FILE="$TMP/sudoers" \
    SG_PAM_DIR="$TMP/pam" bash "$SETUP" --dry-run --role source --dir "$D" 2>&1); rc=$?
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -eq 1 ] && grep -qF "owned by uid" <<<"$o" && ok "a folder in a path the owner account owns is refused (root controlled paths only)" || bad "home-owned path accepted: rc $rc $o"
fi
ln -s "$TMP/outside" "$D/planted"
refused "a link planted inside the folder is refused before any chown" "link or special file" --role source --dir "$D"
rm -f "$D/planted"
mkfifo "$D/fifo"
refused "a special file inside the folder is refused" "link or special file" --role source --dir "$D"
rm -f "$D/fifo"
refused "a host name with user@ is refused" "host name" --role source --dir "$D" --hosts "root@hostA"
refused "an option shaped host name is refused" "host name" --role source --dir "$D" --hosts "-oProxyCommand=x"
refused "a deploy name with a slash is refused" "deploy name" --role source --dir "$D" --hosts hostA --deploy "../x"
refused "a missing helpers folder is refused" "helpers" --role receiver --dir "$D" --pubkey "$KEY" --helpers "$TMP/nohelpers"
ln -s "$HS/peek" "$HS/linked"
refused "a symlinked helper is refused" "symbolic link" --role receiver --dir "$D" --pubkey "$KEY" --helpers "$HS"
rm -f "$HS/linked"
printf 'x\n' >"$HS/.hidden"
refused "a helper name with a leading dot is refused" "helper name" --role source --dir "$D" --hosts hostA --helpers "$HS"
rm -f "$HS/.hidden"
printf 'x\n' >"$HS/-x"
refused "a helper name with a leading dash is refused" "helper name" --role source --dir "$D" --hosts hostA --helpers "$HS"
rm -f "$HS/-x"
mkdir "$HS/sub"
refused "a directory among the helpers is refused" "regular file" --role receiver --dir "$D" --pubkey "$KEY" --helpers "$HS"
rmdir "$HS/sub"

# Real source run: lock the top, then look again as root, then hand over the rest, in that order
: >"$TMP/sudo.log"
out=$(run --role source --dir "$D" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "source run exits 0" || bad "source run rc $rc: $out"
lock=$(grep -n "^chown -h -- root:.* $D\$" "$TMP/sudo.log" | head -1 | cut -d: -f1)
look=$(grep -n "^find -P $D " "$TMP/sudo.log" | head -1 | cut -d: -f1)
all=$(grep -n "^chown -R -P -- root:.* $D\$" "$TMP/sudo.log" | head -1 | cut -d: -f1)
if [ -n "$lock" ] && [ -n "$look" ] && [ -n "$all" ] && [ "$lock" -lt "$look" ] && [ "$look" -lt "$all" ]; then ok "order: lock the top, look for links as root, then chown -R -P"; else bad "order: lock=$lock look=$look all=$all: $(cat "$TMP/sudo.log")"; fi
grep -qF "$(id -un) ALL=(root) NOPASSWD: $TMP/opt/secrets-gate sync" "$TMP/captured/sudoers" && ok "installed sudoers is the sync entry" || bad "installed sudoers: $(cat "$TMP/captured/sudoers" 2>/dev/null)"
grep -qxF "$(id -un) ALL=(root) NOPASSWD: $TMP/opt/secrets-gate run *" "$TMP/captured/sudoers" && ok "source sudoers also allows passwordless run" || bad "source sudoers lacks run: $(cat "$TMP/captured/sudoers" 2>/dev/null)"
: >"$TMP/sudo.log"
out=$(run --role source --dir "$D" --helpers "$HS" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -qE "^install -o root -g [^ ]+ -m 755 -- $HS/peek $TMP/opt/helpers/peek\$" "$TMP/sudo.log" && ok "source run with --helpers installs the helpers" || bad "source --helpers: rc $rc $(cat "$TMP/sudo.log")"
[ "$(cat "$TMP/captured/secrets-gate.conf")" = "DIR=$D
HOSTS=hostA hostB
DEPLOY=" ] && ok "config holds the folder and hosts" || bad "config: $(cat "$TMP/captured/secrets-gate.conf")"

# A folder name that looks like an option or holds a space reaches every command after --
WD="$TMP/data/-odd name"
mkdir -p "$WD"; chmod 700 "$WD"
: >"$TMP/sudo.log"
out=$(run --role source --dir "$WD" --hosts hostA 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "an option shaped folder name with a space is handled" || bad "odd name rc $rc: $out"
if grep -E '^(chown|chmod) ' "$TMP/sudo.log" | grep -vF -- " -- " | grep -q .; then bad "a chown or chmod lacks --: $(cat "$TMP/sudo.log")"; else ok "every chown and chmod has -- before the name"; fi
grep -qF -- " $WD" "$TMP/sudo.log" && ok "the odd name arrives as one quoted argument" || bad "odd name split: $(cat "$TMP/sudo.log")"

# Fresh host: the gate directory does not exist yet and no --dir is given (the documented first step)
FRESH="$TMP/fresh"
mkdir -p "$FRESH"; chmod 700 "$FRESH"
run_fresh() {
  HOME="$TMP" PATH="$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" SG_TRUST_UID="$(id -u)" \
    SG_GATE_DIR="$FRESH/secrets-gate" SG_SUDOERS_FILE="$TMP/sudoers" SG_PAM_DIR="$TMP/pam" SG_SSHD_DIR="$TMP/ssh" SG_ROOT_HOME="$TMP/roothome" \
    bash "$SETUP" "$@"
}
for fresh_role in source receiver; do
  if [ "$fresh_role" = source ]; then fresh_args=(--role source --hosts hostA); else fresh_args=(--role receiver --pubkey "$KEY"); fi
  : >"$TMP/sudo.log"
  out=$(run_fresh --dry-run "${fresh_args[@]}" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "fresh host $fresh_role dry run exits 0" || bad "fresh host $fresh_role dry run rc $rc: $out"
  grep -qF "would: create $FRESH/secrets-gate" <<<"$out" && ok "fresh host $fresh_role dry run reports creating the gate dir" || bad "fresh host $fresh_role dry run lacks the create step: $out"
  [ ! -s "$TMP/sudo.log" ] && [ ! -e "$FRESH/secrets-gate" ] && ok "fresh host $fresh_role dry run ran no sudo and created nothing" || bad "fresh host $fresh_role dry run changed something"
  : >"$TMP/sudo.log"
  out=$(run_fresh "${fresh_args[@]}" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "fresh host $fresh_role run exits 0" || bad "fresh host $fresh_role run rc $rc: $out"
  grep -qE "^install -d -o root -g [^ ]+ -m 755 -- $FRESH/secrets-gate\$" "$TMP/sudo.log" && ok "fresh host $fresh_role run creates the gate dir through sudo" || bad "fresh host $fresh_role run did not create the gate dir: $(cat "$TMP/sudo.log")"
done
# A fresh host whose top parent is not root controlled is still refused
mkdir -p "$TMP/openparent"; chmod 777 "$TMP/openparent"
refused_fresh_out=$(HOME="$TMP" PATH="$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" SG_TRUST_UID="$(id -u)" SG_GATE_DIR="$TMP/openparent/secrets-gate" \
  bash "$SETUP" --dry-run --role source --hosts hostA 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -qF "writable" <<<"$refused_fresh_out" && ok "fresh host under a writable parent is refused" || bad "writable parent accepted: rc $rc $refused_fresh_out"

# BSD chown (macOS) reads options, then the owner, then only paths, so a `--` after the owner is a file name.
# The folder here is owned by the user, so step 3 takes the "not root 700" branch and runs both chowns.
BSD="$TMP/bsd"
mkdir -p "$BSD"
cat >"$BSD/chown" <<'EOF'
#!/bin/sh
# Stand-in for BSD chown: options (stop at --), then the owner, then only paths.
while [ $# -gt 0 ]; do case $1 in --) shift; break ;; -*) shift ;; *) break ;; esac; done
[ $# -gt 0 ] || { echo "usage: chown" >&2; exit 1; }
shift
for p; do
  if [ "$p" = -- ] || [ ! -e "$p" ]; then
    echo "chown: $p: No such file or directory" >&2
    touch "$(dirname "$0")/chown.fail"
    exit 1
  fi
done
exit 0
EOF
cat >"$BSD/sudo" <<'EOF'
#!/bin/sh
# chown is checked with BSD argument rules first, then handed to the shared stub that logs it.
if [ "$1" = chown ]; then shift; "$(dirname "$0")/chown" "$@" || exit $?; set -- chown "$@"; fi
exec "$(dirname "$0")/../bin/sudo" "$@"
EOF
chmod +x "$BSD/chown" "$BSD/sudo"
: >"$TMP/sudo.log"
out=$(HOME="$TMP" PATH="$BSD:$TMP/bin:$PATH" SECRETS_SYNC_CONFIG="$TMP/sync.json" SG_TRUST_UID="$(id -u)" \
  SG_GATE_DIR="$TMP/opt" SG_SUDOERS_FILE="$TMP/sudoers" SG_PAM_DIR="$TMP/pam" SG_SSHD_DIR="$TMP/ssh" SG_ROOT_HOME="$TMP/roothome" \
  bash "$SETUP" --role source --dir "$D" --hosts hostA 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$BSD/chown.fail" ] && ok "step 3 on an existing folder that is not root 700 passes BSD chown argument order" \
  || bad "BSD chown order: rc $rc, failed: $([ -e "$BSD/chown.fail" ] && echo yes || echo no), out: $out"
grep -qE "^chown -h -- root:[^ ]+ $D\$" "$TMP/sudo.log" && ok "the top is handed over as: chown -h -- root:group dir" || bad "top chown: $(cat "$TMP/sudo.log")"
grep -qE "^chown -R -P -- root:[^ ]+ $D\$" "$TMP/sudo.log" && ok "the folder is handed over as: chown -R -P -- root:group dir" || bad "folder chown: $(cat "$TMP/sudo.log")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
