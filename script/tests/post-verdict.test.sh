#!/usr/bin/env bash
# T21 (spec #286, R6): post-verdict.sh output is what lead-merge.sh parses, for PASS, PASS+NOTES and FAIL.
# Real git, fake gh and orca from the shared fixture; nothing leaves the temp dir.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
mf_setup; trap mf_teardown EXIT
export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
mkdir -p "$MF_TOPLEVEL"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MF_BIN/cleanup"; chmod +x "$MF_BIN/cleanup"
export LEAD_MERGE_CLEANUP="$MF_BIN/cleanup"
mf_orca_add_run run_a; mf_orca_add_worker run_a ctx_verify completed /w/v; mf_orca_add_worker run_a ctx_author completed /w/a
cd "$MF_REPO" || exit 1

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
say() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ ($3)}"; fi; }

body=$'## Verification\n- Passed.'
new_pr() { mf_pr_add "$1" "pv$1" "$body" "script/pv$1.sh"; jq -r .headRefOid "$MF_GH_DIR/pr-$1.json"; }
post_checks() { gh pr comment "$1" --repo example/repo --body "Checks: PASS head=$2" >/dev/null; }
verdict() { bash "$here/post-verdict.sh" --repo example/repo --pr "$@" 2>&1; }
merge() { bash "$here/lead-merge.sh" --repo example/repo --pr "$1" --head "$2" "${@:3}" 2>&1; }
first_line() { jq -r '[.comments[] | select(.body | startswith("Verdict:"))][-1].body | split("\n")[0]' "$MF_GH_DIR/pr-$1.json"; }

# PASS
h=$(new_pr 41); post_checks 41 "$h"
out=$(verdict 41 --result PASS --head "$h" --verifier ctx_verify --author ctx_author); code=$?
say "$code" "PASS: helper posts" "$out"
[ "$(first_line 41)" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" ] && ok "PASS: first line is exactly the parsed form" || bad "PASS line: $(first_line 41)"
out=$(merge 41 "$h"); code=$?
[ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out" && ok "PASS: lead-merge accepts it" || bad "PASS merge: $out"

# PASS+NOTES with a Command line and free text below the first line
h=$(new_pr 42); post_checks 42 "$h"
verdict 42 --result PASS+NOTES --head "$h" --verifier ctx_verify --author ctx_author --command "bun test a.test.ts" --notes "Unchecked paths covered by hand." >/dev/null
[ "$(first_line 42)" = "Verdict: PASS+NOTES head=$h verifier=ctx_verify author=ctx_author" ] && ok "PASS+NOTES: first line parsed form" || bad "NOTES line: $(first_line 42)"
jq -r '.comments[-1].body' "$MF_GH_DIR/pr-42.json" | grep -qx 'Command: bun test a.test.ts' && ok "PASS+NOTES: Command line present" || bad "no Command line"
out=$(merge 42 "$h" --verify-command "bun test a.test.ts"); code=$?
[ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out" && ok "PASS+NOTES: lead-merge accepts it and matches the Command" || bad "NOTES merge: $out"

# FAIL is read as a FAIL: next to a later PASS it conflicts instead of being ignored
h=$(new_pr 43); post_checks 43 "$h"
verdict 43 --result FAIL --head "$h" --verifier ctx_other --author ctx_author >/dev/null
mf_orca_add_worker run_a ctx_other completed /w/o
out=$(merge 43 "$h"); code=$?
[ "$code" -eq 1 ] && ! grep -q 'ignored Verdict' <<<"$out" && ok "FAIL: parsed, not named as ignored" || bad "FAIL alone: $out"
verdict 43 --result PASS --head "$h" --verifier ctx_verify --author ctx_author >/dev/null
out=$(merge 43 "$h"); code=$?
[ "$code" -eq 1 ] && grep -q 'conflicting PASS and FAIL' <<<"$out" && ok "FAIL: counted as a FAIL next to a PASS" || bad "FAIL+PASS: $out"

# Bad flags post nothing
h=$(new_pr 44); before=$(jq '.comments|length' "$MF_GH_DIR/pr-44.json")
for args in "--result MAYBE --head $h --verifier ctx_verify --author ctx_author" \
            "--result PASS --head abc123 --verifier ctx_verify --author ctx_author" \
            "--result PASS --head $h --verifier ctx_verify --author ctx_verify" \
            "--result PASS --head $h --verifier bad\$id --author ctx_author" \
            "--result PASS --head $h --verifier ctx_verify"; do
  # shellcheck disable=SC2086
  out=$(verdict 44 $args); code=$?
  [ "$code" -ne 0 ] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-44.json")" = "$before" ] && ok "refuses: ${args%% --head*}${args##*--head $h}" || bad "bad flags posted or exited 0: $args"
done

# --print builds the body without posting
h=$(new_pr 45)
out=$(verdict 45 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --print); code=$?
[ "$code" -eq 0 ] && [ "$(head -1 <<<"$out")" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" ] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-45.json")" = 0 ] && ok "--print shows the body and posts nothing" || bad "--print: $out"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
