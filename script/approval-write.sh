#!/usr/bin/env bash
# Writes one owner approval file. Runs as root through sudo, from the copy that
# script/approval-root-setup.sh installs; the owner's bin/owner-approve.sh pipes the JSON in.
# Usage: approval-write <namespace> < approval.json
# Result: <root>/<namespace>/approval.json, root owned, mode 0644 (world readable, writable by root only).
# AGENT_APPROVAL_ROOT replaces the root folder only when this runs as a non root user (tests).
set -euo pipefail
umask 022
ns=${1:-}
case "$ns" in
  ''|*[!A-Za-z0-9._-]*|.|..) echo "approval-write: namespace must be letters, digits, dot, dash or underscore" >&2; exit 2 ;;
esac
root=/usr/local/etc/agent-team
[ "$(id -u)" -eq 0 ] || root=${AGENT_APPROVAL_ROOT:-$root}
dir="$root/$ns"
[ -d "$dir" ] || { echo "approval-write: $dir is missing; the owner runs script/approval-root-setup.sh with sudo first" >&2; exit 1; }
tmp=$(mktemp "$dir/.approval.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,dict)' "$tmp" \
  || { echo "approval-write: input is not a JSON object" >&2; exit 1; }
chmod 0644 "$tmp"
mv -f "$tmp" "$dir/approval.json"
trap - EXIT
