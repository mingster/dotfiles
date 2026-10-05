#!/usr/bin/env bash
# Moves every changelog.d/*.md fragment (except README.md, sorted by file name) directly under the
# top "## [Unreleased]" heading of CHANGELOG.md, then deletes the fragments.
# No fragments: no change, exit 0. Missing heading: exit 1. Run from anywhere; paths are repo relative.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
DIR="$ROOT/changelog.d"

fragments=()
if [[ -d "$DIR" ]]; then
	while IFS= read -r f; do
		fragments+=("$f")
	done < <(find "$DIR" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | LC_ALL=C sort)
fi

if [[ ${#fragments[@]} -eq 0 ]]; then
	exit 0
fi

if [[ ! -f "$CHANGELOG" ]] || ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
	echo "changelog-compile: no '## [Unreleased]' heading in $CHANGELOG, nothing changed" >&2
	exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

inserted=0
while IFS= read -r line || [[ -n "$line" ]]; do
	printf '%s\n' "$line"
	if [[ "$inserted" -eq 0 && "$line" == '## [Unreleased]'* ]]; then
		for f in "${fragments[@]}"; do
			cat "$f"
			# A fragment without a trailing newline must not run into the next line.
			[[ -n "$(tail -c1 "$f")" ]] && printf '\n'
		done
		inserted=1
	fi
done <"$CHANGELOG" >"$tmp"

cat "$tmp" >"$CHANGELOG"
rm -f "${fragments[@]}"
echo "changelog-compile: inserted ${#fragments[@]} fragment(s) into CHANGELOG.md"
