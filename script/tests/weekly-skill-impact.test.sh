#!/usr/bin/env bash
# weekly-skill-impact.sh cites the real pstack-attribution.md and writes one section per slice (#1528).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tests=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

d="$tmp/dotfiles"
mkdir -p "$d/docs/agents" "$d/.agents/skills" "$d/templates/agent-team/docs/agents"
printf 'The pin doc cites poteto-mode.\n' >"$d/templates/agent-team/docs/agents/pstack-attribution.md"
printf 'skills=grilling\n' >"$d/.agents/skills/.mattpocock-upstream"
printf 'mentions grilling\n' >"$d/docs/agents/sdlc-skill-map.md"
out="$d/docs/agents/drafts/weekly-skill-impact-20260101.md"
run() { DOTFILES="$d" DATE_TAG=20260101 WEEKLY_SKILL_IMPACT_SLICE=$1 bash "$root/script/weekly-skill-impact.sh" 2>&1; }
count() { grep -c "^## $1" "$out" || true; }

# pstack slice alone, run twice: citation line present, one section.
run pstack >/dev/null
run pstack >/dev/null
grep -q 'templates/agent-team/docs/agents/pstack-attribution.md` cites `poteto-mode`' "$out" \
  || fail 'pstack-attribution.md citation missing'
[[ "$(count 'pstack template skills')" == 1 ]] || fail 'pstack section duplicated on a rerun'
tests=$((tests + 1))

# mattpocock then pstack, then both again: one section per slice.
run mattpocock >/dev/null
run pstack >/dev/null
run pstack >/dev/null
[[ "$(count 'pstack template skills')" == 1 ]] || fail 'pstack section duplicated after mattpocock'
[[ "$(count 'Matt Pocock vendored skills')" == 1 ]] || fail 'mattpocock section duplicated'
grep -q 'sdlc-skill-map.md` cites `grilling`' "$out" || fail 'mattpocock citation missing'
tests=$((tests + 1))

# A missing citation root warns instead of skipping silently.
rm "$d/docs/agents/sdlc-skill-map.md"
msg=$(run pstack)
[[ "$msg" == *WARN*sdlc-skill-map.md* ]] || fail "no WARN for a missing root: $msg"
tests=$((tests + 1))

printf 'PASS: %s tests\n' "$tests"
