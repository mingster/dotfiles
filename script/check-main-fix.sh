#!/usr/bin/env bash
# Refuse a PR body that lacks 'Fixes main: <run id>' when the PR fixes a 'main red: <run id>' issue (#1677).
# Usage: check-main-fix.sh --body-file <file> --issue-title "<title of the issue the PR closes>"
#        check-main-fix.sh --body-file <file> --issue-title "<title>" ...   (repeat --issue-title per issue)
# An issue whose title is not 'main red: <run id>' needs nothing. -h and --help print this Usage block.
set -euo pipefail
print_usage() { sed -n '/^# Usage:/,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
body_file="" titles=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --body-file) body_file=${2:?--body-file needs a value}; shift 2 ;;
    --issue-title) titles+=("${2:?--issue-title needs a value}"); shift 2 ;;
    *) echo "check-main-fix: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$body_file" ] && [ -f "$body_file" ] || { echo "check-main-fix: --body-file must name a file" >&2; exit 2; }
rc=0
for title in ${titles[@]+"${titles[@]}"}; do
  [[ "$title" =~ ^main\ red:\ ([0-9]+)$ ]] || continue
  id=${BASH_REMATCH[1]}
  grep -Eq "^Fixes main: ${id}[[:space:]]*\$" "$body_file" || { echo "check-main-fix: PR body needs the line 'Fixes main: $id' ('$title')" >&2; rc=1; }
done
exit "$rc"
