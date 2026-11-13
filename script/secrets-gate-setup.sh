#!/usr/bin/env bash
# Owner runs this once per host. Makes the credential folder root owned and installs the gate (secrets-gate.sh).
# Usage: secrets-gate-setup.sh [--dry-run] --role source|receiver [--dir <path>] [--hosts "h1 h2"] [--deploy "n1 n2"]
#                              [--pubkey "<ssh-ed25519 line>"]
#   --dry-run  print every step it would take (and the sudoers, authorized_keys and sshd text), change nothing, run no sudo
#   --role     source: this host holds the master copy and pushes it. One passwordless sudoers entry, `sync` only.
#              receiver: a fleet host that only receives. No sudoers entry at all. Needs --pubkey (the source's gate key).
#   --dir      the folder, default /opt/secrets-gate/folder. It and every parent must be real directories (no link) that
#              only root can rename: owned by root, no group or other write bit. A folder under a home folder is refused.
#   --hosts    source only: fleet hosts to push to, default from script/secrets-sync.config.json, then fleet-pull.config.json
#   --deploy   file names `deploy-read` may print, default none
#   --pubkey   receiver only: the line printed by `sudo cat /opt/secrets-gate/id_ed25519.pub` on the source
# Receiver: root's authorized_keys gets one line, `restrict,command="<gate> receive" <pubkey>`, and sshd gets a drop in
# with `PermitRootLogin forced-commands-only`, so root login works for that command only and nothing runs as the
# shared worker account. Every privileged step goes through `sudo`. The SG_* variables move the targets for tests only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
gate_dir=${SG_GATE_DIR:-/opt/secrets-gate}
sudoers_file=${SG_SUDOERS_FILE:-/etc/sudoers.d/secrets-gate}
pam_dir=${SG_PAM_DIR:-/etc/pam.d}
sshd_dir=${SG_SSHD_DIR:-/etc/ssh}
root_home=${SG_ROOT_HOME:-$(cd ~root 2>/dev/null && pwd -P || echo /var/root)}
cfg=${SECRETS_SYNC_CONFIG:-$here/secrets-sync.config.json}
fleet=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}
export SG_TRUST_UID=${SG_TRUST_UID:-0}

dry=0 role='' dir='' hosts='' deploy='' pubkey=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --role) role=${2:?--role needs a value}; shift 2 ;;
    --dir) dir=${2:?--dir needs a path}; shift 2 ;;
    --hosts) hosts=${2:?--hosts needs a list}; shift 2 ;;
    --deploy) deploy=${2:?--deploy needs a list}; shift 2 ;;
    --pubkey) pubkey=${2:?--pubkey needs a line}; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
die() { echo "secrets-gate-setup: $*" >&2; exit 1; }
case $role in source|receiver) ;; *) die "--role is source or receiver" ;; esac

gate_src="$here/secrets-gate.sh"
[ -f "$gate_src" ] || die "$gate_src missing"
[ -n "$dir" ] || dir=$gate_dir/folder
case $dir in /?*) ;; *) die "folder must be an absolute path" ;; esac
# check_parent <label> <path>: the parent chain must be root controlled. Same rule the gate applies on every run.
check_parent() {
  local why
  why=$(bash "$gate_src" check-path "$2") || die "$1: $why. The folder must sit in a path only root can change (default $gate_dir/folder), not in a home folder."
}
check_parent "folder parent" "${dir%/*}"
[ ! -L "$dir" ] || die "$dir is a symbolic link"
check_parent "gate folder parent" "${gate_dir%/*}"
[ ! -L "$gate_dir" ] || die "$gate_dir is a symbolic link"
# A link or special file already in an owner owned folder is refused before any step runs (a root owned folder was
# locked by an earlier run and is checked by the gate on every use).
if [ -d "$dir" ] && [ -r "$dir" ]; then
  odd=$(find -P "$dir" ! -type f ! -type d -print -quit 2>/dev/null || true)
  [ -z "$odd" ] || die "the folder holds a link or special file ($odd). Remove it, then rerun. Nothing was changed."
fi

if [ "$role" = source ]; then
  if [ -z "$hosts" ] && command -v jq >/dev/null; then
    [ ! -f "$cfg" ] || hosts=$(jq -r '(.hosts // empty)[]' "$cfg" | tr '\n' ' ')
    [ -n "${hosts// /}" ] || hosts=$(jq -r '.hosts[]' "$fleet" 2>/dev/null | tr '\n' ' ' || true)
  fi
  [ -n "${hosts// /}" ] || die "no hosts. Pass --hosts or fill the config"
  for h in $hosts; do
    case $h in -*|*[!A-Za-z0-9._-]*) die "host name '$h' may only hold letters, digits, dot, dash and underscore (no user@)" ;; esac
  done
else
  [[ $pubkey =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9._@-]+)?$ ]] || die "--pubkey must be one ssh-ed25519 public key line"
fi
for n in $deploy; do case $n in ''|*[!A-Za-z0-9._-]*|.*) die "deploy name '$n' is not a plain file name" ;; esac; done
owner=${SUDO_USER:-$(id -un)}
case $owner in ''|-*|*[!A-Za-z0-9._-]*) die "owner account name is not plain" ;; esac
root_group=$(id -gn 0)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step() { printf '%s\n' "$*"; }
# act <description> <command...>: run it with sudo, or only print it in a dry run.
act() {
  local what=$1; shift
  if [ "$dry" -eq 1 ]; then step "would: $what  [sudo $*]"; else step "do:    $what"; sudo "$@"; fi
}
show() { sed 's/^/        | /' "$1"; }
# stat_of <path>: owner and octal mode, GNU or BSD stat.
stat_of() { stat -c '%U %a' -- "$1" 2>/dev/null || stat -f '%Su %Lp' -- "$1"; }

# 1. The gate directory and the gate itself.
if [ "$(stat_of "$gate_dir" 2>/dev/null)" = "root 755" ]; then step "ok:    $gate_dir exists"
else act "create $gate_dir (root, 755)" install -d -o root -g "$root_group" -m 755 -- "$gate_dir"; fi
if [ -f "$gate_dir/secrets-gate" ] && cmp -s "$gate_src" "$gate_dir/secrets-gate" \
   && [ "$(stat_of "$gate_dir/secrets-gate")" = "root 755" ]; then step "ok:    gate already installed"
else act "install the gate" install -o root -g "$root_group" -m 755 -- "$gate_src" "$gate_dir/secrets-gate"; fi

# 2. The config, root owned so a worker cannot point the gate elsewhere.
printf 'DIR=%s\nHOSTS=%s\nDEPLOY=%s\n' "$dir" "${hosts% }" "$deploy" >"$tmp/secrets-gate.conf"
if [ -f "$gate_dir/secrets-gate.conf" ] && cmp -s "$tmp/secrets-gate.conf" "$gate_dir/secrets-gate.conf" \
   && [ "$(stat_of "$gate_dir/secrets-gate.conf")" = "root 644" ]; then step "ok:    config up to date"
else act "write the config (folder, hosts, deploy list)" install -o root -g "$root_group" -m 644 -- \
  "$tmp/secrets-gate.conf" "$gate_dir/secrets-gate.conf"; fi

# 3. The folder. Lock the top first (a worker can no longer walk in), then look for links, then hand everything to root.
if [ ! -d "$dir" ]; then
  act "create the folder (root, 700)" install -d -o root -g "$root_group" -m 700 -- "$dir"
  step "note:  put the credential files in $dir with sudo, then rerun this script"
elif [ "$(stat_of "$dir")" = "root 700" ]; then step "ok:    $dir is root owned, mode 700"
else
  act "hand the top of the folder to root and lock it" chown -h "root:$root_group" -- "$dir"
  act "folder mode 700" chmod -- 700 "$dir"
  if [ "$dry" -eq 0 ]; then
    odd=$(sudo find -P "$dir" ! -type f ! -type d -print -quit) || true
    [ -z "$odd" ] || die "the folder holds a link or special file ($odd), left locked and untouched. Remove it with sudo, then rerun."
  fi
  act "hand every file to root, no links followed" chown -R -P "root:$root_group" -- "$dir"
  act "remove group and other access" chmod -R -- go-rwx "$dir"
fi

if [ "$role" = source ]; then
  # 4s. The sync's ssh uses only a root owned key and known_hosts, never the owner's ~/.ssh.
  if [ -f "$gate_dir/id_ed25519" ]; then step "ok:    ssh key exists"
  else act "create the sync's ssh key (root only, no passphrase)" ssh-keygen -q -t ed25519 -N '' -C secrets-gate -f "$gate_dir/id_ed25519"; fi
  : >"$tmp/known_hosts"
  if [ "$dry" -eq 0 ]; then
    for h in $hosts; do ssh-keyscan -q -t ed25519 "$h" >>"$tmp/known_hosts" 2>/dev/null || echo "warn: no host key from $h"; done
    step "host keys found (compare them with each host before trusting this):"
    ssh-keygen -lf "$tmp/known_hosts" 2>/dev/null | sed 's/^/        /' || true
  fi
  if [ -f "$gate_dir/known_hosts" ] && cmp -s "$tmp/known_hosts" "$gate_dir/known_hosts" && [ "$dry" -eq 0 ]; then step "ok:    known_hosts up to date"
  else act "write known_hosts for the fleet hosts" install -o root -g "$root_group" -m 644 -- "$tmp/known_hosts" "$gate_dir/known_hosts"; fi
  step "note:  on every receiver run: secrets-gate-setup.sh --role receiver --pubkey \"\$(sudo cat $gate_dir/id_ed25519.pub)\""

  # 5s. Sudoers: the fixed sync, passwordless. Everything else asks Touch ID or the password.
  {
    echo "# Managed by secrets-gate-setup.sh. Passwordless: the fixed sync only."
    echo "Defaults!$gate_dir/secrets-gate env_reset, secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\""
    echo "$owner ALL=(root) NOPASSWD: $gate_dir/secrets-gate sync"
  } >"$tmp/sudoers"
  step "sudoers text:"; show "$tmp/sudoers"
  if [ "$dry" -eq 0 ]; then
    visudo -cf "$tmp/sudoers" >/dev/null || die "generated sudoers failed visudo, nothing installed"
  fi
  if [ "$dry" -eq 0 ] && sudo cmp -s "$tmp/sudoers" "$sudoers_file" 2>/dev/null; then step "ok:    sudoers entry up to date"
  else act "install the sudoers entry" install -o root -g "$root_group" -m 440 -- "$tmp/sudoers" "$sudoers_file"; fi
else
  # 4r. Root's authorized_keys: the gate key may run the receive command and nothing else.
  line="restrict,command=\"$gate_dir/secrets-gate receive\" $pubkey"
  ak="$root_home/.ssh/authorized_keys"
  step "authorized_keys line for root:"; printf '        | %s\n' "$line"
  act "create root's .ssh folder" install -d -o root -g "$root_group" -m 700 -- "$root_home/.ssh"
  if [ "$dry" -eq 0 ]; then
    { sudo cat -- "$ak" 2>/dev/null | grep -vF "$gate_dir/secrets-gate receive" || true; printf '%s\n' "$line"; } >"$tmp/authorized_keys"
    if sudo cmp -s "$tmp/authorized_keys" "$ak" 2>/dev/null; then step "ok:    root's authorized_keys up to date"
    else act "install root's authorized_keys (the gate line replaces an older gate line, other lines stay)" \
      install -o root -g "$root_group" -m 600 -- "$tmp/authorized_keys" "$ak"; fi
  else
    step "would: add that line to $ak (an older gate line is replaced, other lines stay)"
  fi
  # 5r. sshd: root may log in with a key, for a forced command only.
  printf '# Managed by secrets-gate-setup.sh\nPermitRootLogin forced-commands-only\n' >"$tmp/sshd.conf"
  dropin="$sshd_dir/sshd_config.d/100-secrets-gate.conf"
  step "sshd drop in:"; show "$tmp/sshd.conf"
  grep -qsE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$sshd_dir/sshd_config" \
    || step "warn:  $sshd_dir/sshd_config has no 'Include $sshd_dir/sshd_config.d/*.conf' line. Add it above the first Match line, or put the PermitRootLogin line in sshd_config itself."
  if [ -f "$dropin" ] && cmp -s "$tmp/sshd.conf" "$dropin"; then step "ok:    sshd drop in up to date"
  else
    act "create the sshd drop in folder" install -d -o root -g "$root_group" -m 755 -- "$sshd_dir/sshd_config.d"
    act "install the sshd drop in" install -o root -g "$root_group" -m 644 -- "$tmp/sshd.conf" "$dropin"
    if [ "$dry" -eq 0 ]; then
      sudo "${SG_SSHD:-sshd}" -t || { sudo rm -f -- "$dropin"; die "sshd rejected the config, drop in removed"; }
    fi
    step "note:  sshd reads the drop in on the next connection (macOS). On Linux reload it: sudo systemctl reload ssh"
  fi
  step "note:  check: sudo sshd -T | grep -i permitrootlogin   must say forced-commands-only"
fi

# 6. Touch ID for sudo on macOS (macOS 14 and later read /etc/pam.d/sudo_local).
if [ "$role" = source ] && [ "$(uname -s)" = Darwin ]; then
  if grep -qs '^auth.*pam_tid\.so' "$pam_dir/sudo_local" "$pam_dir/sudo" 2>/dev/null; then step "ok:    Touch ID already enabled for sudo"
  else
    printf 'auth       sufficient     pam_tid.so\n' >"$tmp/sudo_local"
    act "enable Touch ID for sudo" install -o root -g "$root_group" -m 444 -- "$tmp/sudo_local" "$pam_dir/sudo_local"
  fi
fi

if [ "$dry" -eq 1 ]; then step "dry run: nothing changed, no sudo ran"
else step "done."; fi
