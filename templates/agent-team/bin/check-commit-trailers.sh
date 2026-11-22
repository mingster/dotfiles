#!/usr/bin/env bash
# Report commit trailers that git does not parse. A line such as 'Owner-approved: <name> <date>' that sits in an
# earlier paragraph than 'Co-Authored-By:' (a blank line between them) is not a trailer, so fleet-watch and the guard
# see the commit as unapproved. Callers only invoke this: the commit-msg hook and checks-local.sh.
# Usage: check-commit-trailers.sh <input>...
#   --file <path>      one commit message file (lines starting with '#' are comments)
#   --commits <range>  the message of each commit in <range>, for example origin/main..HEAD
# Trailer-looking lines are Owner-approved:, Co-Authored-By:, Refs: and Closes:, matched without regard to case.
# Each problem goes to stderr as '<source>:<line>: <message>'; stdout gets 'N checked, M problems'.
# Exit 0 clean, 1 problems, 2 usage error.
set -uo pipefail

usage() { echo "Usage: $0 [--file <path>]... [--commits <range>]" >&2; exit 2; }
commits="" files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --commits) [ $# -ge 2 ] || usage; commits=$2; shift 2 ;;
    --file) [ $# -ge 2 ] || usage; files+=("$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$commits" ] || [ "${#files[@]}" -gt 0 ] || usage

cd "$(dirname "$0")/.." || exit 2
checked=0 problems=0
looks_like_trailer='^(owner-approved|co-authored-by|refs|closes):'
# A line in a mixed paragraph counts as a trailer attempt only when its value has the shape of one.
ref_tok='([A-Za-z0-9_./-]*#[0-9]+|[0-9]+|https?://[^[:space:]]+)'
shaped_trailer() { # <lowercased line>
  case "$1" in
    owner-approved:*) [[ "$1" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*(\(.*\))?$ ]] ;;
    co-authored-by:*) [[ "$1" =~ \<[^\>]+\>[[:space:]]*$ ]] ;;
    *) [[ "${1#*:}" =~ ^[[:space:]]*${ref_tok}([,[:space:]]+${ref_tok})*[[:space:]]*$ ]] ;;
  esac
}

check_message() { # <source>; message on stdin
  local source=$1 raw parsed n=0 line low para=0 last=-1 i p gap=0
  local -a nums=() paras=() texts=() mixed=()
  raw=$(tr -d '\r')
  parsed=$(grep -v '^#' <<<"$raw" | git interpret-trailers --parse)
  checked=$((checked + 1))
  # Split into paragraphs; a comment line is not part of the message.
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "${line:0:1}" = "#" ] && continue
    if [ -z "${line//[[:space:]]/}" ]; then gap=1; continue; fi
    [ "$gap" -eq 1 ] && para=$((para + 1)); gap=0
    nums+=("$n"); paras+=("$para"); texts+=("$line"); last=$para
    low=$(tr '[:upper:]' '[:lower:]' <<<"$line")
    [[ "$low" =~ $looks_like_trailer ]] || mixed[para]=1
  done <<<"$raw"
  [ "$last" -ge 0 ] || return 0
  # Only the last paragraph, and the paragraphs right before it that hold nothing but trailer lines, are
  # trailer territory. A prose paragraph that happens to start with 'Closes:' earlier in the body is not.
  p=$last
  while [ "$p" -gt 0 ] && [ -z "${mixed[$((p - 1))]:-}" ] ; do p=$((p - 1)); done
  for i in "${!texts[@]}"; do
    line=${texts[$i]}
    low=$(tr '[:upper:]' '[:lower:]' <<<"$line")
    [[ "$low" =~ $looks_like_trailer ]] || continue
    # The paragraph right before the trailer block is where a misplaced trailer lands; only a line shaped like a
    # trailer counts there, so a prose line that opens with 'Closes:' stays prose.
    if [ "${paras[$i]}" -lt "$p" ]; then
      [ "${paras[$i]}" -eq $((p - 1)) ] && shaped_trailer "$low" || continue
    fi
    grep -qxF -- "$line" <<<"$parsed" && continue
    echo "$source:${nums[$i]}: not a git trailer (it must sit in the last paragraph, with no blank line before the next trailer); git does not parse it" >&2
    problems=$((problems + 1))
  done
}

if [ -n "$commits" ]; then
  shas=$(git rev-list "$commits" 2>/dev/null) || { echo "check-commit-trailers: bad commit range $commits" >&2; exit 2; }
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    check_message "${sha:0:12}" < <(git show -s --format=%B "$sha")
  done <<<"$shas"
fi
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || { echo "check-commit-trailers: no such file: $f" >&2; exit 2; }
  check_message "$f" <"$f"
done
echo "$checked checked, $problems problems"
[ "$problems" -eq 0 ]
