#!/bin/bash
# Root owned gate to the credential folder. secrets-gate-setup.sh installs it as /opt/secrets-gate/secrets-gate
# (root, mode 755) next to its config. The folder is root 700 inside a root controlled path, so this is the only way in.
# Fixed command list, anything else is refused (exit 2):
#   fingerprint <file>      size and 8 hex fingerprint of one file in the folder, never its content
#   sync [--dry-run]        source host: push the folder to root@<host> of every fleet host over ssh, prints file names only
#   receive                 receiver host: the rsync server side. Runs ONLY as the forced command of the gate key in
#                           root's authorized_keys (restrict,command=...). No sudoers entry, no argument, no caller option.
#   deploy-read <name>      print one file from the DEPLOY allow list, for a deploy step
#   check-path <path>       exit 0 when the path and every parent is root controlled (setup uses it), prints why not
# Config (root owned, KEY=value lines): DIR (absolute), HOSTS (space separated names), DEPLOY (space separated file names).
# Next to the config (root owned): id_ed25519 (the only key sync's ssh uses) and known_hosts.
# A non root caller may point SECRETS_GATE_CONF, SG_RSYNC and SG_TRUST_UID elsewhere (tests); under root they are
# ignored. Under root the first thing that runs is a re-exec with an empty environment and a PATH of system
# folders only (no user writable folder), so nothing the calling account sets can steer a command here.
if [ -z "${SG_CLEAN:-}" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
  exec /usr/bin/env -i SG_CLEAN=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash "$0" "$@"
fi
set -u
set -f # no globbing anywhere: a name with a star is a name

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  conf=/opt/secrets-gate/secrets-gate.conf
  rsync_bin=/usr/bin/rsync
  trust_uid=0
else
  conf=${SECRETS_GATE_CONF:-/opt/secrets-gate/secrets-gate.conf}
  rsync_bin=${SG_RSYNC:-/usr/bin/rsync}
  trust_uid=${SG_TRUST_UID:-$(/usr/bin/id -u)}
fi
gate_dir=${conf%/*}

refuse() { echo "secrets-gate: refused: $*" >&2; exit 2; }
fail() { echo "secrets-gate: $*" >&2; exit 1; }

# stat_of <path>: "uid octal-mode" (GNU or BSD stat).
stat_of() { stat -c '%u %a' -- "$1" 2>/dev/null || stat -f '%u %Lp' -- "$1" 2>/dev/null; }

# path_trusted <absolute physical path>: print why not and return 1 unless the path, as written, has no symlink,
# dot, dot dot or double slash, and the path and every parent is a directory owned by the trusted uid (root, or the
# test user for a non root caller) or by root, and none of them can be renamed or replaced by anyone else: no
# group or other write bit, except a sticky parent whose child is owned by the trusted uid. A parent the owner
# account can write would let a worker swap the folder for a link after the check.
path_trusted() {
  local p=$1 cur= c ids uid mode
  case $p in /?*) ;; *) echo "not an absolute path"; return 1 ;; esac
  case "$p/" in */../*|*/./*|*//*) echo "has a dot, dot dot or double slash"; return 1 ;; esac
  local parts=() IFS=/
  read -r -a parts <<<"${p#/}"
  IFS=$' \t\n'
  local i=0 n=${#parts[@]} par=/
  # Walk from / down. par is the parent of cur.
  while [ "$i" -lt "$n" ]; do
    c=${parts[$i]}
    cur=${par%/}/$c
    [ -L "$cur" ] && { echo "$cur is a symlink"; return 1; }
    [ -d "$cur" ] || { echo "$cur is not a directory"; return 1; }
    ids=$(stat_of "$cur") || { echo "cannot stat $cur"; return 1; }
    uid=${ids% *} mode=${ids#* }
    { [ "$uid" = 0 ] || [ "$uid" = "$trust_uid" ]; } || { echo "$cur is owned by uid $uid"; return 1; }
    # the parent of cur must not let another account rename cur
    ids=$(stat_of "$par") || { echo "cannot stat $par"; return 1; }
    mode=${ids#* }
    mode=$(printf '%04d' "$((10#$mode))")
    if [ "$(( (8#${mode:2:1} & 2) | (8#${mode:3:1} & 2) ))" -ne 0 ]; then
      if [ "$(( 8#${mode:0:1} & 1 ))" -eq 1 ]; then
        [ "$(stat_of "$cur" | cut -d' ' -f1)" = "$trust_uid" ] || { echo "$par is writable by others and $cur is not owned by the trusted uid"; return 1; }
      else
        echo "$par is writable by group or others"; return 1
      fi
    fi
    par=$cur
    i=$((i + 1))
  done
  # cur itself must not be writable by group or others either (it is the last parent of what it holds)
  ids=$(stat_of "$cur"); mode=$(printf '%04d' "$((10#${ids#* }))")
  if [ "$(( (8#${mode:2:1} & 2) | (8#${mode:3:1} & 2) ))" -ne 0 ]; then echo "$cur is writable by group or others"; return 1; fi
  return 0
}

if [ "${1:-}" = check-path ]; then
  [ "$#" -eq 2 ] || refuse "check-path takes one path"
  why=$(path_trusted "$2") || { echo "$why"; exit 1; }
  exit 0
fi

[ -f "$conf" ] || fail "no config at $conf"
DIR= HOSTS= DEPLOY=
while IFS='=' read -r k v; do
  case $k in DIR|HOSTS|DEPLOY) printf -v "$k" '%s' "$v" ;; esac
done <"$conf"
case $DIR in /?*) ;; *) fail "config DIR must be an absolute path" ;; esac

# The folder must be root owned mode 700, in a root controlled path, with no link inside it. Checked on every use.
check_folder() {
  local why ids
  why=$(path_trusted "$DIR") || fail "folder not trusted: $why"
  ids=$(stat_of "$DIR")
  [ "${ids% *}" = "$trust_uid" ] && [ "${ids#* }" = 700 ] || fail "folder must be owned by uid $trust_uid with mode 700"
  [ -z "$(find -P "$DIR" -type l -print -quit)" ] || fail "folder holds a symbolic link (remove it as the owner with sudo, then rerun)"
}
check_folder
real_dir=$DIR

sha8() {
  if command -v shasum >/dev/null; then shasum -a 256 | cut -c1-8; else sha256sum | cut -c1-8; fi
}

# Print the absolute path of a regular file inside the folder, or fail. No dot dot, no symlink, nothing outside.
file_in_dir() {
  local p=$1
  case $p in /*) ;; *) p=$DIR/$p ;; esac
  case "$p/" in */../*|*/./*|*//*) return 1 ;; esac
  case $p in "$DIR"/?*) ;; *) return 1 ;; esac
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  # every directory between the folder and the file is a real directory
  local rel=${p#"$DIR"/} cur=$DIR c
  local parts=() IFS=/
  read -r -a parts <<<"$rel"
  IFS=$' \t\n'
  for c in "${parts[@]}"; do
    cur=$cur/$c
    [ -L "$cur" ] && return 1
  done
  printf '%s\n' "$p"
}

cmd_fingerprint() {
  [ "$#" -eq 1 ] || refuse "fingerprint takes one file"
  local f rel
  f=$(file_in_dir "$1") || refuse "fingerprint: not a regular file inside the folder"
  rel=${f#"$DIR"/}
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
  cat -- "$f"
}

cmd_sync() {
  local dry=0 a
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      *) refuse "sync: unknown flag" ;;
    esac
  done
  [ -n "$HOSTS" ] || fail "config has no HOSTS"
  local key=$gate_dir/id_ed25519 known=$gate_dir/known_hosts
  local count
  count=$(find -P "$DIR" -type f ! -name .DS_Store | wc -l | tr -d ' ')
  if [ "$dry" -eq 1 ]; then
    # The receiver ignores every client option, so a real rsync dry run cannot be asked of it. List the plan instead.
    echo "would push $count files to: $HOSTS"
    (cd "$DIR" && find -P . -type f ! -name .DS_Store | sed 's#^\./#  #')
    return 0
  fi
  [ -f "$key" ] && [ -f "$known" ] || fail "no ssh key or known_hosts next to the config (rerun secrets-gate-setup.sh)"
  # ssh ignores every user editable file: no config (-F /dev/null), one root owned key, one root owned known_hosts.
  local rsh="ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o IdentityFile=$key"
  rsh="$rsh -o UserKnownHostsFile=$known -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes"
  rsh="$rsh -o ProxyCommand=none -o ControlPath=none -o PermitLocalCommand=no"
  local h
  for h in $HOSTS; do
    case $h in ''|-*|*[!A-Za-z0-9._-]*) echo "warn bad host name, skipped"; continue ;; esac
    echo "$h"
    # The far end ignores the path and every option: its forced command receives into its own folder.
    # -rt only: no links, owners or devices travel. -i lists changed names.
    "$rsync_bin" -rt -i --exclude .DS_Store --exclude '.stage.*' -e "$rsh" -- "$DIR"/ "root@$h:folder/" 2>&1 \
      | sed 's/^/  /' || echo "warn push to $h failed"
  done
  echo "secrets-sync done ($count files at source)"
}

# Create a relative directory inside the folder one component at a time; fail if any component is a link.
safe_mkdir() {
  local p=$real_dir c
  [ "$1" = . ] && return 0
  local parts=() IFS=/
  read -r -a parts <<<"$1"
  IFS=$' \t\n'
  for c in "${parts[@]}"; do
    p=$p/$c
    [ -L "$p" ] && return 1
    [ -d "$p" ] || mkdir -- "$p" || return 1
    chmod -- 700 "$p"
  done
}

# The rsync server side. Reached only through the forced command in root's authorized_keys. Its arguments and the
# client's command line (SSH_ORIGINAL_COMMAND) are ignored: rsync starts with a fixed list (no -l, -K, -L, -o, -g,
# -D, --delete, no caller path) into a fresh staging folder inside the root 700 folder. Only regular files are then
# moved into place; links and anything else are dropped. Nothing is ever deleted from the folder.
cmd_receive() {
  [ "$#" -eq 0 ] || refuse "receive takes no argument"
  local stage f rel d dest
  stage=$(mktemp -d "$real_dir/.stage.XXXXXX") || fail "receive: cannot create a staging folder"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$stage'" EXIT
  "$rsync_bin" --server -rt --log-format=%i . "$stage"/ || fail "receive: rsync failed"
  while IFS= read -r -d '' f; do
    rel=${f#./}
    case "/$rel/" in */../*|*/./*|*//*|*/.stage.*) continue ;; esac
    case $rel in .DS_Store|*/.DS_Store) continue ;; esac
    case $rel in */*) d=${rel%/*} ;; *) d=. ;; esac
    safe_mkdir "$d" || continue
    dest=$real_dir/$rel
    [ -d "$dest" ] && [ ! -L "$dest" ] && continue
    [ -L "$dest" ] && rm -f -- "$dest"
    # the parent is checked again right before the move
    [ "$d" = . ] || [ "$(cd -P -- "$real_dir/$d" && pwd -P)" = "$real_dir/$d" ] || continue
    mv -f -- "$stage/$rel" "$dest" && chmod -- 600 "$dest"
  done < <(cd "$stage" && find -P . -type f -print0)
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
