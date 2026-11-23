#!/usr/bin/env bash
# First step of a runner job that calls $HOME/dotfiles/script/...: fast-forward ~/dotfiles when it is
# on main, clean and behind origin/main. Same rule as session start (session-sync.sh), so a dirty,
# diverged or offline checkout prints one line and the job still runs. Always exits 0.
# Usage: dotfiles-sync.sh (takes no arguments: -h/--help print usage, anything else exits 2, #1581)
if [ $# -gt 0 ]; then
  echo "Usage: dotfiles-sync.sh (takes no arguments)" >&2
  case "$*" in -h | --help) [ $# -eq 1 ] && exit 0 ;; esac
  exit 2
fi
bash "$(cd "$(dirname "$0")" && pwd)/session-sync.sh" --dotfiles-only
exit 0
