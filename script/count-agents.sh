#!/usr/bin/env bash
# Print the number of coding agent CLI sessions in a process snapshot.
# Counts `claude` only when invoked bare (`claude ...`), so path qualified helpers such as
# `/Users/u/.local/bin/claude --chrome-native-host` stay out of the count. `agy` and `grok`
# count bare or by path. A match needs at least one argument. Cursor is not counted
# since the owner replaced it with Grok (#1264, #1527).
set -euo pipefail

usage="Usage: $0 [--stdin]"
case "$#:$*" in
  0:|1:--stdin) ;;
  1:-h|1:--help) echo "$usage" >&2; exit 0 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

process_args() {
  if [ "$#" -eq 0 ]; then ps -eo args; else cat; fi
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
