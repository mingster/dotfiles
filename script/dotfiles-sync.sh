#!/usr/bin/env bash
# First step of a runner job that calls $HOME/dotfiles/script/...: fast-forward ~/dotfiles when it is
# on main, clean and behind origin/main. Same rule as session start (session-sync.sh), so a dirty,
# diverged or offline checkout prints one line and the job still runs. Always exits 0.
# Usage: dotfiles-sync.sh
bash "$(cd "$(dirname "$0")" && pwd)/session-sync.sh" --dotfiles-only
exit 0
