#!/usr/bin/env bash
# Push the secrets folder from this host to every fleet host with rsync over ssh.
# This host is the source of truth. Never prints file contents, only the names of changed files.
# Config (untracked, see secrets-sync.config.example.json): {"dir": "~/path/to/secrets", "hosts": ["ssh-host"]}
# "hosts" falls back to the hosts in fleet-pull.config.json.
# Flags: --dry-run (show what would change). --delete (also remove files the source no longer has;
# use once after a reorg, refused when the source holds fewer than 3 files).
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=${SECRETS_SYNC_CONFIG:-$here/secrets-sync.config.json}
fleet=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}
dry=(); del=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=(--dry-run) ;;
    --delete) del=(--delete) ;;
    *) echo "unknown flag $a" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo 'secrets-sync requires jq' >&2; exit 1; }
[ -f "$cfg" ] || { echo "secrets-sync: no $cfg, skipped (copy secrets-sync.config.example.json)"; exit 0; }
dir=$(jq -r '.dir' "$cfg"); dir=${dir/#\~/$HOME}
[ -d "$dir" ] || { echo "secrets-sync: source $dir missing" >&2; exit 1; }
hosts=$(jq -r '(.hosts // empty)[]' "$cfg")
[ -n "$hosts" ] || hosts=$(jq -r '.hosts[]' "$fleet" 2>/dev/null)
count=$(find "$dir" -type f ! -name .DS_Store | wc -l | tr -d ' ')
if [ "${#del[@]}" -gt 0 ] && [ "$count" -lt 3 ]; then
  echo "secrets-sync: refusing --delete, source has only $count files" >&2; exit 1
fi
rel=${dir#"$HOME"/}
for h in $hosts; do
  echo "$h"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" "umask 077; mkdir -p ~/'$rel'; chmod 700 ~/'$rel'" 2>&1 \
    || { echo "warn unreachable $h"; continue; }
  # -a keeps the tree; --chmod forces owner only modes on the fleet copy; -i lists changed names only.
  rsync -a ${dry[@]+"${dry[@]}"} ${del[@]+"${del[@]}"} -i --chmod=D700,F600 --exclude .DS_Store \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' "$dir"/ "$h":"~/$rel"/ 2>&1 \
    | grep -v '^\.' | sed 's/^/  /' || true
done
echo "secrets-sync done ($count files at source)"
