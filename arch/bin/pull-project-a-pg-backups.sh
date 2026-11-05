#!/usr/bin/env bash
# Pull project-a Postgres dumps from the production host to this machine.
#
# Third copy of the nightly dumps, on a different network and provider from
# host-a (primary) and host-b (backup ship target). Deliberately a pull: the
# primary holds no credentials for this host, so a compromise or an accidental
# wipe there cannot reach in and delete these copies the way it could a push target.
#
# No --delete, for the same reason. The primary expires dated directories after 30
# days; that must not erase them here. Local retention is pruned below and kept
# considerably longer — the dumps are well under a megabyte a day.
#
# Real host, user and paths live in pull-project-a-pg-backups.local.conf (untracked).

set -euo pipefail

_script="${BASH_SOURCE[0]}"
while [ -L "$_script" ]; do
  _link_dir=$(cd "$(dirname "$_script")" && pwd -P)
  _script=$(readlink "$_script")
  case "$_script" in
    /*) ;;
    *) _script="$_link_dir/$_script" ;;
  esac
done
bin_dir=$(cd "$(dirname "$_script")" && pwd -P)
unset _script _link_dir

local_conf="${PULL_PG_BACKUP_CONF:-$bin_dir/pull-project-a-pg-backups.local.conf}"
if [ ! -f "$local_conf" ]; then
  echo "ERROR: missing pull backup config: ${local_conf}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$local_conf"

SRC="${PULL_PG_SRC:-root@host-a.example:/var/lib/postgresql/18/backup/}"
DEST="${PULL_PG_DEST:-${HOME}/backup/project-a-pg}"
PRIMARY_HOST="${PULL_PG_PRIMARY_HOST:-host-a}"
KEY="${PULL_PG_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
DAYS_TO_KEEP="${PULL_PG_DAYS_TO_KEEP:-180}"
STALE_HOURS="${PULL_PG_STALE_HOURS:-30}"

mkdir -p "${DEST}"

# IdentitiesOnly: this host may offer several keys, and the source's MaxAuthTries
# closes the connection before the right one is reached.
rsync -az --stats \
    -e "ssh -i ${KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20" \
    "${SRC}" "${DEST}/"

# The dangerous failure is a silent no-op: if the source dump cron dies, this keeps
# "succeeding" against an unchanging directory. Fail loudly so the unit shows up
# in `systemctl --user --failed` instead.
newest="$(find "${DEST}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | head -1 | cut -d' ' -f2-)"

if [ -z "${newest}" ]; then
    echo "ERROR: no dumps present after pull" >&2
    exit 1
fi

age_hours=$(( ( $(date +%s) - $(stat -c %Y "${newest}") ) / 3600 ))
if [ "${age_hours}" -gt "${STALE_HOURS}" ]; then
    echo "ERROR: newest dump ${newest} is ${age_hours}h old (limit ${STALE_HOURS}h)." >&2
    echo "       ${PRIMARY_HOST}'s pg_backup cron may be dead — check /var/log/pg_backup.log there." >&2
    exit 1
fi

echo "Pruning local copies older than ${DAYS_TO_KEEP} days"
find "${DEST}" -mindepth 1 -maxdepth 1 -type d -mtime "+${DAYS_TO_KEEP}" -exec rm -rf '{}' ';'

echo "Newest dump: ${newest} (${age_hours}h old)"
echo "Local archive: $(du -sh "${DEST}" | cut -f1) across $(find "${DEST}" -mindepth 1 -maxdepth 1 -type d | wc -l) day(s)"
