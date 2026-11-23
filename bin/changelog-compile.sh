#!/usr/bin/env bash
# Compile changelog.d/*.md fragments into CHANGELOG.md, directly under the top
# "## [Unreleased]" heading, then delete the fragments. README.md is skipped.
# Run from the repo root. No fragments: no change. Missing heading: exit 1.
# Usage: changelog-compile.sh [-h|--help]
#   -h, --help  print this usage to stdout and exit 0; any other argument prints it to stderr and exits 2.
set -eu

usage() { sed -n '/^# Usage:/,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"; }
[ "$#" -le 1 ] || { usage >&2; exit 2; }
case "${1-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
DIR="${FRAGMENTS_DIR:-changelog.d}"
export LC_ALL=C

frags=()
if [ -d "$DIR" ]; then
  for f in "$DIR"/*.md; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    frags+=("$f")
  done
fi
[ "${#frags[@]}" -eq 0 ] && exit 0

line="$(grep -n '^## \[Unreleased\]' "$CHANGELOG" | head -1 | cut -d: -f1 || true)"
if [ -z "$line" ]; then
  echo "changelog-compile: no '## [Unreleased]' heading in $CHANGELOG" >&2
  exit 1
fi

tmp="$(mktemp)"
{
  head -n "$line" "$CHANGELOG"
  for f in "${frags[@]}"; do
    cat "$f"
    [ -n "$(tail -c1 "$f")" ] && echo
  done
  tail -n +"$((line + 1))" "$CHANGELOG"
} > "$tmp"
cat "$tmp" > "$CHANGELOG"
rm -f "$tmp" "${frags[@]}"
echo "changelog-compile: merged ${#frags[@]} fragment(s) into $CHANGELOG"
