#!/usr/bin/env bash
# Root owned gate to the credential folder. secrets-gate-setup.sh installs it as /opt/secrets-gate/secrets-gate
# (root, mode 755) next to its config. The folder is root:wheel 700, so this is the only way in.
# Fixed command list, anything else is refused:
#   fingerprint <file>              size and 8 hex fingerprint of one file in the folder, never its content
#   sync [--dry-run] [--delete]     push the folder to the fleet hosts with rsync over ssh, prints file names only
#   receive --server ...            the rsync server side on a fleet host, writes only into the configured folder
#   deploy-read <name>              print one file from the DEPLOY allow list, for a deploy step
# Config (root owned, KEY=value lines): DIR (absolute), REL (path under $HOME on the fleet hosts), OWNER (the
# account whose ssh keys reach the hosts), HOSTS (space separated), DEPLOY (space separated file names).
# A non root caller may point SECRETS_GATE_CONF elsewhere (tests); under root the variable is ignored.
set -u

if [ "$(id -u)" -eq 0 ]; then
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
  conf=/opt/secrets-gate/secrets-gate.conf
  self=/opt/secrets-gate/secrets-gate
else
  conf=${SECRETS_GATE_CONF:-/opt/secrets-gate/secrets-gate.conf}
  self=${SECRETS_GATE_SELF:-/opt/secrets-gate/secrets-gate}
fi
export PATH

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

# Run the argument as the owner account when root, as the caller otherwise (tests).
as_owner() {
  if [ "$(id -u)" -eq 0 ]; then sudo -n -u "$OWNER" -H "$@"; else "$@"; fi
}

cmd_sync() {
  local dry=() del=() a
  for a in "$@"; do
    case $a in
      --dry-run) dry=(--dry-run) ;;
      --delete) del=(--delete) ;;
      *) refuse "sync: unknown flag" ;;
    esac
  done
  case $REL in ''|/*|*[!A-Za-z0-9._/-]*|*..*) fail "config REL is not a safe relative path" ;; esac
  case $OWNER in ''|*[!a-z0-9_-]*) fail "config OWNER is not a plain account name" ;; esac
  [ -n "$HOSTS" ] || fail "config has no HOSTS"
  local count h ssh_cmd rsh
  count=$(find "$DIR" -type f ! -name .DS_Store | wc -l | tr -d ' ')
  if [ "${#del[@]}" -gt 0 ] && [ "$count" -lt 3 ]; then fail "refusing --delete, source has only $count files"; fi
  ssh_cmd="ssh -o BatchMode=yes -o ConnectTimeout=10"
  if [ "$(id -u)" -eq 0 ]; then rsh="sudo -n -u $OWNER -H $ssh_cmd"; else rsh=$ssh_cmd; fi
  for h in $HOSTS; do
    case $h in -*|*[!A-Za-z0-9._@-]*) echo "warn bad host name, skipped"; continue ;; esac
    echo "$h"
    local rpath=()
    # shellcheck disable=SC2086
    if as_owner $ssh_cmd "$h" "test -x $self" >/dev/null 2>&1; then
      rpath=(--rsync-path="sudo -n $self receive")
    else
      # The host has no gate yet: its folder is still owner owned, so the owner account can prepare it.
      # shellcheck disable=SC2086
      as_owner $ssh_cmd "$h" "umask 077; mkdir -p ~/'$REL'; chmod 700 ~/'$REL'" 2>&1 \
        || { echo "warn unreachable $h"; continue; }
    fi
    # -i lists changed names only; --chmod forces owner only modes on the fleet copy.
    rsync -a ${dry[@]+"${dry[@]}"} ${del[@]+"${del[@]}"} -i --chmod=D700,F600 --exclude .DS_Store \
      ${rpath[@]+"${rpath[@]}"} -e "$rsh" "$DIR"/ "$h":"~/$REL"/ 2>&1 \
      | grep -v '^\.' | sed 's/^/  /' || true
  done
  echo "secrets-sync done ($count files at source)"
}

# rsync --server <flags> . <dest>: accept only plain flag clusters and the delete family, and only the
# configured folder as the destination. Everything else the caller sends is refused.
cmd_receive() {
  [ "${1:-}" = --server ] || refuse "receive: only the rsync server side"
  shift
  local opts=() dest
  while [ "$#" -gt 2 ]; do
    case $1 in
      --delete|--delete-before|--delete-during|--delete-after|--delete-delay|--log-format=%i) opts+=("$1") ;;
      -*[!A-Za-z0-9.]*|--*|-) refuse "receive: option not allowed" ;;
      -?*) opts+=("$1") ;;
      *) refuse "receive: unexpected argument" ;;
    esac
    shift
  done
  [ "$#" -eq 2 ] && [ "$1" = . ] || refuse "receive: expected '. <folder>'"
  dest=${2%/}
  [ "$dest" = "$DIR" ] || refuse "receive: destination is not the configured folder"
  mkdir -p "$DIR" && chmod 700 "$DIR"
  exec rsync --server ${opts[@]+"${opts[@]}"} . "$DIR"/
}

[ "$#" -ge 1 ] || refuse "usage: secrets-gate fingerprint|sync|receive|deploy-read"
cmd=$1; shift
case $cmd in
  fingerprint) cmd_fingerprint "$@" ;;
  deploy-read) cmd_deploy_read "$@" ;;
  sync) cmd_sync "$@" ;;
  receive) cmd_receive "$@" ;;
  *) refuse "unknown command" ;;
esac
