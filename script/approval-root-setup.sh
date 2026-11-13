#!/usr/bin/env bash
# One time setup for the root owned owner approval file (dotfiles#917). The owner runs it with sudo on each host:
#   sudo bash script/approval-root-setup.sh <namespace>...        (add --dry-run to only print the plan)
# It creates /usr/local/etc/agent-team/<namespace>/ owned by root (so a worker cannot rename or replace the
# file), installs the write helper root owned, and sets sudo to ask every time for that helper only
# (timestamp_timeout=0). Safe to re-run.
# Env for tests: SETUP_ROOT, SETUP_LIBEXEC, SETUP_SUDOERS (default real paths), SETUP_SKIP_ROOT_CHECK=1.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${SETUP_ROOT:-/usr/local/etc/agent-team}
libexec=${SETUP_LIBEXEC:-/usr/local/libexec/agent-team}
sudoers=${SETUP_SUDOERS:-/etc/sudoers.d/agent-team-approval}
helper="$libexec/approval-write"
dry=0
spaces=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *[!A-Za-z0-9._-]*|-*) echo "bad argument: $a" >&2; exit 2 ;;
    *) spaces+=("$a") ;;
  esac
done
[ "${#spaces[@]}" -gt 0 ] || { echo "Usage: sudo bash $0 [--dry-run] <namespace>..." >&2; exit 2; }
if [ "$dry" -eq 0 ] && [ "${SETUP_SKIP_ROOT_CHECK:-}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo (add --dry-run to only see the plan)." >&2
  exit 1
fi
rootgroup=$(id -gn 0)
own=(-o 0 -g "$rootgroup")
[ "$(id -u)" -eq 0 ] || own=()   # only a test runs unprivileged
sudoers_text="# Managed by dotfiles script/approval-root-setup.sh: ask for the password or Touch ID on every run of the approval writer.
Defaults!$helper timestamp_timeout=0
"
echo "This will:"
for ns in "${spaces[@]}"; do echo "  create $root/$ns (root:$rootgroup, 0755)"; done
echo "  install $helper (root:$rootgroup, 0755) from $here/approval-write.sh"
echo "  write $sudoers (0440) so sudo never caches a login for $helper"
echo "The approval file is then $root/<namespace>/approval.json, root owned, 0644."
[ "$dry" -eq 0 ] || { echo "Dry run: nothing changed."; exit 0; }

install -d -m 0755 ${own[@]+"${own[@]}"} "$root" "$libexec"
for ns in "${spaces[@]}"; do install -d -m 0755 ${own[@]+"${own[@]}"} "$root/$ns"; done
install -m 0755 ${own[@]+"${own[@]}"} "$here/approval-write.sh" "$helper"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$sudoers_text" > "$tmp"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$tmp" >/dev/null || { echo "sudoers text failed visudo; nothing installed" >&2; exit 1; }
fi
[ -d "$(dirname "$sudoers")" ] || install -d -m 0755 ${own[@]+"${own[@]}"} "$(dirname "$sudoers")"
install -m 0440 ${own[@]+"${own[@]}"} "$tmp" "$sudoers"
echo "Done. The owner's approve script now writes with: sudo $helper <namespace>"
