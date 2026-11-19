#!/usr/bin/env bash
# Fail when an entry script does not source lib/dotfiles-fresh.sh (#1211).
# Usage: check-dotfiles-fresh.sh [<script dir>]   (default: this script's directory)
set -euo pipefail
dir=${1:-$(cd "$(dirname "$0")" && pwd)}
fail=0
for f in worker-startup.sh ship.sh head-checks.sh fleet-watch-loop.sh; do
  if ! grep -Eq '^\. "\$[a-z_]+/lib/dotfiles-fresh\.sh"' "$dir/$f" 2>/dev/null; then
    echo "check-dotfiles-fresh: $f does not source lib/dotfiles-fresh.sh" >&2
    fail=1
  fi
done
exit "$fail"
