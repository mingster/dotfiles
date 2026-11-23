#!/usr/bin/env bash
# Refuse a PR body that does not match its title (#1688). Each issue number in the title needs the body to
# close or refer to it, and each number a closing keyword names must exist in this repo (a body pasted from
# another repo's PR fails here).
# Usage: check-pr-body-issues.sh --title "<PR title>" --body-file <file> [--pr <n>] [--repo <owner/name>]
#        --pr skips the PR's own number when the title ends with it (a squash title adds '(#<pr>)').
#        --repo defaults to the repo of the current checkout.
#        -h and --help print this Usage block.
# Exit 0: the body matches. Exit 1: refused, one line per problem on stderr. Exit 2: usage error.
# A lookup that fails for another reason than a 404 (auth, network) is a warning, never a refusal.
set -euo pipefail
print_usage() { sed -n '/^# Usage:/,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
usage_error() { echo "check-pr-body-issues: $1" >&2; exit 2; }

title="" body_file="" pr="" repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --title) [ $# -ge 2 ] || usage_error "--title needs a value"; title=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage_error "--body-file needs a value"; body_file=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || usage_error "--pr needs a value"; pr=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage_error "--repo needs a value"; repo=$2; shift 2 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$body_file" ] && [ -f "$body_file" ] || usage_error "--body-file must name a file"
repo_path=${repo:-'{owner}/{repo}'}

# '#N' as a whole token: not part of 'owner/repo#N' and not a longer number.
mentions() { grep -Eq "(^|[^A-Za-z0-9_/.-])#$1([^0-9]|\$)" "$body_file"; }

rc=0
title_numbers=$(grep -Eo '#[0-9]+' <<<"$title" | tr -d '#' | sort -un || true)
for n in $title_numbers; do
  [ "$n" = "${pr:-}" ] && continue
  mentions "$n" || { echo "check-pr-body-issues: title names #$n but the body neither closes nor refers to it" >&2; rc=1; }
done

closed_numbers=$(grep -Eio '(^|[^A-Za-z])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]:]+(#[0-9]+[ ,]*)+' "$body_file" |
  grep -Eo '#[0-9]+' | tr -d '#' | sort -un || true)
for n in $closed_numbers; do
  if err=$(gh api "repos/$repo_path/issues/$n" --jq .number 2>&1 >/dev/null); then
    continue
  fi
  if grep -q 'HTTP 404' <<<"$err"; then
    echo "check-pr-body-issues: body closes #$n, which is not an issue or PR in this repo" >&2
    rc=1
  else
    echo "check-pr-body-issues: could not look up #$n ($err), not refused" >&2
  fi
done

exit "$rc"
