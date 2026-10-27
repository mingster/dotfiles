#!/usr/bin/env bash
# Reply to an orchestration message, then nudge the recipient's terminal.
# A bare `orca orchestration reply` does not wake an idle agent session; it sees the reply only on its next input.
# Usage: orca-reply.sh --to <terminal handle> --id <message id> --body <text> [--from <handle>]
set -euo pipefail

orca_cli=${ORCA_CLI_COMMAND:-orca}
bound=${ORCA_REPLY_BOUND_SECONDS:-30}
bounded() {
  if command -v timeout > /dev/null 2>&1; then timeout "$bound" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then gtimeout "$bound" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$bound" "$@"
  fi
}

to="" id="" body="" from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to=${2-}; shift 2 || break ;;
    --id) id=${2-}; shift 2 || break ;;
    --body) body=${2-}; shift 2 || break ;;
    --from) from=${2-}; shift 2 || break ;;
    *) echo "orca-reply: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$to" ] || { echo "orca-reply: refusing, empty recipient (--to <terminal handle>)" >&2; exit 2; }
[ -n "$id" ] || { echo "orca-reply: --id is required" >&2; exit 2; }
[ -n "$body" ] || { echo "orca-reply: --body is required" >&2; exit 2; }

reply=("$orca_cli" orchestration reply --id "$id" --body "$body" --json)
[ -z "$from" ] || reply+=(--from "$from")
bounded "${reply[@]}"

if ! bounded "$orca_cli" terminal send --terminal "$to" --text "check your inbox" --enter --json > /dev/null; then
  echo "orca-reply: reply sent but the nudge to $to failed" >&2
  exit 1
fi
