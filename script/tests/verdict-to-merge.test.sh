#!/usr/bin/env bash
# verdict-to-merge.py: percentiles, buckets, causes and the --split groups from a fixture (#1731).
set -u
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../verdict-to-merge.py"
pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
h1=$(printf 'a%.0s' {1..40}); h2=$(printf 'b%.0s' {1..40}); h3=$(printf 'c%.0s' {1..40}); h4=$(printf 'd%.0s' {1..40})
cat >"$tmp/f.json" <<JSON
{"prs": [
 {"number": 1, "mergedAt": "2026-11-23T10:00:30Z", "headRefOid": "$h1",
  "comments": [{"createdAt": "2026-11-23T10:00:00Z", "body": "Verdict: PASS head=$h1 verifier=ctx_a author=unknown"}]},
 {"number": 2, "mergedAt": "2026-11-23T11:07:00Z", "headRefOid": "$h2",
  "comments": [{"createdAt": "2026-11-23T11:00:00Z", "body": "Verdict: PASS+NOTES head=$h2 verifier=ctx_a author=unknown"}]},
 {"number": 3, "mergedAt": "2026-11-23T13:00:00Z", "headRefOid": "$h3",
  "comments": [{"createdAt": "2026-11-23T12:00:00Z", "body": "Verdict: PASS head=$h3 verifier=ctx_a author=unknown"}]},
 {"number": 4, "mergedAt": "2026-11-23T20:00:00Z", "headRefOid": "$h4",
  "comments": [{"createdAt": "2026-11-23T19:00:00Z", "body": "Verdict: FAIL head=$h4 verifier=ctx_a author=unknown"},
               {"createdAt": "2026-11-23T19:30:00Z", "body": "Verdict: PASS head=$h3 verifier=ctx_a author=unknown"}]}
 ],
 "main_runs": [{"createdAt": "2026-11-23T12:10:00Z", "updatedAt": "2026-11-23T12:20:00Z", "conclusion": "failure"}]}
JSON
out=$(python3 "$tool" --fixture "$tmp/f.json" --json) || { bad "run failed: $out"; echo "passed=$pass failed=$fail"; exit 1; }
jq -e '.all.n == 3 and ."no-verdict-at-head" == 1' <<<"$out" >/dev/null && ok "counts PRs with a Verdict at the merged head, the rest are named" || bad "counts: $out"
jq -e '.all.max == 60 and .all.buckets["<1"] == 1 and .all.buckets["5-10"] == 1 and .all.buckets[">=30"] == 1' <<<"$out" >/dev/null && ok "max and buckets" || bad "buckets: $out"
jq -e '.all.causes == {"ship-at-verdict":1,"waited-for-pass":1,"main-red":1}' <<<"$out" >/dev/null && ok "causes: verifier, pass, main red" || bad "causes: $out"
out=$(python3 "$tool" --fixture "$tmp/f.json" --json --split 2026-11-23T11:30:00Z)
jq -e '.before.n == 2 and .after.n == 1 and .after.slowest[0].pr == 3' <<<"$out" >/dev/null && ok "--split groups by Verdict time" || bad "split: $out"
python3 "$tool" --help | grep -q '^Usage:' && ok "--help prints usage" || bad "--help"
python3 "$tool" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no source exits 2" || bad "no source"
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
