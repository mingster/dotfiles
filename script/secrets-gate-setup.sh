#!/usr/bin/env bash
# Owner runs this once per host. Makes the credential folder root owned and installs the gate (secrets-gate.sh).
# Usage: secrets-gate-setup.sh [--dry-run] [--role source|receiver|both] [--dir <path>] [--hosts "h1 h2"] [--deploy "name1 name2"]
#   --dry-run  print every step it would take, change nothing, run no sudo
#   --role     source (default): this host pushes the folder, one passwordless sudoers entry for `sync` only
#              receiver: a fleet host that only receives, one passwordless entry for `receive` (the gate ignores its arguments)
#              both: the two entries
#   --dir      the folder, default from script/secrets-sync.config.json ("dir")
#   --hosts    fleet hosts to push to, default from that config ("hosts"), then fleet-pull.config.json
#   --deploy   file names `deploy-read` may print, default none
# Steps (each one skipped when already in place): /opt/secrets-gate with the gate and its config, a root owned ssh key
# and known_hosts for the sync (not for a receiver), folder chown root and mode 700, sudoers entry (checked with visudo),
# Touch ID for sudo (macOS pam_tid).
# Every privileged step goes through `sudo`, so Touch ID or the password is asked as usual.
# The SG_* variables below move the targets for tests only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
gate_dir=${SG_GATE_DIR:-/opt/secrets-gate}
sudoers_file=${SG_SUDOERS_FILE:-/etc/sudoers.d/secrets-gate}
pam_dir=${SG_PAM_DIR:-/etc/pam.d}
cfg=${SECRETS_SYNC_CONFIG:-$here/secrets-sync.config.json}
fleet=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}

dry=0 role=source dir='' hosts='' deploy=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --role) role=${2:?--role needs a value}; shift 2 ;;
    --dir) dir=${2:?--dir needs a path}; shift 2 ;;
    --hosts) hosts=${2:?--hosts needs a list}; shift 2 ;;
    --deploy) deploy=${2:?--deploy needs a list}; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
case $role in source|receiver|both) ;; *) echo "--role is source, receiver or both" >&2; exit 2 ;; esac

if [ -z "$dir" ] && [ -f "$cfg" ] && command -v jq >/dev/null; then
  dir=$(jq -r '.dir // empty' "$cfg")
  [ -n "$hosts" ] || hosts=$(jq -r '(.hosts // empty)[]' "$cfg" | tr '\n' ' ')
  [ -n "$hosts" ] || hosts=$(jq -r '.hosts[]' "$fleet" 2>/dev/null | tr '\n' ' ' || true)
fi
dir=${dir/#\~/$HOME}
[ -n "$dir" ] || { echo "secrets-gate-setup: no folder. Pass --dir or create $cfg" >&2; exit 1; }
case $dir in /?*) ;; *) echo "secrets-gate-setup: folder must be an absolute path" >&2; exit 1 ;; esac
rel=''
case $dir in "$HOME"/?*) rel=${dir#"$HOME"/} ;; esac
if [ "$role" != receiver ]; then
  [ -n "$rel" ] || { echo "secrets-gate-setup: a source folder must sit under $HOME" >&2; exit 1; }
  [ -n "${hosts// /}" ] || { echo "secrets-gate-setup: no hosts. Pass --hosts or fill the config" >&2; exit 1; }
fi
[ -n "$rel" ] || rel=$(basename "$dir")
owner=${SUDO_USER:-$(id -un)}
root_group=$(id -gn 0)
gate_src="$here/secrets-gate.sh"
[ -f "$gate_src" ] || { echo "secrets-gate-setup: $gate_src missing" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step() { printf '%s\n' "$*"; }
# act <description> <command...>: run it with sudo, or only print it in a dry run.
act() {
  local what=$1; shift
  if [ "$dry" -eq 1 ]; then step "would: $what  [sudo $*]"; else step "do:    $what"; sudo "$@"; fi
}
# stat_of <path>: owner and octal mode, GNU or BSD stat.
stat_of() { stat -c '%U %a' "$1" 2>/dev/null || stat -f '%Su %Lp' "$1"; }

# 1. The gate directory and the gate itself.
if [ "$(stat_of "$gate_dir" 2>/dev/null)" = "root 755" ]; then step "ok:    $gate_dir exists"
else act "create $gate_dir (root, 755)" install -d -o root -g "$root_group" -m 755 "$gate_dir"; fi
if [ -f "$gate_dir/secrets-gate" ] && cmp -s "$gate_src" "$gate_dir/secrets-gate" \
   && [ "$(stat_of "$gate_dir/secrets-gate")" = "root 755" ]; then step "ok:    gate already installed"
else act "install the gate" install -o root -g "$root_group" -m 755 "$gate_src" "$gate_dir/secrets-gate"; fi

# 2. The config, root owned so a worker cannot point the gate elsewhere.
{
  printf 'DIR=%s\nREL=%s\nOWNER=%s\nHOSTS=%s\nDEPLOY=%s\n' "$dir" "$rel" "$owner" "${hosts% }" "$deploy"
} >"$tmp/secrets-gate.conf"
if [ -f "$gate_dir/secrets-gate.conf" ] && cmp -s "$tmp/secrets-gate.conf" "$gate_dir/secrets-gate.conf" \
   && [ "$(stat_of "$gate_dir/secrets-gate.conf")" = "root 644" ]; then step "ok:    config up to date"
else act "write the config (folder, hosts, owner, deploy list)" install -o root -g "$root_group" -m 644 \
  "$tmp/secrets-gate.conf" "$gate_dir/secrets-gate.conf"; fi

# 2b. The sync's ssh uses only a root owned key and known_hosts, never the owner's ~/.ssh. Source hosts only.
if [ "$role" != receiver ]; then
  if [ -f "$gate_dir/id_ed25519" ]; then step "ok:    ssh key exists"
  else act "create the sync's ssh key (root only, no passphrase)" ssh-keygen -q -t ed25519 -N '' -C secrets-gate -f "$gate_dir/id_ed25519"; fi
  : >"$tmp/known_hosts"
  if [ "$dry" -eq 0 ]; then
    for h in $hosts; do ssh-keyscan -q -t ed25519 "${h#*@}" >>"$tmp/known_hosts" 2>/dev/null || echo "warn: no host key from $h"; done
    step "host keys found (compare them with each host before trusting this):"
    ssh-keygen -lf "$tmp/known_hosts" 2>/dev/null | sed 's/^/        /' || true
  fi
  if [ -f "$gate_dir/known_hosts" ] && cmp -s "$tmp/known_hosts" "$gate_dir/known_hosts" && [ "$dry" -eq 0 ]; then step "ok:    known_hosts up to date"
  else act "write known_hosts for the fleet hosts" install -o root -g "$root_group" -m 644 "$tmp/known_hosts" "$gate_dir/known_hosts"; fi
  step "note:  on every host that receives, add the key below to ~/.ssh/authorized_keys of $owner: sudo cat $gate_dir/id_ed25519.pub"
fi

# 3. The folder. After this the owner account cannot read it either, only through the gate.
if [ ! -d "$dir" ]; then
  step "skip:  $dir does not exist yet, create it and rerun"
elif [ "$(stat_of "$dir")" = "root 700" ]; then step "ok:    $dir is root owned, mode 700"
else
  act "hand the folder to root" chown -R "root:$root_group" "$dir"
  act "remove group and other access" chmod -R go-rwx "$dir"
  act "folder mode 700" chmod 700 "$dir"
fi

# 4. Sudoers: exactly the commands each role needs, passwordless. Everything else asks Touch ID or the password.
{
  echo "# Managed by secrets-gate-setup.sh. Passwordless: the fixed sync, and receive on a receiver (the gate ignores its arguments)."
  # The gate runs with a clean environment and root owned PATH whatever the caller exports.
  echo "Defaults!$gate_dir/secrets-gate env_reset, secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\""
  if [ "$role" != receiver ]; then echo "$owner ALL=(root) NOPASSWD: $gate_dir/secrets-gate sync"; fi
  if [ "$role" != source ]; then echo "$owner ALL=(root) NOPASSWD: $gate_dir/secrets-gate receive *"; fi
} >"$tmp/sudoers"
if [ "$dry" -eq 0 ]; then
  visudo -cf "$tmp/sudoers" >/dev/null || { echo "secrets-gate-setup: generated sudoers failed visudo, nothing installed" >&2; exit 1; }
fi
if [ "$dry" -eq 0 ] && sudo cmp -s "$tmp/sudoers" "$sudoers_file" 2>/dev/null; then step "ok:    sudoers entry up to date"
elif [ "$dry" -eq 1 ] && [ -e "$sudoers_file" ]; then step "ok?:   $sudoers_file exists (content is compared with sudo on a real run)"
else act "install the sudoers entry (role $role)" install -o root -g "$root_group" -m 440 "$tmp/sudoers" "$sudoers_file"; fi

# 5. Touch ID for sudo on macOS (macOS 14 and later read /etc/pam.d/sudo_local).
if [ "$(uname -s)" = Darwin ]; then
  if grep -qs '^auth.*pam_tid\.so' "$pam_dir/sudo_local" "$pam_dir/sudo" 2>/dev/null; then step "ok:    Touch ID already enabled for sudo"
  else
    printf 'auth       sufficient     pam_tid.so\n' >"$tmp/sudo_local"
    act "enable Touch ID for sudo" install -o root -g "$root_group" -m 444 "$tmp/sudo_local" "$pam_dir/sudo_local"
  fi
fi

if [ "$dry" -eq 1 ]; then step "dry run: nothing changed, no sudo ran"
else step "done. Check it: sudo $gate_dir/secrets-gate fingerprint <a file name in the folder>"; fi
