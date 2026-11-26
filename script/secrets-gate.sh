#!/bin/bash
# Root owned gate to the credential folder. secrets-gate-setup.sh installs it as /opt/secrets-gate/secrets-gate
# (root, mode 755) next to its config. The folder is root 700 inside a root controlled path, so this is the only way in.
# Fixed command list, anything else is refused (exit 2):
#   fingerprint <file>      size and 8 hex fingerprint of one file in the folder, never its content
#   sync [--dry-run]        source host: mirror the folder to root@<host> of every fleet host over ssh, prints file names
#                           only. A file or folder removed here is removed on every receiver.
#   receive                 receiver host: the rsync server side. Runs ONLY as the forced command of the gate key in
#                           root's authorized_keys (restrict,command=...). No sudoers entry, no argument, no caller option.
#                           Its folder ends up holding only what was pushed. A failed or empty push deletes nothing.
#   deploy-read <name>      print one file from the DEPLOY allow list, for a deploy step
#   check-path <path>       exit 0 when the path and every parent is root controlled (setup uses it), prints why not
#   run <helper> [args...]  run one fixed helper from helpers/ next to the config (root owned, no group or other write,
#                           no link) in an empty environment with SECRETS_GATE_FOLDER set to the folder, plus
#                           SECRETS_GATE_CALLER_UID, _USER and _HOME from sudo when present. Its arguments go to the helper.
# Config (root owned, KEY=value lines): DIR (absolute), HOSTS (space separated names), DEPLOY (space separated file names).
# Next to the config (root owned): id_ed25519 (the only key sync's ssh uses) and known_hosts.
# A non root caller may point SECRETS_GATE_CONF, SG_RSYNC and SG_TRUST_UID elsewhere (tests); under root they are
# ignored. Under root the first thing that runs is a re-exec with an empty environment and a PATH of system
# folders only (no user writable folder), so nothing the calling account sets can steer a command here. Only the
# SUDO_UID and SUDO_USER that sudo sets cross it, and `run` checks them before passing them on.
# Usage: secrets-gate.sh <command> [args]   (-h and --help print this text)
if [ -z "${SG_CLEAN:-}" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
  exec /usr/bin/env -i SG_CLEAN=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin SUDO_UID="${SUDO_UID:-}" SUDO_USER="${SUDO_USER:-}" /bin/bash "$0" "$@"
fi
print_usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
# the arguments after `run <helper>` belong to the helper, so its --help is not the gate's
for a in ${1+"$@"}; do case "$a" in -h|--help) print_usage; exit 0 ;; --|run) break ;; esac; done
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
  # shellcheck disable=SC1007 # empty assignment on purpose
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
# shellcheck disable=SC1007 # empty assignments on purpose (reset to empty)
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
    echo "receivers drop anything not in this list"
    return 0
  fi
  # An unreadable file makes the sender's rsync skip it, and every receiver then drops its copy. Refuse before any push.
  # Same skips as the rsync call below (.DS_Store and .stage.* at any depth). A find that cannot list a folder also refuses.
  local f files
  files=$(find -P "$DIR" \( -name '.stage.*' -o -name .DS_Store \) -prune -o -type f -print) || fail "sync: cannot list the folder"
  while IFS= read -r f; do
    [ -r "$f" ] || fail "sync: cannot read ${f#"$DIR"/}"
  done <<<"$files"
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

# lands <relative path>: true when receive would move a staged file of this name into the folder.
lands() {
  case "/$1/" in */../*|*/./*|*//*|*/.stage.*) return 1 ;; esac
  case $1 in .DS_Store|*/.DS_Store) return 1 ;; esac
}

# The rsync server side. Reached only through the forced command in root's authorized_keys. Its arguments and the
# client's command line (SSH_ORIGINAL_COMMAND) are ignored: rsync starts with a fixed list (no -l, -K, -L, -o, -g,
# -D, --delete, no caller path) into a fresh staging folder inside the root 700 folder. Only regular files are then
# moved into place; links and anything else are dropped. The folder mirrors the push: whatever is not a regular file
# also in the staging folder is removed (links are removed, never followed), then empty directories. Other .stage.*
# folders are left alone. When rsync fails or nothing landable is staged, nothing is deleted and the exit is not zero.
cmd_receive() {
  [ "$#" -eq 0 ] || refuse "receive takes no argument"
  local stage f rel d dest n=0
  stage=$(mktemp -d "$real_dir/.stage.XXXXXX") || fail "receive: cannot create a staging folder"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$stage'" EXIT
  "$rsync_bin" --server -rt --log-format=%i . "$stage"/ || fail "receive: rsync failed"
  while IFS= read -r -d '' f; do
    lands "${f#./}" && n=$((n + 1))
  done < <(cd "$stage" && find -P . -type f -print0)
  [ "$n" -gt 0 ] || fail "receive: no file was pushed, nothing changed"
  # Remove before moving in: the stage still lists every source file, and a name that turned from a folder into a
  # file (or back) is free by the time it moves.
  while IFS= read -r -d '' f; do
    rel=${f#./}
    dest=$real_dir/$rel
    lands "$rel" && [ -f "$dest" ] && [ ! -L "$dest" ] && [ -f "$stage/$rel" ] && [ ! -L "$stage/$rel" ] && continue
    # the parent is checked again right before the removal
    case $rel in */*) d=${rel%/*}; [ "$(cd -P -- "$real_dir/$d" && pwd -P)" = "$real_dir/$d" ] || continue ;; esac
    rm -f -- "$dest" || fail "receive: cannot remove $rel"
  done < <(cd "$real_dir" && find -P . -mindepth 1 ! -type d ! -path './.stage.*' -print0)
  # deepest first; rmdir refuses a directory that still holds something
  while IFS= read -r -d '' f; do
    rmdir -- "$real_dir/${f#./}" 2>/dev/null
  done < <(cd "$real_dir" && find -P . -mindepth 1 -depth -type d ! -path './.stage.*' -print0)
  while IFS= read -r -d '' f; do
    rel=${f#./}
    lands "$rel" || continue
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

# The helper must be a plain name for a regular executable file in helpers/ next to the config, owned by the trusted
# uid with no group or other write bit, in a trusted path with no link. It runs in an empty environment.
cmd_run() {
  [ "$#" -ge 1 ] || refuse "run takes a helper name"
  local name=$1 hdir=$gate_dir/helpers h why ids mode
  shift
  case $name in ''|[.-]*|*[!A-Za-z0-9._-]*) refuse "run: bad helper name" ;; esac
  why=$(path_trusted "$hdir") || refuse "run: helpers folder not trusted: $why"
  h=$hdir/$name
  [ ! -L "$h" ] || refuse "run: $name is a symlink"
  [ -f "$h" ] && [ -x "$h" ] || refuse "run: $name is not an executable file in $hdir"
  ids=$(stat_of "$h") || refuse "run: cannot stat $name"
  [ "${ids% *}" = "$trust_uid" ] || refuse "run: $name is not owned by uid $trust_uid"
  mode=$(printf '%04d' "$((10#${ids#* }))")
  [ "$(( (8#${mode:2:1} & 2) | (8#${mode:3:1} & 2) ))" -eq 0 ] || refuse "run: $name is writable by group or others"
  local env=(SECRETS_GATE_FOLDER="$DIR") uid=${SUDO_UID:-} user=${SUDO_USER:-} home=
  case $uid in ''|*[!0-9]*) ;; *) env+=(SECRETS_GATE_CALLER_UID="$uid") ;; esac
  case $user in ''|-*|*[!A-Za-z0-9._-]*) ;; *)
    env+=(SECRETS_GATE_CALLER_USER="$user")
    if command -v getent >/dev/null; then home=$(getent passwd "$user" | cut -d: -f6)
    else home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p'); fi
    case $home in /?*) env+=(SECRETS_GATE_CALLER_HOME="$home") ;; esac ;;
  esac
  exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "${env[@]}" "$h" "$@"
}

[ "$#" -ge 1 ] || refuse "usage: secrets-gate fingerprint|sync|receive|deploy-read|run"
cmd=$1; shift
case $cmd in
  fingerprint) cmd_fingerprint "$@" ;;
  deploy-read) cmd_deploy_read "$@" ;;
  sync) cmd_sync "$@" ;;
  receive) cmd_receive "$@" ;;
  run) cmd_run "$@" ;;
  *) refuse "unknown command" ;;
esac
