#!/usr/bin/env bash
# Refuse work whose "Allowed files" overlap another issue in progress or an open PR (#1678).
# Usage: check-issue-overlap.sh [--repo owner/name] [--spec <brief file>] <issue>
# Reads the Allowed files of <issue> (or of --spec, a brief), then those of the other open issues labeled
# status:進行中 and the file lists of open PRs (a PR that closes or refs <issue> is its own work, skipped).
# Prints each overlap and exits 1 on any. Exit 0: none. Exit 2: usage.
# Also warns (stderr, exit unchanged) when the Allowed files mix owner-reviewed files with code (#1748): file two issues.
# An entry that ends in / covers every file under it. Bundle overlapping work into one issue.
set -euo pipefail
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

repo="" spec="" issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --spec) [ $# -ge 2 ] || usage; spec=$2; shift 2 ;;
    *) [ -z "$issue" ] || usage; issue=${1#\#}; shift ;;
  esac
done
case "$issue" in ''|*[!0-9]*) usage ;; esac
r=(); [ -z "$repo" ] || r=(-R "$repo")

# Paths named under "## Allowed files" or on an "Allowed files:" line, one per line.
allowed_files() { # reads a body on stdin
  awk '
    { sub(/\r$/, "") }
    /^## Allowed files/ { sec = 1; next }
    /^\*\*Allowed files:\*\*|^Allowed files:/ { sec = 1; line = $0; sub(/^\*\*Allowed files:\*\*|^Allowed files:/, "", line); print line; next }
    /^#+ / || /^\*\*[^*]+:\*\*/ { sec = 0 }
    sec { print }
  ' | tr '`",'"'"'' '    ' | tr -s '[:space:]' '\n' | sed -e 's/[.;:)]*$//' -e 's|^\./||' \
    | grep -E '/|\.[A-Za-z0-9]+$' | awk '!seen[$0]++' || true
}

covers() { # <a> <b>: same path, or one is a directory entry above the other
  [ "$1" = "$2" ] && return 0
  case "$1" in */) case "$2" in "$1"*) return 0 ;; esac ;; esac
  case "$2" in */) case "$1" in "$2"*) return 0 ;; esac ;; esac
  return 1
}

# The brief may omit the issue's Allowed files, so use both.
mine=$(gh issue view "$issue" ${r[@]+"${r[@]}"} --json body -q .body 2>/dev/null | allowed_files) || mine=""
if [ -n "$spec" ]; then
  [ -f "$spec" ] || usage
  mine=$(printf '%s\n%s\n' "$mine" "$(allowed_files <"$spec")" | awk 'NF && !seen[$0]++')
fi
[ -n "$mine" ] || exit 0

# Owner-reviewed paths come from the ship.sh path rules, so the two cannot drift.
# shellcheck source=lib/protected-paths.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/protected-paths.sh"
owner_files="" code_files=""
while IFS= read -r a; do
  [ -n "$a" ] || continue
  if owner_only_path "$a" || protected_path "$a" || [ "$a" = templates/agent-team/docs/agents/team.md ]; then owner_files+="$a "
  else case "$a" in *.md|changelog.d/*) ;; *) code_files+="$a " ;; esac; fi
done <<<"$mine"
if [ -n "$owner_files" ] && [ -n "$code_files" ]; then
  echo "warning: Allowed files mix owner-reviewed files (${owner_files% }) with code (${code_files% })." >&2
  echo "warning: File two issues: the code one first, the owner-reviewed one blocked by it (team.md, Issue budget)." >&2
fi

found=0
report() { # <path> <what>
  echo "overlap: $1 is also in $2" >&2
  found=1
}

inflight=$(gh issue list ${r[@]+"${r[@]}"} --state open --label 'status:進行中' --limit 100 --json number,body 2>/dev/null) || inflight='[]'
while IFS= read -r num; do
  [ -n "$num" ] && [ "$num" != "$issue" ] || continue
  theirs=$(jq -r --argjson n "$num" '.[] | select(.number == $n) | .body // ""' <<<"$inflight" | allowed_files)
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if covers "$a" "$b"; then report "$a" "the Allowed files of in-progress issue #$num"; break; fi
    done <<<"$theirs"
  done <<<"$mine"
done < <(jq -r '.[].number' <<<"$inflight")

prs=$(gh pr list ${r[@]+"${r[@]}"} --state open --limit 100 --json number,body,files 2>/dev/null) || prs='[]'
while IFS= read -r num; do
  [ -n "$num" ] || continue
  own=$(jq -r --argjson n "$num" --arg i "$issue" '.[] | select(.number == $n) | (.body // "") | test("#" + $i + "([^0-9]|$)")' <<<"$prs")
  [ "$own" != true ] || continue
  files=$(jq -r --argjson n "$num" '.[] | select(.number == $n) | .files[]?.path' <<<"$prs")
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if covers "$a" "$b"; then report "$b" "open PR #$num (it touches $b; allowed here: $a)"; break; fi
    done <<<"$files"
  done <<<"$mine"
done < <(jq -r '.[].number' <<<"$prs")

if [ "$found" -ne 0 ]; then
  echo "check-issue-overlap: refused. Bundle the overlapping work into one issue, or wait for the other to merge." >&2
  exit 1
fi
