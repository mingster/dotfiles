#!/usr/bin/env bash
# A builder may send worker_done only when its PR head carries a "Review: PASS head=<sha>" comment (#1675).
# Usage: check-builder-review.sh [--repo owner/name] <pr> <head sha>
#        check-builder-review.sh [--repo owner/name] --worktree <dir>   (PR and head come from the branch in <dir>)
# Exit 0: the review exists, or --worktree finds no PR for the branch (nothing to review).
# Exit 1: no PASS at that head. The message names the fix: bash ~/dotfiles/script/pr-review.sh <pr> <sha>.
# Exit 2: usage. pr-review.sh starts a fresh cold reviewer, so a builder may and must run it itself.
set -euo pipefail

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

repo="" pr="" sha="" worktree=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --worktree) [ $# -ge 2 ] || usage; worktree=$2; shift 2 ;;
    *) if [ -z "$pr" ]; then pr=$1; elif [ -z "$sha" ]; then sha=$1; else usage; fi; shift ;;
  esac
done
if [ -n "$worktree" ]; then
  [ -z "$pr" ] || usage
elif [ -z "$pr" ] || [ -z "$sha" ]; then
  usage
fi

gh_args=(pr view)
[ -z "$pr" ] || gh_args+=("$pr")
[ -z "$repo" ] || gh_args+=(--repo "$repo")
gh_args+=(--json number,headRefOid,comments)
if [ -n "$worktree" ]; then
  json=$(cd "$worktree" && gh "${gh_args[@]}" 2>/dev/null) || exit 0
else
  json=$(gh "${gh_args[@]}" 2>/dev/null) || { echo "check-builder-review: cannot read PR $pr" >&2; exit 1; }
fi

head=$(jq -r '.headRefOid // empty' <<<"$json" | tr '[:upper:]' '[:lower:]')
[ -n "$pr" ] || pr=$(jq -r '.number // empty' <<<"$json")
[ -n "$sha" ] || sha=$head
sha=$(tr '[:upper:]' '[:lower:]' <<<"$sha")
fix="bash ~/dotfiles/script/pr-review.sh $pr $sha"

# The sha must be the head or a prefix of it (7 or more characters); a PASS for any other head does not count.
case "$head" in "$sha"*) [ "${#sha}" -ge 7 ] || head="" ;; *) head="" ;; esac
if [ -n "$head" ] && jq -r '.comments[].body' <<<"$json" | grep -qE "^Review: PASS head=$head"; then
  exit 0
fi
echo "check-builder-review: no 'Review: PASS head=$sha' comment on PR #$pr. Run the cold review yourself, then send worker_done:" >&2
echo "  $fix" >&2
echo "A FAIL means fix, push and rerun it until it passes." >&2
exit 1
