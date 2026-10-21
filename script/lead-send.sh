#!/usr/bin/env bash
# lead-send.sh: Elon's one way to message a Tech Lead. The lead coordinates its own Run, so a message
# on Elon's Run, or to the lead's old dispatch, is never read. This resolves the Run the lead's
# terminal coordinates and sends to run:<id>.
# Usage: lead-send.sh --lead <lead terminal handle> --subject <text> [--body <text>] [--type status] [--from <handle>]
# --from defaults to $ORCA_TERMINAL_HANDLE. Prints "<run id> <message id>".
# Exit 0 sent, 1 when the lead coordinates no Run or the send fails, 2 on a usage error.
set -uo pipefail
orca="${ORCA_CLI_COMMAND:-orca}"
lead="" subject="" body="" type=status from="${ORCA_TERMINAL_HANDLE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --lead) lead=${2:-};; --subject) subject=${2:-};; --body) body=${2:-};; --type) type=${2:-};; --from) from=${2:-};;
  *) echo "lead-send: unknown arg $1" >&2; exit 2;; esac; shift 2; done
[ -n "$lead" ] && [ -n "$subject" ] || { echo "lead-send: need --lead and --subject" >&2; exit 2; }
run="" newest="" cursor=""
for _ in 1 2 3 4 5; do
  page=$("$orca" orchestration run-list --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) \
    || { echo "lead-send: cannot read orca run-list" >&2; exit 1; }
  hit=$(jq -r --arg h "$lead" '[.result.runs[]? | select(.coordinator_handle == $h)] | max_by(.created_at) // empty | "\(.created_at) \(.id)"' <<<"$page") \
    || { echo "lead-send: cannot parse orca run-list" >&2; exit 1; }
  if [ -n "$hit" ] && { [ -z "$newest" ] || [[ "${hit%% *}" > "$newest" ]]; }; then newest=${hit%% *}; run=${hit#* }; fi
  cursor=$(jq -r '.result.nextCursor // empty' <<<"$page"); [ -n "$cursor" ] || break
done
[ -n "$run" ] || { echo "lead-send: $lead coordinates no Run; the lead must run-create (or run-use) before Elon can message it" >&2; exit 1; }
out=$("$orca" orchestration send --to "run:$run" --type "$type" --subject "$subject" ${body:+--body "$body"} ${from:+--from "$from"} --json) \
  || { echo "lead-send: send to run:$run failed: $out" >&2; exit 1; }
echo "$run $(jq -r '.result.message.id // .result.id // .result.messageId // "sent"' <<<"$out")"
