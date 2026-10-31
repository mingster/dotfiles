#!/usr/bin/env bash
# Validate a PR body file for coordinator publication (exactly three Verification bullets).
# Usage: validate-publication-body.sh <body-file>
# Exits 0 on success; prints "coordinator-publication: refused: …" on stderr and exits 1.
set -euo pipefail

refuse() { echo "coordinator-publication: refused: $*" >&2; exit 1; }

[ $# -eq 1 ] || refuse "usage: validate-publication-body.sh <body-file>"
[ -f "$1" ] || refuse "body file not found: $1"

body=$(cat "$1")
[ -n "$body" ] || refuse "empty PR body"

if grep -qiE 'generated with (claude code|cursor)|co-authored-by:' <<<"$body"; then
  refuse "tool credit is forbidden in the PR body"
fi

normalized_body=$(awk '
/^[[:blank:]]*#+[[:space:]]/ {
  heading=$0; sub(/^[[:blank:]]*/, "", heading)
  hashes=heading; sub(/[[:space:]].*$/, "", hashes)
  title=heading; sub(/^#+[[:space:]]+/, "", title)
  gsub(/[[:space:]]+/, " ", title)
  sub(/[[:space:][:punct:]]+$/, "", title)
  print hashes " " tolower(title); next
}
{print}' <<<"$body")

if grep -qiE '^#{1,6} test plan$' <<<"$normalized_body"; then
  refuse "Test plan heading is forbidden"
fi

if ! grep -qE '^## verification$' <<<"$normalized_body"; then
  refuse "missing ## Verification heading with exactly three bullets"
fi

bullet_count=$(awk '/^## verification$/ {inside=1; next} inside && /^#+ / {inside=0} inside && /^[[:space:]]*[-*+] / {n++} END {print n+0}' <<<"$normalized_body")
[ "$bullet_count" -eq 3 ] || refuse "Verification needs exactly three run and outcome bullets (found $bullet_count)"

closes_directive_count() {
  local matches
  matches=$(
    grep -oiE '(^|[^[:alnum:]_])closes[[:space:]]*:[[:space:]]*|(^|[^[:alnum:]_])closes[[:space:]]+(#[0-9]+|https?://|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)' <<<"$1" 2>/dev/null || true
  )
  if [ -z "$matches" ]; then
    printf '0'
  else
    printf '%s\n' "$matches" | wc -l | tr -d ' '
  fi
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  n=$(closes_directive_count "$line")
  [ "$n" -eq 0 ] && continue
  [ "$n" -eq 1 ] || refuse "each Closes line must reference at most one issue"
  if ! grep -qE '^Closes #[0-9]+$' <<<"$line"; then
    refuse "Closes lines must be exactly one issue per line (Closes #N)"
  fi
done <<<"$body"
