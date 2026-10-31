#!/usr/bin/env bash
# Print the number of coding agent CLI sessions in a process snapshot.
set -euo pipefail

process_args() {
  case "$#:$*" in
    0:) ps -eo args ;;
    1:--stdin) cat ;;
    *) printf 'Usage: %s [--stdin]\n' "$0" >&2; return 2 ;;
  esac
}

process_args "$@" | awk '
  $1 == "claude" && NF > 1 { count++; next }
  {
    executable = $1
    sub(/^.*\//, "", executable)
    if ($1 ~ /\/\.local\/bin\/cursor-agent$/) {
      # The IDE helper path contains spaces and is not the executable token.
      count++
    }
  }
  END { print count + 0 }
'
