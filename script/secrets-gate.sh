#!/bin/bash
# Root owned gate to the credential folder. secrets-gate-setup.sh installs it as /opt/secrets-gate/secrets-gate
# (root, mode 755) next to its config. The folder is root:wheel 700, so this is the only way in.
# Fixed command list, anything else is refused:
#   fingerprint <file>              size and 8 hex fingerprint of one file in the folder, never its content
#   sync [--dry-run]                push the folder to the fleet hosts with rsync over ssh, prints file names only
#   receive ...                     the rsync server side on a fleet host. Takes no option from the caller: the
#                                   rsync arguments are fixed here, it receives into a fresh root staging folder,
#                                   then moves regular files only into the configured folder. Never deletes.
#   deploy-read <name>              print one file from the DEPLOY allow list, for a deploy step
# Config (root owned, KEY=value lines): DIR (absolute), REL (path under $HOME on the fleet hosts), OWNER (the
# account name on the fleet hosts), HOSTS (space separated), DEPLOY (space separated file names).
# Next to the config (root owned): id_ed25519 (the only key sync's ssh uses) and known_hosts.
# A non root caller may point SECRETS_GATE_CONF, SECRETS_GATE_SELF and SG_RSYNC elsewhere (tests); under root they
# are ignored. Under root the first thing that runs is a re-exec with an empty environment and a PATH of system
# folders only (no user writable folder), so nothing the calling account sets can steer a command here.
if [ -z "${SG_CLEAN:-}" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
  exec /usr/bin/env -i SG_CLEAN=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash "$0" "$@"
fi
set -u

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  conf=/opt/secrets-gate/secrets-gate.conf
  self=/opt/secrets-gate/secrets-gate
  rsync_bin=/usr/bin/rsync
else
  conf=${SECRETS_GATE_CONF:-/opt/secrets-gate/secrets-gate.conf}
  self=${SECRETS_GATE_SELF:-/opt/secrets-gate/secrets-gate}
  rsync_bin=${SG_RSYNC:-/usr/bin/rsync}
fi
gate_dir=$(dirname "$conf")

refuse() { echo "secrets-gate: refused: $*" >&2; exit 2; }
fail() { echo "secrets-gate: $*" >&2; exit 1; }

[ -f "$conf" ] || fail "no config at $conf"
DIR= REL= OWNER= HOSTS= DEPLOY=
while IFS='=' read -r k v; do
  case $k in DIR|REL|OWNER|HOSTS|DEPLOY) printf -v "$k" '%s' "$v" ;; esac
done <"$conf"
case $DIR in /?*) ;; *) fail "config DIR must be an absolute path" ;; esac
[ -d "$DIR" ] || fail "folder $DIR missing"
real_dir=$(cd "$DIR" && pwd -P) || fail "cannot enter $DIR"

sha8() {
  if command -v shasum >/dev/null; then shasum -a 256 | cut -c1-8; else sha256sum | cut -c1-8; fi
}

# Print the absolute path of a regular file inside the folder, or fail. No dot dot, no symlink, nothing outside.
file_in_dir() {
  local p=$1 real
  case $p in /*) ;; *) p=$DIR/$p ;; esac
  case "$p/" in */../*|*/./*|*//*) return 1 ;; esac
  case $p in "$DIR"/?*|"$real_dir"/?*) ;; *) return 1 ;; esac
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  real=$(cd "$(dirname "$p")" && pwd -P) || return 1
  case "$real/" in "$real_dir"/*) ;; *) return 1 ;; esac
  printf '%s\n' "$p"
}

cmd_fingerprint() {
  [ "$#" -eq 1 ] || refuse "fingerprint takes one file"
  local f rel
  f=$(file_in_dir "$1") || refuse "fingerprint: not a regular file inside the folder"
  rel=${f#"$real_dir"/}; rel=${rel#"$DIR"/}
  echo "$rel: not a dotenv file; $(wc -c <"$f" | tr -d ' ') bytes, fp $(sha8 <"$f")"
}

cmd_deploy_read() {
  [ "$#" -eq 1 ] || refuse "deploy-read takes one name"
  local name=$1 allowed ok=
  case $name in ''|*[!A-Za-z0-9._-]*|.*) refuse "deploy-read: bad name" ;; esac
  for allowed in $DEPLOY; do [ "$allowed" = "$name" ] && ok=1; done
  [ -n "$ok" ] || refuse "deploy-read: $name is not on the deploy list"
  local f
  f=$(file_in_dir "$name") || refuse "deploy-read: $name is not a regular file in the folder"
  cat "$f"
}

cmd_sync() {
  local dry=() a
  for a in "$@"; do
    case $a in
      --dry-run) dry=(--dry-run) ;;
      *) refuse "sync: unknown flag" ;;
    esac
  done
  case $REL in ''|/*|*[!A-Za-z0-9._/-]*|*..*) fail "config REL is not a safe relative path" ;; esac
  case $OWNER in ''|*[!a-z0-9_-]*) fail "config OWNER is not a plain account name" ;; esac
  [ -n "$HOSTS" ] || fail "config has no HOSTS"
  local key=$gate_dir/id_ed25519 known=$gate_dir/known_hosts
  [ -f "$key" ] && [ -f "$known" ] || fail "no ssh key or known_hosts next to the config (rerun secrets-gate-setup.sh)"
  local count h rsh target
  count=$(find "$DIR" -type f ! -name .DS_Store ! -path '*/.stage.*' | wc -l | tr -d ' ')
  # ssh ignores every user editable file: no config (-F /dev/null), one root owned key, one root owned known_hosts.
  rsh="ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o IdentityFile=$key"
  rsh="$rsh -o UserKnownHostsFile=$known -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes"
  rsh="$rsh -o ProxyCommand=none -o ControlPath=none -o PermitLocalCommand=no"
  for h in $HOSTS; do
    case $h in -*|*[!A-Za-z0-9._@-]*) echo "warn bad host name, skipped"; continue ;; esac
    target=$h
    case $h in *@*) ;; *) target=$OWNER@$h ;; esac
    echo "$h"
    local rpath=()
    # shellcheck disable=SC2086
    if $rsh "$target" "test -x $self" >/dev/null 2>&1; then
      rpath=(--rsync-path="sudo -n $self receive")
    else
      # The host has no gate yet: its folder is still owner owned, so the owner account can prepare it.
      # shellcheck disable=SC2086
      $rsh "$target" "umask 077; mkdir -p ~/'$REL'; chmod 700 ~/'$REL'" 2>&1 \
        || { echo "warn unreachable $h"; continue; }
    fi
    # -rt only: no links, owners or devices travel. -i lists changed names only; the receiving gate sets modes 700 and 600.
    "$rsync_bin" -rt ${dry[@]+"${dry[@]}"} -i --exclude .DS_Store --exclude '.stage.*' \
      ${rpath[@]+"${rpath[@]}"} -e "$rsh" "$DIR"/ "$target":"~/$REL"/ 2>&1 \
      | grep -v '^\.' | sed 's/^/  /' || true
  done
  echo "secrets-sync done ($count files at source)"
}

# The rsync server side. The caller's arguments are ignored: rsync starts with a fixed list (no -l, -K, -L, -o,
# -g, -D, --delete, no caller path) into a fresh staging folder inside the root owned folder. Only regular files
# are then moved into the folder; directories are created plain; links and anything else are dropped. Nothing
# is ever deleted from the folder.
# Create a relative directory inside the folder one component at a time; fail if any component is a link.
safe_mkdir() {
  local p=$real_dir c
  [ "$1" = . ] && return 0
  local IFS=/
  for c in $1; do
    p=$p/$c
    [ -L "$p" ] && return 1
    [ -d "$p" ] || mkdir "$p" || return 1
    chmod 700 "$p"
  done
}

cmd_receive() {
  local stage f rel d dest
  chmod 700 "$real_dir"
  stage=$(mktemp -d "$real_dir/.stage.XXXXXX") || fail "receive: cannot create a staging folder"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  "$rsync_bin" --server -rt --log-format=%i . "$stage"/ || fail "receive: rsync failed"
  while IFS= read -r -d '' f; do
    rel=${f#./}
    case "/$rel/" in */../*|*/./*|*//*|*/.stage.*) continue ;; esac
    case $rel in .DS_Store|*/.DS_Store) continue ;; esac
    d=$(dirname "$rel")
    safe_mkdir "$d" || continue
    dest=$real_dir/$rel
    if [ -d "$dest" ] && [ ! -L "$dest" ]; then continue; fi
    if [ -L "$dest" ]; then rm -f "$dest"; fi
    mv -f "$stage/$rel" "$dest" && chmod 600 "$dest"
  done < <(cd "$stage" && find . -type f -print0)
}

[ "$#" -ge 1 ] || refuse "usage: secrets-gate fingerprint|sync|receive|deploy-read"
cmd=$1; shift
case $cmd in
  fingerprint) cmd_fingerprint "$@" ;;
  deploy-read) cmd_deploy_read "$@" ;;
  sync) cmd_sync "$@" ;;
  receive) cmd_receive ;;
  *) refuse "unknown command" ;;
esac
