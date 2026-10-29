#!/usr/bin/env bash
# Proving suite for Verdict history preservation (issue #416).
# Real git, fake gh and orca from the shared fixture; nothing leaves the temp dir.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
mf_setup; trap mf_teardown EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
mkdir -p "$MF_TOPLEVEL"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MF_BIN/cleanup"; chmod +x "$MF_BIN/cleanup"
export LEAD_MERGE_CLEANUP="$MF_BIN/cleanup"
mf_orca_add_run run_a
mf_orca_add_worker run_a ctx_verify completed /w/v
mf_orca_add_worker run_a ctx_verify2 completed /w/v2
mf_orca_add_worker run_a ctx_author completed /w/a
cd "$MF_REPO" || exit 1

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
say() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ ($3)}"; fi; }

body=$'## Verification\n- Passed.'
new_pr() { mf_pr_add "$1" "vh$1" "$body" "script/vh$1.sh"; jq -r .headRefOid "$MF_GH_DIR/pr-$1.json"; }
post_checks() { gh pr comment "$1" --repo example/repo --body "Checks: PASS head=$2" >/dev/null; }
verdict() { bash "$here/post-verdict.sh" --repo example/repo --pr "$@" 2>&1; }
merge() { bash "$here/lead-merge.sh" --repo example/repo --pr "$1" --head "$2" "${@:3}" 2>&1; }
set_comment_url() {
  local pr=$1 idx=$2 url=$3
  local f="$MF_GH_DIR/pr-$pr.json"
  jq --argjson i "$idx" --arg u "$url" '.comments[$i].url = $u' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# 1. Proving requirement: zero PATCH or DELETE calls plus one linked correction
h=$(new_pr 51); post_checks 51 "$h"
# Initial malformed Verdict
verdict 51 --result PASS --head "$h" --verifier ctx_verify --author unknown >/dev/null
orig_url="https://example.test/pull/51#issuecomment-1"
set_comment_url 51 1 "$orig_url"

# Publish linked correction with original comment identity
out=$(verdict 51 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --correction "$orig_url"); code=$?
say "$code" "post-verdict publishes linked correction" "$out"

# Assert zero PATCH/DELETE calls occurred in GitHub log
if grep -iE '(PATCH|DELETE)' "$MF_GH_LOG"; then
  bad "found PATCH or DELETE in gh log"
else
  ok "zero PATCH/DELETE calls in gh log"
fi

# Assert comment history is preserved: both original and correction exist
comment_count=$(jq '.comments | length' "$MF_GH_DIR/pr-51.json")
if [ "$comment_count" -eq 3 ]; then
  ok "history preserved: Checks + original + correction present"
else
  bad "expected 3 comments, got $comment_count"
fi

# Assert the correction comment links to original comment identity
last_comment=$(jq -r '.comments[-1].body' "$MF_GH_DIR/pr-51.json")
if grep -qxF "Correction: $orig_url" <<<"$last_comment"; then
  ok "correction is linked to original comment identity"
else
  bad "missing linked correction: $last_comment"
fi

# 2. Exact-head acceptance under canonical policy
out=$(merge 51 "$h"); code=$?
if [ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out"; then
  ok "exact-head acceptance merges with corrected Verdict"
else
  bad "merge failed: $out"
fi

# 3. History preservation: FAIL cannot be erased without Elon countersign
h2=$(new_pr 52); post_checks 52 "$h2"
verdict 52 --result FAIL --head "$h2" --verifier ctx_verify --author ctx_author >/dev/null
fail_url="https://example.test/pull/52#issuecomment-1"
set_comment_url 52 1 "$fail_url"

# Reviewer attempts correction without countersign
verdict 52 --result PASS --head "$h2" --verifier ctx_verify2 --author ctx_author --correction "$fail_url" >/dev/null
out=$(merge 52 "$h2"); code=$?
if [ "$code" -ne 0 ] && grep -q 'conflicting PASS and FAIL' <<<"$out"; then
  ok "FAIL comment preserved in history; un-countersigned correction blocked"
else
  bad "FAIL was bypassed: $out"
fi

# With Elon countersign referencing original comment url, canonical policy accepts it
gh pr comment 52 --repo example/repo --body "Countersign: Elon head=$h2 reason=supersedes $fail_url" >/dev/null
out=$(merge 52 "$h2"); code=$?
if [ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out"; then
  ok "superseded FAIL retired by countersign, PR merges"
else
  bad "countersigned merge failed: $out"
fi

# 4. Stale heads fail closed
h3=$(new_pr 53); post_checks 53 "$h3"
verdict 53 --result PASS --head "$h3" --verifier ctx_verify --author ctx_author >/dev/null
# Advance branch with new commit (stale head)
echo "new work" >> "$MF_REPO/stale.txt"
git -C "$MF_REPO" checkout -q "vh53"
git -C "$MF_REPO" add "stale.txt"
git -C "$MF_REPO" commit -q -m "stale work"
git -C "$MF_REPO" push -q -f origin "vh53"
git -C "$MF_REPO" checkout -q main
new_h=$(git -C "$MF_REPO" rev-parse "vh53")
jq --arg nh "$new_h" '.headRefOid = $nh' "$MF_GH_DIR/pr-53.json" > "$MF_GH_DIR/pr-53.json.tmp" && mv "$MF_GH_DIR/pr-53.json.tmp" "$MF_GH_DIR/pr-53.json"
post_checks 53 "$new_h"
out=$(merge 53 "$new_h"); code=$?
if [ "$code" -ne 0 ] && grep -q 'missing passing verifier verdict' <<<"$out"; then
  ok "stale head fails closed"
else
  bad "stale head accepted: $out"
fi

# 5. Missing verifier identity fails closed
h4=$(new_pr 54); post_checks 54 "$h4"
verdict 54 --result PASS --head "$h4" --verifier ctx_ghost --author ctx_author >/dev/null
out=$(merge 54 "$h4"); code=$?
if [ "$code" -ne 0 ] && grep -q 'ctx_ghost is not a known dispatch' <<<"$out"; then
  ok "missing verifier identity fails closed"
else
  bad "unknown verifier accepted: $out"
fi

# 6. Missing author identity fails closed
h5=$(new_pr 55); post_checks 55 "$h5"
verdict 55 --result PASS --head "$h5" --verifier ctx_verify --author ctx_random >/dev/null
out=$(merge 55 "$h5"); code=$?
if [ "$code" -ne 0 ] && grep -q 'ctx_random is not a known dispatch' <<<"$out"; then
  ok "missing author identity fails closed"
else
  bad "unknown author accepted: $out"
fi

# 7. "test not run" stays pending
h6=$(new_pr 56)
verdict 56 --result PASS --head "$h6" --verifier ctx_verify --author ctx_author >/dev/null
out=$(merge 56 "$h6"); code=$?
if [ "$code" -ne 0 ] && grep -q 'missing current-head or containing-train Checks: PASS' <<<"$out"; then
  ok "test not run stays pending"
else
  bad "untested PR merged: $out"
fi

# Final check: across entire suite, zero PATCH or DELETE calls
if grep -iE '(PATCH|DELETE)' "$MF_GH_LOG"; then
  bad "found PATCH or DELETE in gh log at end of suite"
else
  ok "zero PATCH or DELETE calls across all tests"
fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
