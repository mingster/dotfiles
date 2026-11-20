#!/usr/bin/env bash
# Fail when a tracked file spells out the old per-category app folder or installs a cask into it.
# Apps live in /Applications. A script that needs an app path calls app_path (script/lib/app-path.sh),
# the one file allowed to name the old folder. _outdated/ and CHANGELOG.md are history.
# Usage: check-appdir.sh [<repo dir>]   (default: the repo this script is in)
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
old="/Applications/""_dev"   # split so this file does not match itself
hits=$(git -C "$root" grep -n -F -e "$old" -- . \
  ':(exclude)script/lib/app-path.sh' ':(exclude)_outdated' ':(exclude)CHANGELOG.md' || true)
if [ -n "$hits" ]; then
  echo "check-appdir: the old app folder is named outside script/lib/app-path.sh." >&2
  echo "Install into /Applications (no --appdir) and look an app up with app_path." >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
