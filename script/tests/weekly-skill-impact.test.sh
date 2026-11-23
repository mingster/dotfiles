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

# A citation is a whole word: "triaged" does not cite triage, "/triage" does (#1572).
printf 'skills=triage to-spec\n' >"$d/.agents/skills/.mattpocock-upstream"
printf 'The bug was triaged and a to-specific note.\n' >"$d/docs/agents/sdlc-skill-map.md"
run mattpocock >/dev/null
! grep -q 'sdlc-skill-map.md` cites `triage`' "$out" || fail 'triaged counted as a citation of triage'
! grep -q 'sdlc-skill-map.md` cites `to-spec`' "$out" || fail 'to-specific counted as a citation of to-spec'
printf 'Run /triage then /to-spec.\n' >"$d/docs/agents/sdlc-skill-map.md"
run mattpocock >/dev/null
grep -q 'sdlc-skill-map.md` cites `triage`' "$out" || fail '/triage not counted as a citation'
grep -q 'sdlc-skill-map.md` cites `to-spec`' "$out" || fail '/to-spec not counted as a citation'
tests=$((tests + 1))

# -h and --help print usage and exit 0, any other argument or an unknown slice exits 2, and none of them writes (#1622).
w="$tmp/dotfiles-args"
mkdir -p "$w"
args_run() { DOTFILES="$w" DATE_TAG=20260101 WEEKLY_SKILL_IMPACT_SLICE="${SLICE_VALUE:-pstack}" bash "$root/script/weekly-skill-impact.sh" "$@" 2>&1; }
for flag in -h --help; do
  rc=0; msg=$(args_run "$flag") || rc=$?
  [[ "$rc" == 0 && "$msg" == *Usage:* ]] || fail "$flag should print usage and exit 0 ($rc, $msg)"
  [[ -z "$(ls -A "$w")" ]] || fail "$flag wrote into DOTFILES"
done
for bad in --bogus extra; do
  rc=0; msg=$(args_run "$bad") || rc=$?
  [[ "$rc" == 2 && "$msg" == *Usage:* ]] || fail "$bad should exit 2 with usage ($rc, $msg)"
  [[ -z "$(ls -A "$w")" ]] || fail "$bad wrote into DOTFILES"
done
rc=0; msg=$(SLICE_VALUE=nope args_run) || rc=$?
[[ "$rc" == 2 && "$msg" == *"unknown slice nope"* ]] || fail "an unknown slice should exit 2 ($rc, $msg)"
[[ -z "$(ls -A "$w")" ]] || fail "an unknown slice wrote into DOTFILES"
tests=$((tests + 1))

printf 'PASS: %s tests\n' "$tests"
