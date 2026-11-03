#!/usr/bin/env bash
# Pull riben.life Postgres dumps from stm11 (production host) to this machine.
#
# Third copy of the nightly dumps, on a different network and provider from
# stm11 (primary) and stm39 (backup ship target). Deliberately a pull: stm11
# holds no credentials for this host, so a compromise or an accidental wipe
# there cannot reach in and delete these copies the way it could a push target.
#
# No --delete, for the same reason. stm11 expires dated directories after 30
# days; that must not erase them here. Local retention is pruned below and kept
# considerably longer — the dumps are well under a megabyte a day.

set -euo pipefail

SRC="root@stm11.tvcdn.org:/var/lib/postgresql/18/backup/"
DEST="${HOME}/backup/riben-pg"
KEY="${HOME}/.ssh/id_ed25519"
DAYS_TO_KEEP=180
STALE_HOURS=30

mkdir -p "${DEST}"

# IdentitiesOnly: this host offers three keys, and stm11's MaxAuthTries closes
# the connection before the right one is reached.
rsync -az --stats \
    -e "ssh -i ${KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20" \
    "${SRC}" "${DEST}/"

# The dangerous failure is a silent no-op: if stm11's dump cron dies, this keeps
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
    echo "       stm11's pg_backup cron may be dead — check /var/log/pg_backup.log there." >&2
    exit 1
fi

echo "Pruning local copies older than ${DAYS_TO_KEEP} days"
find "${DEST}" -mindepth 1 -maxdepth 1 -type d -mtime "+${DAYS_TO_KEEP}" -exec rm -rf '{}' ';'

echo "Newest dump: ${newest} (${age_hours}h old)"
echo "Local archive: $(du -sh "${DEST}" | cut -f1) across $(find "${DEST}" -mindepth 1 -maxdepth 1 -type d | wc -l) day(s)"
