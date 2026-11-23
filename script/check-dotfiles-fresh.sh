#!/usr/bin/env bash
# Fail when an entry script does not source lib/dotfiles-fresh.sh (#1211).
# Usage: check-dotfiles-fresh.sh [<script dir>]   (default: this script's directory; -h and --help print this text)
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -le 1 ] || { echo "check-dotfiles-fresh: takes at most one argument" >&2; exit 2; }
dir=${1:-$(cd "$(dirname "$0")" && pwd)}
[ -d "$dir" ] || { echo "check-dotfiles-fresh: not a directory: $dir" >&2; exit 2; }
fail=0
for f in worker-startup.sh ship.sh head-checks.sh fleet-watch-loop.sh; do
  if ! grep -Eq '^\. "\$[a-z_]+/lib/dotfiles-fresh\.sh"' "$dir/$f" 2>/dev/null; then
    echo "check-dotfiles-fresh: $f does not source lib/dotfiles-fresh.sh" >&2
    fail=1
  fi
done
exit "$fail"
