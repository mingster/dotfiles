#!/usr/bin/env bash
# List where files under a directory match a pattern, as file:line. Never prints the matched text.
# Usage: secrets-refs.sh <dir> <pattern>   (pattern is an extended regex, matched per line)
# Read only. Skips directories named secrets, .git and node_modules, and does not follow symlinks.
# The Bash guard lets this script, and only this one, take the credential folder's name as its pattern.
set -u
[ "$#" -eq 2 ] || { echo "Usage: $0 <dir> <pattern>" >&2; exit 2; }
dir=$1 pattern=$2
case $dir in -*) echo "secrets-refs: dir may not start with a dash" >&2; exit 2 ;; esac
[ -d "$dir" ] || { echo "secrets-refs: $dir is not a directory" >&2; exit 2; }
real=$(cd "$dir" && pwd -P) || exit 2
case "/$real/" in */secrets/*) echo "secrets-refs: refuses to search inside a secrets folder" >&2; exit 2 ;; esac
export SECRETS_REFS_PATTERN=$pattern
find "$real" \( -name secrets -o -name .git -o -name node_modules \) -prune -o -type f \
  -exec awk '$0 ~ ENVIRON["SECRETS_REFS_PATTERN"] { print FILENAME ":" FNR }' {} + 2>/dev/null
exit 0
