#!/usr/bin/env bash
# Guard: each minute saving in the 2026-11-21 audit report traces to a duration or rate the report quotes.
# The first Verdict FAIL named five estimates with no quoted basis (#1324, #1325, #1326, #1327, tsc).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
report="$root/docs/agents/audits/2026-11-21-team-audit.md"
fail=0
row() { grep -F "$1" "$report" | head -1; }
bad() { echo "FAIL: $1"; fail=1; }

for issue in '#1324' '#1325' '#1326' '#1327' 'tsc'; do
  case "$issue" in
    'tsc') line=$(grep -F 'head-checks-tsc.sh` | 145 min a week' "$report" | head -1) ;;
    *) line=$(row "| \`mingster/dotfiles$issue\` |" | head -1) ;;
  esac
  [ -n "$line" ] || { bad "no ranked row for $issue"; continue; }
  case "$line" in *"÷ 7"*) continue ;; esac
  case "$line" in *"min a day"*) bad "$issue still states 'min a day' with no ÷ 7 derivation: $line" ;; esac
done

grep -q '15 refusals a week.*2 min' "$report" || bad "#1324 does not tie 15 refusals a week to 2 min each"
grep -q '145 min a week.*21 min a day' "$report" || bad "tsc row does not show 145 min a week is about 21 min a day"
grep -q '395 s.*not estimated\|not estimated.*395 s' "$report" || bad "#1325 should say it is not estimated per day"
[ "$fail" -eq 0 ] && echo "ok: audit estimates trace to quoted figures"
exit "$fail"
