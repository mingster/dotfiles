#!/usr/bin/env bash
# Print the owner's recorded decisions on an issue and on the issues it links (#1283).
# Usage: owner-decisions.sh <owner/repo> <issue>
# A decision is an issue comment whose first line starts with "Owner decision". Linked issues are the
# #N references in the issue body, one level deep. Exit 0 when any decision exists (printed), 1 when
# none, 2 on bad usage, when gh cannot read the issue, or when a linked read fails and nothing was
# found (never read that as "no decision"). A linked #N that does not resolve (dead ref) is skipped.
# The coordinator's owner asks log (OWNER_ASKS_LOG, default ~/.claude/state/elon-owner-asks.md) is read
# too: each line naming #<issue> is printed as "asks log: <line>" and counts as a recorded answer (#1298).
set -euo pipefail
[ $# -eq 2 ] || { echo "Usage: $0 <owner/repo> <issue>" >&2; exit 2; }
repo=$1 issue=${2#\#}
case "$issue" in ''|*[!0-9]*) echo "owner-decisions: issue must be a number" >&2; exit 2 ;; esac

decisions() { jq -r --arg n "$1" '.comments[] | select(.body | test("^\\s*Owner decision"; "i")) | "#\($n): " + .body' <<<"$2"; }

err=$(mktemp)
trap 'rm -f "$err"' EXIT
found=0 failed=0
log=${OWNER_ASKS_LOG:-$HOME/.claude/state/elon-owner-asks.md}
if [ -f "$log" ]; then
  out=$(grep -E "(^|[^A-Za-z0-9/])#$issue([^0-9]|\$)" "$log" | sed 's/^/asks log: /' || true)
  [ -z "$out" ] || { echo "$out"; found=1; }
fi
json=$(gh issue view "$issue" -R "$repo" --json body,comments) || { echo "owner-decisions: cannot read #$issue" >&2; exit 2; }
out=$(decisions "$issue" "$json")
[ -z "$out" ] || { echo "$out"; found=1; }
# Only #N not preceded by a letter, digit or "/" (so other/repo#98 is not this repo's #98).
for n in $(jq -r '.body // ""' <<<"$json" | grep -oE '(^|[^A-Za-z0-9/])#[0-9]+' | grep -oE '[0-9]+' | sort -un || true); do
  [ "$n" = "$issue" ] && continue
  if linked_json=$(gh issue view "$n" -R "$repo" --json body,comments 2>"$err"); then
    out=$(decisions "$n" "$linked_json")
    [ -z "$out" ] || { echo "$out"; found=1; }
  elif ! grep -qi 'could not resolve' "$err"; then
    echo "owner-decisions: cannot read #$n" >&2
    failed=1
  fi
done
[ "$found" -eq 1 ] && exit 0
[ "$failed" -eq 1 ] && exit 2
exit 1
