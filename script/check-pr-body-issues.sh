#!/usr/bin/env bash
# check-pr-body-issues.sh: a PR body must close or refer to every issue number its title names, and must
# not close a number that does not exist in this repo. A body pasted from another repo fails here (#1688).
# Usage: check-pr-body-issues.sh --title <title> --body-file <file> [--repo <owner/name>]
# Exit 0: ok. Exit 1: refused, one line per problem on stderr. Exit 2: usage.
# The repo defaults to the current one (gh repo view). Without a repo the existence check is skipped
# and a SKIPPED line says so. A lookup that fails for another reason is also SKIPPED, not refused.
set -euo pipefail
usage() { echo "usage: check-pr-body-issues.sh --title <title> --body-file <file> [--repo <owner/name>]" >&2; exit 2; }

title="" body_file="" repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage; body_file=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$body_file" ] && [ -f "$body_file" ] || usage

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
repo_lc=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')

# One line per reference in the body: "<qualifier>|<number>|<close|refer>". A qualifier is owner/name
# from "owner/name#N"; empty when the reference is bare. Lowercased so the repo compares cleanly.
kw_re='(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve|refs)'
ref_re='([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+'
list_re="(^|[^A-Za-z])${kw_re}:?[[:space:]]+(${ref_re}[[:space:],]*)+"
refs=""
while IFS= read -r match; do
  [ -n "$match" ] || continue
  match=$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[^a-z]+//')
  kind=refer
  case "${match%%[^a-z]*}" in
    close|closed|closes|fix|fixed|fixes|resolve|resolved|resolves) kind=close ;;
  esac
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    refs="$refs${ref%%#*}|${ref##*#}|$kind
"
  done < <(printf '%s' "$match" | grep -Eo "$ref_re" || true)
done < <(grep -Eio "$list_re" "$body_file" || true)

# A reference counts for this repo when it is bare or names this repo. With no repo known, any reference counts.
rc=0
title_nums=$(printf '%s\n' "$title" | grep -Eo '#[0-9]+' | tr -d '#' | sort -u || true)
for n in $title_nums; do
  if ! printf '%s' "$refs" | awk -F'|' -v r="$repo_lc" -v n="$n" '$2 == n && ($1 == "" || r == "" || $1 == r) { f = 1 } END { exit !f }'; then
    echo "check-pr-body-issues: the title names #$n but the body neither closes nor refers to it" >&2
    rc=1
  fi
done

close_nums=$(printf '%s' "$refs" | awk -F'|' -v r="$repo_lc" '$3 == "close" && ($1 == "" || $1 == r) { print $2 }' | sort -u || true)
if [ -n "$close_nums" ]; then
  if [ -z "$repo" ]; then
    echo "check-pr-body-issues: SKIPPED the existence check, no repo to look in" >&2
  else
    for n in $close_nums; do
      if out=$(gh api "repos/$repo/issues/$n" --jq .number 2>&1); then
        continue
      fi
      if grep -Eqi 'HTTP 404|not found' <<<"$out"; then
        echo "check-pr-body-issues: the body closes #$n, which does not exist in $repo (another repo's number?)" >&2
        rc=1
      else
        echo "check-pr-body-issues: SKIPPED #$n, could not check it in $repo: $out" >&2
      fi
    done
  fi
fi
exit "$rc"
