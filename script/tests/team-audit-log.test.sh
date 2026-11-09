#!/usr/bin/env bash
# Tests for team-audit.sh --log (the TSV observation log). --report is covered in team-audit.test.sh.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "ok   $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name"
  fi
}

log="$tmp/team-observations.tsv"
export TEAM_AUDIT_LOG="$log"

out1=$(bash "$here/team-audit.sh" --log "role-skill-mismatch" "PR #101" 2>&1)
rc1=$?
assert_ok "--log first call exits 0" test "$rc1" -eq 0
assert_ok "--log first call does not print promote" test -z "$out1"
assert_ok "--log first call writes one row with count 1" test "$(wc -l < "$log" | tr -d ' ')" -eq 1 -a "$(awk -F'\t' 'NR==1 {print $4}' "$log")" = "1"

out2=$(bash "$here/team-audit.sh" --log "role-skill-mismatch" "PR #102" 2>&1)
rc2=$?
assert_ok "--log second call with same finding exits 0" test "$rc2" -eq 0
assert_ok "--log second call prints promote line" grep -qF "promote: open a fix ticket for role-skill-mismatch" <<<"$out2"
assert_ok "--log twice with one finding gives one row with count 2" test "$(wc -l < "$log" | tr -d ' ')" -eq 1 -a "$(awk -F'\t' 'NR==1 {print $2 "|" $4 "|" $5 "|" $6}' "$log")" = "role-skill-mismatch|2|-|open"

bash "$here/team-audit.sh" --log "label-conflict" "issue #55" >/dev/null 2>&1
rc3=$?
assert_ok "--log with a second finding adds a second row with count 1" test "$rc3" -eq 0 -a "$(wc -l < "$log" | tr -d ' ')" -eq 2 -a "$(awk -F'\t' 'NR==2 {print $2 "|" $4}' "$log")" = "label-conflict|1"

bash "$here/team-audit.sh" --log "only-one-arg" >/dev/null 2>&1
rc_bad=$?
assert_ok "--log with missing evidence exits 2" test "$rc_bad" -eq 2

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
