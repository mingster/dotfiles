#!/usr/bin/env bash
# Print the owner's recorded decisions on an issue and on the issues it links (#1283).
# Usage: owner-decisions.sh <owner/repo> <issue>
# A decision is an issue comment whose first line starts with "Owner decision". Linked issues are the
# #N references in the issue body, one level deep. Exit 0 when any decision exists (printed), 1 when
# none, 2 on bad usage or when gh cannot read the issue (never read that as "no decision").
set -euo pipefail
[ $# -eq 2 ] || { echo "Usage: $0 <owner/repo> <issue>" >&2; exit 2; }
repo=$1 issue=${2#\#}
case "$issue" in ''|*[!0-9]*) echo "owner-decisions: issue must be a number" >&2; exit 2 ;; esac

fetch() { gh issue view "$1" -R "$repo" --json body,comments || { echo "owner-decisions: cannot read #$1" >&2; exit 2; }; }
decisions() { jq -r --arg n "$1" '.comments[] | select(.body | test("^\\s*Owner decision"; "i")) | "#\($n): " + .body' <<<"$2"; }

found=0
json=$(fetch "$issue")
out=$(decisions "$issue" "$json")
[ -z "$out" ] || { echo "$out"; found=1; }
for n in $(jq -r '.body // ""' <<<"$json" | grep -oE '#[0-9]+' | tr -d '#' | sort -un || true); do
  [ "$n" = "$issue" ] && continue
  linked_json=$(fetch "$n")
  out=$(decisions "$n" "$linked_json")
  [ -z "$out" ] || { echo "$out"; found=1; }
done
exit $((1 - found))
