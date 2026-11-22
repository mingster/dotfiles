#!/usr/bin/env bash
# statusline.sh writes the usage-gate rate limit files that script/usage-gate.py reads.
# Hermetic: temp HOME, asdf pinned. Covers the write, the day start baseline, and no rate_limits.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
mkdir -p "$HOME"
script="$root/.agents/claude/statusline.sh"
gate="$HOME/.claude/state/usage-gate"
limits="$gate/claude-rate-limits.json"
daystart="$gate/claude-day-start.json"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fails=$((fails + 1)); fi; }
run() { printf '%s' "$1" | bash "$script"; }
input='{"model":{"display_name":"Test"},"workspace":{"current_dir":"/x"},"rate_limits":{"seven_day":{"used_percentage":42}}}'

out=$(run "$input")
check "prints a line" "$(grep -c 'Test' <<<"$out")" "1"
check "limits file has the rate limit" "$(jq -r '.seven_day.used_percentage' "$limits")" "42"
check "limits file has _written_at" "$(jq -r '._written_at | type' "$limits")" "number"
check "day start file has _written_at" "$(jq -r '._written_at | type' "$daystart")" "number"
check "day start _date is today" "$(jq -r '._date' "$daystart")" "$(date +%F)"
check "no leftover tmp files" "$(ls "$gate" | grep -c '\.tmp$')" "0"

# Same day: the baseline is kept even when the reading changes.
jq -c '. + {_written_at: 1}' "$daystart" > "$daystart.x" && mv "$daystart.x" "$daystart"
run '{"rate_limits":{"seven_day":{"used_percentage":50}}}' >/dev/null
check "same day keeps day start" "$(jq -r '._written_at' "$daystart")" "1"
check "same day keeps its reading" "$(jq -r '.seven_day.used_percentage' "$daystart")" "42"
check "same day refreshes limits" "$(jq -r '.seven_day.used_percentage' "$limits")" "50"

# New day: the baseline is rewritten.
jq -c '. + {_date: "2000-01-01"}' "$daystart" > "$daystart.x" && mv "$daystart.x" "$daystart"
run '{"rate_limits":{"seven_day":{"used_percentage":60}}}' >/dev/null
check "new day rewrites _date" "$(jq -r '._date' "$daystart")" "$(date +%F)"
check "new day rewrites reading" "$(jq -r '.seven_day.used_percentage' "$daystart")" "60"

# No rate_limits: nothing written, a line still prints.
rm -rf "$HOME/.claude"
out=$(run '{"model":{"display_name":"Plain"}}')
check "no rate_limits still prints" "$(grep -c 'Plain' <<<"$out")" "1"
check "no rate_limits writes nothing" "$(ls "$HOME/.claude" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "$fails failed"
[ "$fails" -eq 0 ]
