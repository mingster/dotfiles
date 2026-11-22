#!/usr/bin/env bash
# Print the number of coding agent CLI sessions in a process snapshot.
# Counts `claude` only when invoked bare (`claude ...`), so path qualified helpers such as
# `/Users/u/.local/bin/claude --chrome-native-host` stay out of the count. `agy` and `grok`
# count bare or by path. A match needs at least one argument. Cursor is not counted
# since the owner replaced it with Grok (#1264, #1527).
set -euo pipefail

process_args() {
  case "$#:$*" in
    0:) ps -eo args ;;
    1:--stdin) cat ;;
    *) printf 'Usage: %s [--stdin]\n' "$0" >&2; return 2 ;;
  esac
}

process_args "$@" | awk '
  {
    executable = $1
    sub(/^.*\//, "", executable)
    if ((executable == "claude" && $1 == "claude") || executable == "agy" || executable == "grok") {
      if (NF > 1) count++
    }
  }
  END { print count + 0 }
'
