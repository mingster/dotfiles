#!/usr/bin/env bash
# Print every hook command in a Claude settings file that points at a $HOME/dotfiles/script path that no longer exists.
# Usage: check-hook-paths.sh [settings.json] | -h | --help   (default ~/.claude/settings.json)
# Prints "stale hook <event>: <path>" per hit and exits 1 when any is found. Prints no other settings value.
set -u
case "${1:-}" in -h | --help) echo "Usage: check-hook-paths.sh [settings.json] | -h | --help   (default ~/.claude/settings.json)"; exit 0 ;; esac
f=${1:-$HOME/.claude/settings.json}
command -v jq >/dev/null || { echo 'check-hook-paths requires jq' >&2; exit 2; }
[ -f "$f" ] || { echo "no settings file: $f" >&2; exit 2; }
rows=$(jq -r '(.hooks // {}) | to_entries[] | .key as $e | (.value[]? | .hooks[]? | .command? // empty) | "\($e)\t\(.)"' "$f" 2>/dev/null) \
  || { echo "unreadable settings file: $f" >&2; exit 2; }
rc=0
while IFS=$'\t' read -r event cmd; do
  [ -n "$cmd" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    real=$(printf '%s' "$p" | sed -E "s#^(\\\$\{HOME\}|\\\$HOME|~)#$HOME#")
    if [ ! -e "$real" ]; then
      echo "stale hook $event: $p"
      rc=1
    fi
  done < <(printf '%s\n' "$cmd" | grep -oE '(\$\{HOME\}|\$HOME|~)/dotfiles/script/[A-Za-z0-9._/-]+')
done <<<"$rows"
exit "$rc"
