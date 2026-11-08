#!/usr/bin/env bash
# Tests for team-audit.sh (--log, --report --times).
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

fixture="$tmp/fixture.tsv"
cat > "$fixture" <<'EOF'
stage	minutes	verified
queue	4	1
queue	8	1
queue	12	0
queue	20	1
build	10	1
build	20	1
build	30	1
build	40	0
build	80	1
merge	5	1
merge	15	0
EOF

rep=$(bash "$here/team-audit.sh" --report --times "$fixture" 2>&1)
rc_rep=$?
assert_ok "--report --times exits 0" test "$rc_rep" -eq 0
assert_ok "--report prints Problems with evidence section" grep -qE '^## Problems with evidence' <<<"$rep"
assert_ok "--report lists logged problem and evidence" grep -qE 'role-skill-mismatch.*PR #101' <<<"$rep"
assert_ok "--report prints Proposals with a recommended option section" grep -qE '^## Proposals with a recommended option' <<<"$rep"
assert_ok "--report includes a recommended option" grep -qi 'Recommended: Option A' <<<"$rep"
assert_ok "--report prints Stage times section" grep -qE '^## Stage times' <<<"$rep"
assert_ok "--report prints sample and verified totals" grep -qE 'Samples: 11, verified: 8' <<<"$rep"
assert_ok "--report computes queue median=10 p75=12 max=20 samples=4 verified=3" grep -qE '\| *queue *\| *10 *\| *12 *\| *20 *\| *4 *\| *3 *\|' <<<"$rep"
assert_ok "--report computes build median=30 p75=40 max=80 samples=5 verified=4" grep -qE '\| *build *\| *30 *\| *40 *\| *80 *\| *5 *\| *4 *\|' <<<"$rep"
assert_ok "--report computes merge median=10 p75=15 max=15 samples=2 verified=1" grep -qE '\| *merge *\| *10 *\| *15 *\| *15 *\| *2 *\| *1 *\|' <<<"$rep"

bash "$here/team-audit.sh" --log "only-one-arg" >/dev/null 2>&1
rc_bad=$?
assert_ok "--log with missing evidence exits 2" test "$rc_bad" -eq 2

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
