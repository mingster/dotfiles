#!/usr/bin/env bash
# Give every open issue of a repo a state label and a priority, and keep the board status labels in step.
# Usage: issue-label-gate.sh [--apply] [--repo OWNER/REPO]   (default: dry run, repo from DOTFILES_REPO or the origin remote)
# Rules (docs/agents/labels.md, "Gate at filing"):
#   no state label (needs-triage, ready-for-agent, a hold label or status:進行中)  -> add needs-triage
#   no P0..P3 label                                                            -> add P2
#   status:進行中 beats a leftover needs-triage or ready-for-agent                 -> remove those
#   ready-for-agent without a hold label  <-> status:接下來; owner <-> status:等你決定
# One line per changed issue on stdout. A failed gh call warns and exits 0: the gate never blocks work.
set -uo pipefail
apply=0 repo=${DOTFILES_REPO:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --repo) repo=${2:?--repo needs OWNER/REPO}; shift 2 ;;
    *) echo "Usage: $0 [--apply] [--repo OWNER/REPO]" >&2; exit 2 ;;
  esac
done
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "$repo" ]; then
  url=$(git -C "$here/.." remote get-url origin 2>/dev/null || true)
  repo=$(printf '%s' "$url" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
fi
[ -n "$repo" ] || { echo "issue-label-gate: no repo (pass --repo)" >&2; exit 2; }
command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "issue-label-gate: gh and jq are required" >&2; exit 0; }
issues=$(gh issue list --repo "$repo" --state open --limit 500 --json number,labels 2>/dev/null) \
  || { echo "issue-label-gate: could not list issues for $repo; skipped" >&2; exit 0; }
plan=$(printf '%s' "$issues" | jq -r '
  .[] | (.labels | map(.name)) as $l
  | ["blocked","owner","deferred","tracking","needs-redesign","needs-elon"] as $hold
  | ($l | index("status:進行中") != null) as $flight
  | ($l | index("ready-for-agent") != null and (map(IN($hold[])) | any | not)) as $ready
  | [ (if ($l | any(. == "needs-triage" or . == "ready-for-agent" or . == "status:進行中" or IN($hold[]))) then empty else "needs-triage" end),
      (if ($l | any(test("^P[0-3]$"))) then empty else "P2" end),
      (if $ready and ($flight | not) and ($l | index("status:接下來") == null) then "status:接下來" else empty end),
      (if ($l | index("owner") != null) and ($l | index("status:等你決定") == null) then "status:等你決定" else empty end) ] as $add
  | [ (if $flight and ($l | index("needs-triage") != null) then "needs-triage" else empty end),
      (if $flight and ($l | index("ready-for-agent") != null) then "ready-for-agent" else empty end),
      (if ($l | index("status:接下來") != null) and (($ready | not) or $flight) then "status:接下來" else empty end),
      (if ($l | index("status:等你決定") != null) and ($l | index("owner") == null) then "status:等你決定" else empty end) ] as $rm
  | select(($add | length) + ($rm | length) > 0)
  | "\(.number)|\($add | join(","))|\($rm | join(","))"')
[ -n "$plan" ] || { echo "issue-label-gate: $repo ok"; exit 0; }
while IFS='|' read -r num add rm; do
  [ -n "$num" ] || continue
  echo "#$num${add:+ +${add//,/ +}}${rm:+ -${rm//,/ -}}"
  [ "$apply" -eq 1 ] || continue
  args=(issue edit "$num" --repo "$repo")
  [ -z "$add" ] || args+=(--add-label "$add")
  [ -z "$rm" ] || args+=(--remove-label "$rm")
  gh "${args[@]}" >/dev/null 2>&1 || echo "issue-label-gate: could not edit $repo#$num" >&2
done <<<"$plan"
[ "$apply" -eq 1 ] || echo "issue-label-gate: dry run, pass --apply to write"
exit 0
