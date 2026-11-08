#!/usr/bin/env bash
# Run before a hand merge of a protected path; this checks approval, never merges.
set -euo pipefail
refuse() { echo "protected-merge-check: refused: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || refuse "usage: protected-merge-check.sh <owner/repo> <pr>"
repo=$1 pr=$2
info=$(gh pr view "$pr" --repo "$repo" --json headRefOid,comments) || refuse "cannot read PR $pr"
head=$(jq -er '.headRefOid | select(type == "string" and test("^[0-9a-f]{40}$"))' <<<"$info") \
  || refuse "cannot read PR head"
commit=$(gh api "repos/$repo/commits/$head") || refuse "cannot read head commit date"
head_date=$(jq -er '.commit.committer.date | fromdateiso8601' <<<"$commit") \
  || refuse "invalid head commit committer date"
jq -e --argjson head_date "$head_date" '
  any(.comments[];
    (.body | split("\n")[0] | startswith("Owner go "))
    and (try ((.createdAt | fromdateiso8601) > $head_date) catch false))
' <<<"$info" >/dev/null || refuse "missing first-line Owner go comment posted after head commit $head"
echo "protected-merge-check: Owner go recorded after head commit $head"
