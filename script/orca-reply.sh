#!/usr/bin/env bash
# Reply to an orchestration message (or send a new one), then nudge the recipient's terminal.
# A bare `orca orchestration reply` does not wake an idle agent session; it sees the reply only on its next input.
# Usage: orca-reply.sh --to <terminal handle> (--id <message id> | --subject <text>) --body <text> [--from <handle>]
#        -h and --help print this text.
set -euo pipefail
print_usage() { sed -n '/^# Usage:/,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }

orca_cli=${ORCA_CLI_COMMAND:-orca}
bound=${ORCA_REPLY_BOUND_SECONDS:-30}
bounded() {
  if command -v timeout > /dev/null 2>&1; then timeout "$bound" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then gtimeout "$bound" "$@"
  else perl -e 'alarm shift; exec @ARGV or exit 127' "$bound" "$@"
  fi
}

to="" id="" subject="" body="" from=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --to) to=${2-}; shift 2 || break ;;
    --id) id=${2-}; shift 2 || break ;;
    --subject) subject=${2-}; shift 2 || break ;;
    --body) body=${2-}; shift 2 || break ;;
    --from) from=${2-}; shift 2 || break ;;
    *) echo "orca-reply: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$to" ] || { echo "orca-reply: refusing, empty recipient (--to <terminal handle>)" >&2; exit 2; }
if [ -n "$id" ] && [ -n "$subject" ] || [ -z "$id$subject" ]; then echo "orca-reply: pass exactly one of --id (reply) or --subject (new message)" >&2; exit 2; fi
[ -n "$body" ] || { echo "orca-reply: --body is required" >&2; exit 2; }

# Mail to a settled or released dispatch makes Orca open a "New messages" follow-up on a dead terminal (#1221).
# Fails open when the worker list cannot be read.
settled=$(bounded "$orca_cli" orchestration worker-list --json --limit 100 2> /dev/null | jq -r --arg t "$to" '
  ($t | sub("^dispatch:"; "")) as $d
  | [.result.workers[]? | select(.terminal == $t or .dispatchId == $d)] as $rows
  | if ($rows | length) > 0 and ($rows | all(.terminalState == "released" or ((.state // "") | IN("succeeded", "failed", "stopped", "abandoned", "rejected")))) then "settled" else "" end' 2> /dev/null || true)
if [ "$settled" = settled ]; then
  echo "orca-reply: refusing, $to belongs to a settled or released dispatch. Start a fresh dispatch instead of mailing it." >&2
  exit 2
fi

if [ -n "$id" ]; then reply=("$orca_cli" orchestration reply --id "$id" --body "$body" --json)
else reply=("$orca_cli" orchestration send --to "$to" --subject "$subject" --body "$body" --json)
fi
[ -z "$from" ] || reply+=(--from "$from")
errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
rc=0
out=$(bounded "${reply[@]}" 2>"$errf") || rc=$?
[ -z "$out" ] || printf '%s\n' "$out"
cat "$errf" >&2
# answer_conflict: the ask already has an answer. Record its id so the fleet-watch unanswered digest skips it (#1838).
if [ -n "$id" ] && grep -q answer_conflict <<<"$out$(cat "$errf")"; then
  answered=${ORCA_REPLY_ANSWERED_FILE:-$HOME/.local/state/agent-team/answered-asks.txt}
  mkdir -p "$(dirname "$answered")" && echo "$id" >>"$answered"
  echo "orca-reply: $id already has an answer (answer_conflict); recorded in $answered" >&2
  # The earlier answer is not this body, so this one was not delivered (#1843). Fetch the ask and resend in its thread.
  ask_subject=$(bounded "$orca_cli" orchestration inbox --limit 5000 --full --json 2> /dev/null \
    | jq -r --arg id "$id" 'first(.result.messages[]? | select(.id == $id) | .subject // empty) // empty' 2> /dev/null || true)
  resend=("$orca_cli" orchestration send --to "$to" --thread-id "$id" --subject "Re: ${ask_subject:-Question}" --body "$body" --json)
  [ -z "$from" ] || resend+=(--from "$from")
  rc=0
  out=$(bounded "${resend[@]}" 2>"$errf") || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  cat "$errf" >&2
  if [ "$rc" = 0 ]; then echo "orca-reply: resent the answer to $to in the thread of $id" >&2
  else echo "orca-reply: resend in the thread of $id failed; the answer did not reach $to" >&2
  fi
fi
[ "$rc" = 0 ] || exit "$rc"

if ! bounded "$orca_cli" terminal send --terminal "$to" --text "check your inbox" --enter --json > /dev/null; then
  echo "orca-reply: reply sent but the nudge to $to failed" >&2
  exit 1
fi
