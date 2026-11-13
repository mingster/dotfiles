#!/usr/bin/env bash
# Hermetic tests for script/ship.sh (ticket T3, issue #717).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
# shellcheck disable=SC1091
. "$here/tests/lib/merge-fixture.sh"

mf_setup
trap mf_teardown EXIT
cd "$MF_REPO" || exit 1

# ship.sh calls Orca only to set the board status after a merge: the stub logs every call and exits ORCA_FAKE_RC (default 0).
printf '#!/usr/bin/env bash\necho "$*" >> "%s/orca-called"\nexit "${ORCA_FAKE_RC:-0}"\n' "$MF_DIR" > "$MF_DIR/fake-orca"
chmod +x "$MF_DIR/fake-orca"
export ORCA_CLI_COMMAND="$MF_DIR/fake-orca"

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

set_checks() { # <pr> <json array>
  local f="$MF_GH_DIR/pr-$1.json"
  jq --argjson c "$2" '.statusCheckRollup = $c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

green_checks='[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"COMPLETED","conclusion":"SUCCESS"}]'

post_verdict() { # <pr> <result> <head> [verifier] [author] [agent/model, default claude/opus; "none" omits it]
  local n=$1 res=$2 h=$3 v=${4:-ctx_verifier} a=${5:-ctx_author} am=${6:-claude/opus} suffix=""
  [ "$am" = none ] || suffix=" agent=${am%%/*} model=${am#*/}"
  gh pr comment "$n" --repo example/repo --body "Verdict: $res head=$h verifier=$v author=$a$suffix" >/dev/null
}

# The builder's own record on the PR: one body line. The head argument is unused (the old Self-review gate is gone).
mf_self_review() { # <pr> <head> [agent/model, default claude/sonnet]
  local pr_n=$1 am=${3:-claude/sonnet} f
  f="$MF_GH_DIR/pr-${pr_n}.json"
  jq --arg l "Builder: agent=${am%%/*} model=${am#*/}" '.body = ((.body // "") + "\n\n" + $l + "\n")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

run_ship() { # <args...>
  SHIP_OUT=$(bash "$here/ship.sh" "$@" 2>&1)
  SHIP_RC=$?
}

# 1. PASS at head merges with --squash --match-head-commit and reads back MERGED
mf_pr_add 1 feat-pass "Body"
h1=$(jq -r .headRefOid "$MF_GH_DIR/pr-1.json")
mf_self_review 1 "$h1"
set_checks 1 "$green_checks"
post_verdict 1 PASS "$h1"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 1\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 1 --repo example/repo --squash --match-head-commit $h1" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-1.json")" = MERGED ]; then
  ok "PASS at head merges and reads back"
else
  bad "PASS at head merges and reads back" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 2. Verdict at an older head with the same patch-id merges
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
mf_pr_add 2 feat-rebase "Body"
old_h2=$(jq -r .headRefOid "$MF_GH_DIR/pr-2.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B main origin/main
echo unrelated > "$MF_REPO/unrelated-main.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add unrelated-main.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "advance main"
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin main
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
new_base=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse origin/main)
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B feat-rebase "$new_base"
"$MF_REAL_GIT" -C "$MF_REPO" cherry-pick "$old_h2" >/dev/null
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-rebase
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h2=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-rebase)
jq --arg h "$new_h2" --arg b "$new_base" '.headRefOid = $h | .baseRefOid = $b' "$MF_GH_DIR/pr-2.json" > "$MF_GH_DIR/pr-2.tmp" && mv "$MF_GH_DIR/pr-2.tmp" "$MF_GH_DIR/pr-2.json"
mf_self_review 2 "$new_h2"
set_checks 2 "$green_checks"
post_verdict 2 "PASS+NOTES" "$old_h2"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 2
if [ "$old_h2" != "$new_h2" ] && [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 2\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 2 --repo example/repo --squash --match-head-commit $new_h2" "$MF_GH_LOG"; then
  ok "verdict at an older head with the same patch id merges"
else
  bad "verdict at an older head with the same patch id merges" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 3. Different patch-id refuses
mf_pr_add 3 feat-diff "Body"
old_h3=$(jq -r .headRefOid "$MF_GH_DIR/pr-3.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q feat-diff
echo changed >> "$MF_REPO/feat-diff.txt"
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -am "change patch"
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-diff
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h3=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-diff)
jq --arg h "$new_h3" '.headRefOid = $h' "$MF_GH_DIR/pr-3.json" > "$MF_GH_DIR/pr-3.tmp" && mv "$MF_GH_DIR/pr-3.tmp" "$MF_GH_DIR/pr-3.json"
mf_self_review 3 "$new_h3"
set_checks 3 "$green_checks"
post_verdict 3 PASS "$old_h3"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 3
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "patch-id" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "different patch id refuses"
else
  bad "different patch id refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 4. FAIL verdict refuses
mf_pr_add 4 feat-fail "Body"
h4=$(jq -r .headRefOid "$MF_GH_DIR/pr-4.json")
set_checks 4 "$green_checks"
post_verdict 4 PASS "$h4"
post_verdict 4 FAIL "$h4"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 4
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "FAIL" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "FAIL refuses"
else
  bad "FAIL refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 5. Pending check refuses
mf_pr_add 5 feat-pending "Body"
h5=$(jq -r .headRefOid "$MF_GH_DIR/pr-5.json")
set_checks 5 '[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"IN_PROGRESS","conclusion":null}]'
post_verdict 5 PASS "$h5"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 5
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "check" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "pending check refuses"
else
  bad "pending check refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 6. No verdict refuses
mf_pr_add 6 feat-noverdict "Body"
set_checks 6 "$green_checks"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 6
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "verdict" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "no verdict refuses"
else
  bad "no verdict refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 7. Merge read-back not MERGED fails
mf_pr_add 7 feat-readback "Body"
h7=$(jq -r .headRefOid "$MF_GH_DIR/pr-7.json")
mf_self_review 7 "$h7"
set_checks 7 "$green_checks"
post_verdict 7 PASS "$h7"
rm -f "$MF_DIR/orca-called"
mkdir -p "$MF_DIR/noop-merge"
cat > "$MF_DIR/noop-merge/gh" <<EOS
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  echo "gh \$*" >> "$MF_GH_LOG"
  exit 0
fi
exec "$MF_BIN/gh" "\$@"
EOS
chmod +x "$MF_DIR/noop-merge/gh"
: > "$MF_GH_LOG"
SHIP_OUT=$(PATH="$MF_DIR/noop-merge:$PATH" bash "$here/ship.sh" --repo example/repo --pr 7 2>&1)
SHIP_RC=$?
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "not MERGED" <<<"$SHIP_OUT" && [ ! -e "$MF_DIR/orca-called" ]; then
  ok "merge read back not MERGED fails and leaves the board status alone"
else
  bad "merge read back not MERGED fails and leaves the board status alone" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 8. Protected path without approval refuses (and with approval merges)
mf_pr_add 8 feat-protected "Body" AGENTS.md
h8=$(jq -r .headRefOid "$MF_GH_DIR/pr-8.json")
mf_self_review 8 "$h8"
set_checks 8 "$green_checks"
gh pr comment 8 --repo example/repo --body "Review: PASS head=$h8" >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 8
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "Owner-approved" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "protected path without approval refuses"
else
  bad "protected path without approval refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 9. --dry-run merges nothing
mf_pr_add 9 feat-dry "Body"
h9=$(jq -r .headRefOid "$MF_GH_DIR/pr-9.json")
mf_self_review 9 "$h9"
set_checks 9 "$green_checks"
post_verdict 9 PASS "$h9"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 9 --dry-run
if [ "$SHIP_RC" -eq 0 ] && grep -qi "dry-run" <<<"$SHIP_OUT" \
  && ! grep -q "^shipped PR" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-9.json")" = OPEN ]; then
  ok "--dry-run merges nothing"
else
  bad "--dry-run merges nothing" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 10. Verifier with the same agent and model as the builder refuses
mf_pr_add 10 feat-same-pair "Body"
h10=$(jq -r .headRefOid "$MF_GH_DIR/pr-10.json")
mf_self_review 10 "$h10" claude/opus
set_checks 10 "$green_checks"
post_verdict 10 PASS "$h10"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 10
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "verifier claude/opus is the same agent and model as the builder" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "same agent and model as the builder refuses"
else
  bad "same agent and model as the builder refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 11. Edited FAIL still blocks an older PASS
mf_pr_add 11 feat-edited-fail "Body"
h11=$(jq -r .headRefOid "$MF_GH_DIR/pr-11.json")
set_checks 11 "$green_checks"
post_verdict 11 PASS "$h11"
post_verdict 11 FAIL "$h11"
mf_comment_flag 11 1 edited true
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 11
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "newest Verdict on PR 11 is FAIL" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "edited FAIL still blocks older PASS"
else
  bad "edited FAIL still blocks older PASS" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 12. Empty statusCheckRollup refuses
mf_pr_add 12 feat-nochecks "Body"
h12=$(jq -r .headRefOid "$MF_GH_DIR/pr-12.json")
set_checks 12 '[]'
post_verdict 12 PASS "$h12"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 12
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "no checks reported at head $h12" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "empty statusCheckRollup refuses"
else
  bad "empty statusCheckRollup refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 13. No Self-review needed, no builder dispatch, no Orca lookup, no cwd root check: the PR lands from any directory.
# The one Orca call is the board status of the merged branch.
mf_pr_add 13 feat-no-self-review "Body"
h13=$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")
mf_self_review 13 "$h13"
set_checks 13 "$green_checks"
post_verdict 13 PASS "$h13" ctx_never_seen ctx_unknown_author
: > "$MF_GH_LOG"
rm -f "$MF_DIR/orca-called"
mkdir -p "$MF_DIR/elsewhere"
SHIP_OUT=$(cd "$MF_DIR/elsewhere" && bash "$here/ship.sh" --repo example/repo --pr 13 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 13 ]] \
  && [ "$(cat "$MF_DIR/orca-called")" = "worktree set --worktree branch:feat-no-self-review --workspace-status completed" ] \
  && ! grep -q "Self-review" <<<"$(jq -r .body "$MF_GH_DIR/pr-13.json")"; then
  ok "no Self-review, dispatch lookup or cwd check; sets the merged branch completed"
else
  bad "no Self-review, dispatch lookup or cwd check; sets the merged branch completed" "rc=$SHIP_RC out=$SHIP_OUT called=$(cat "$MF_DIR/orca-called" 2>/dev/null)"
fi

# 13a. A failing board call warns and does not undo or fail the merge
mf_pr_add 133 feat-board-fails "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-133.json"); mf_self_review 133 "$h"; set_checks 133 "$green_checks"
post_verdict 133 PASS "$h"
SHIP_OUT=$(ORCA_FAKE_RC=1 bash "$here/ship.sh" --repo example/repo --pr 133 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 133 ]] && grep -Fq "could not set completed on branch:feat-board-fails" <<<"$SHIP_OUT"; then
  ok "board failure after merge only warns"
else
  bad "board failure after merge only warns" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 13b. A Verdict without agent and model refuses; a PR without a Builder line refuses
mf_pr_add 131 feat-old-verdict "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-131.json"); mf_self_review 131 "$h"; set_checks 131 "$green_checks"
post_verdict 131 PASS "$h" ctx_verifier ctx_author none
run_ship --repo example/repo --pr 131
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "does not record the verifier agent and model" <<<"$SHIP_OUT"; then ok "Verdict without agent and model refuses"; else bad "Verdict without agent and model refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi
mf_pr_add 132 feat-no-builder "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-132.json"); set_checks 132 "$green_checks"; post_verdict 132 PASS "$h"
run_ship --repo example/repo --pr 132
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "no 'Builder: agent=<agent> model=<model>' line" <<<"$SHIP_OUT"; then ok "PR without a Builder line refuses"; else bad "PR without a Builder line refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi
# Same model, different agent, passes the pair rule.
mf_pr_add 133 feat-other-agent "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-133.json"); mf_self_review 133 "$h" claude/opus; set_checks 133 "$green_checks"; post_verdict 133 PASS "$h" ctx_verifier ctx_author codex/opus
run_ship --repo example/repo --pr 133
if [ "$SHIP_RC" -eq 0 ]; then ok "a different agent with the same model passes"; else bad "a different agent with the same model passes" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 13c. Docs only: a cold Review: PASS at the head (or a Verdict, see 13d) lands; code still needs a Verdict
docs_case() { # <pr> <branch> <file> <review line or empty> <expect ship|refuse> <label> [text] [flags]
  local n=$1 b=$2 f=$3 line=$4 expect=$5 label=$6 text=${7:-} h
  mf_pr_add "$n" "$b" "Body" "$f"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); set_checks "$n" "$green_checks"
  [ -z "$line" ] || gh pr comment "$n" --repo example/repo --body "${line//@HEAD@/$h}" >/dev/null
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
docs_case 134 feat-docs-pass notes/doc.md "Review: PASS head=@HEAD@" ship "docs only PR lands on a cold Review: PASS"
docs_case 135 feat-docs-frag changelog.d/135-x.md "Review: PASS head=@HEAD@ main=$(printf 'b%.0s' {1..40})" ship "changelog fragment PR lands on Review: PASS with a main= tail"
docs_case 136 feat-docs-none notes/doc2.md "" refuse "docs only PR without Review refuses" "needs a cold 'Review: PASS head="
docs_case 137 feat-docs-stale notes/doc3.md "Review: PASS head=$(printf 'c%.0s' {1..40})" refuse "Review at another head refuses" "needs a cold 'Review: PASS head="
docs_case 138 feat-code-review-only notes/code.sh "Review: PASS head=@HEAD@" refuse "a code PR does not land on Review: PASS" "missing Verdict comment"
mf_pr_add 139 feat-docs-fail "Body" notes/doc4.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-139.json"); set_checks 139 "$green_checks"
gh pr comment 139 --repo example/repo --body "Review: PASS head=$h" >/dev/null; gh pr comment 139 --repo example/repo --body "Review: FAIL head=$h" >/dev/null
run_ship --repo example/repo --pr 139
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "newest Review on PR 139 is FAIL" <<<"$SHIP_OUT"; then ok "a newer Review: FAIL refuses a docs only PR"; else bad "a newer Review: FAIL refuses a docs only PR" "rc=$SHIP_RC out=$SHIP_OUT"; fi
mf_pr_add 140 feat-docs-edited "Body" notes/doc5.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-140.json"); set_checks 140 "$green_checks"
gh pr comment 140 --repo example/repo --body "Review: PASS head=$h" >/dev/null; mf_comment_flag 140 0 edited true
run_ship --repo example/repo --pr 140
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "needs a cold 'Review: PASS head=" <<<"$SHIP_OUT"; then ok "an edited Review: PASS does not count"; else bad "an edited Review: PASS does not count" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 13d. Docs only: a post-verdict.sh Verdict at the exact head also lands; FAIL or an older head refuses
docs_verdict_case() { # <pr> <branch> <file> <result> <verdict head: @HEAD@ or sha> <expect ship|refuse> <label> [text]
  local n=$1 b=$2 f=$3 res=$4 vh=$5 expect=$6 label=$7 text=${8:-} h
  mf_pr_add "$n" "$b" "Body" "$f"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); mf_self_review "$n" "$h" claude/sonnet; set_checks "$n" "$green_checks"
  post_verdict "$n" "$res" "${vh//@HEAD@/$h}"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
docs_verdict_case 141 feat-docs-vpass notes/v1.md PASS @HEAD@ ship "docs only PR lands on a Verdict: PASS at the head"
docs_verdict_case 142 feat-docs-vnotes notes/v2.md PASS+NOTES @HEAD@ ship "docs only PR lands on a Verdict: PASS+NOTES at the head"
docs_verdict_case 143 feat-docs-vold notes/v3.md PASS "$(printf 'c%.0s' {1..40})" refuse "a Verdict at an older head does not count" "needs a cold 'Review: PASS head="
docs_verdict_case 144 feat-docs-vfail notes/v4.md FAIL @HEAD@ refuse "a FAIL Verdict at the head refuses a docs only PR" "newest Verdict on PR 144 is FAIL"
mf_pr_add 145 feat-docs-vsame "Body" notes/v5.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-145.json"); mf_self_review 145 "$h" claude/opus; set_checks 145 "$green_checks"; post_verdict 145 PASS "$h"
run_ship --repo example/repo --pr 145
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "is the same agent and model as the builder" <<<"$SHIP_OUT"; then ok "a docs Verdict from the builder's own agent and model refuses"; else bad "a docs Verdict from the builder's own agent and model refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 14-15. Patch-id carry refuses an empty or whitespace-only commit after the verdict head (#771)
blank_case() { # <pr> <branch> <empty|whitespace>
  local n=$1 b=$2 kind=$3 old new
  mf_pr_add "$n" "$b" "Body"
  old=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
  if [ "$kind" = empty ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q --allow-empty -m "empty"
  else
    printf '%s   \n' "$b" > "$MF_REPO/$b.txt"
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q -am "whitespace"
  fi
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  new=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")
  jq --arg h "$new" '.headRefOid = $h' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  mf_self_review "$n" "$new"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$old"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "commit ${new:0:12} after verdict head ${old:0:12} is empty or whitespace only" <<<"$SHIP_OUT" \
    && ! grep -q "pr merge" "$MF_GH_LOG"; then
    ok "$kind commit after verdict head refuses"
  else
    bad "$kind commit after verdict head refuses" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
}
blank_case 14 feat-empty empty
blank_case 15 feat-ws whitespace

# 940. A wording-only change after the Verdict head ships on green checks; code, protected paths and code fences keep the patch-id refusal
wording_case() { # <pr> <branch> <file> <content> <expect ship|refuse> <label> [rename-from: a file the PR already has, moved to <file> unchanged] [pre: content <file> has at the Verdict head]
  local n=$1 b=$2 f=$3 content=$4 expect=$5 label=$6 from=${7:-} pre=${8:-} old new
  mf_pr_add "$n" "$b" "Body" ${from:+"$from"}
  if [ -n "$pre" ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
    mkdir -p "$MF_REPO/$(dirname "$f")"
    printf '%s\n' "$pre" > "$MF_REPO/$f"
    "$MF_REAL_GIT" -C "$MF_REPO" add -A
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "before verdict"
    "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
    jq --arg h "$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")" '.headRefOid = $h' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  fi
  old=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
  mkdir -p "$MF_REPO/$(dirname "$f")"
  if [ -n "$from" ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" mv "$from" "$f"
  else
    printf '%s\n' "$content" > "$MF_REPO/$f"
  fi
  "$MF_REAL_GIT" -C "$MF_REPO" add -A
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "after verdict"
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  new=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")
  jq --arg h "$new" --arg f "$f" '.headRefOid = $h | .files += [{path:$f, filename:$f}]' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  mf_self_review "$n" "$new"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$old"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "patch-id does not match" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
wording_case 60 feat-word-docs docs/note.md "plain words" ship "docs text change after the Verdict ships with no new Verdict"
wording_case 61 feat-word-log changelog.d/61-x.md "a fragment" ship "changelog fragment after the Verdict ships"
wording_case 62 feat-word-top README.md "top level words" ship "top level .md after the Verdict ships"
wording_case 63 feat-word-sh script/new.sh "echo hi" refuse "a .sh change after the Verdict is refused"
wording_case 64 feat-word-hook .claude/hooks/guard.md "words" refuse "a hooks path change after the Verdict is refused"
wording_case 65 feat-word-intent docs/intent/x.md "words" refuse "an intent change after the Verdict is refused"
wording_case 66 feat-word-fence docs/fence.md '```sh
rm -rf x
```' refuse "a docs change that adds a code fence is refused"
wording_case 67 feat-word-nested notes/other.md "words" refuse "a .md outside docs and changelog.d is refused"
wording_case 68 feat-word-rename docs/run.md "" refuse "a script renamed into docs after the Verdict is refused" script/run.sh
fence_doc='intro
```sh
rm -rf x
```
outro'
wording_case 69 feat-word-infence docs/f1.md 'intro
```sh
rm -rf y
```
outro' refuse "an edit to a line inside an existing code fence is refused" "" "$fence_doc"
wording_case 70 feat-word-outfence docs/f2.md 'intro changed
```sh
rm -rf x
```
outro' ship "a prose edit outside an existing code fence still ships" "" "$fence_doc"
wording_case 71 feat-word-claude CLAUDE.md "@AGENTS.md" refuse "a top level CLAUDE.md change is refused"

# Red main: refuses and names the run, unless the PR body says it fixes that run and the PR touches what failed.
# red_main_case <pr> <branch> <body-line or empty> <expect: refuse|ship> <pr file> <label> [conclusion] [expect text]
red_main_case() {
  local n=$1 b=$2 line=$3 expect=$4 file=$5 label=$6 conclusion=${7:-failure} text=${8:-https://example.test/runs/777} h
  mf_pr_add "$n" "$b" "Body" "$file"
  if [ -n "$line" ]; then
    jq --arg l "$line" '.body += "\n" + $l' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  fi
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$h"
  jq -n --arg c "$conclusion" --arg s "$main_sha" '{databaseId:777,conclusion:$c,url:"https://example.test/runs/777",headSha:$s}' > "$MF_GH_DIR/main-run.json"
  printf 'script/post-verdict.sh\n' > "$MF_GH_DIR/commit-$main_sha.txt"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  rm -f "$MF_GH_DIR/main-run.json" "$MF_GH_DIR/main-run-fails"
  if [ "$expect" = refuse ]; then
    if [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
      ok "$label"
    else
      bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"
    fi
  elif [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then
    ok "$label"
  else
    bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
}
main_sha=$(printf 'a%.0s' {1..40})
red_main_case 16 feat-red-main "" refuse script/post-verdict.sh "red main refuses and names the run"
red_main_case 17 feat-red-wrong-run "Fixes main: 778" refuse script/post-verdict.sh "Fixes main for another run refuses"
red_main_case 18 feat-fix-main "Fixes main: 777" ship script/post-verdict.sh "PR that touches a file of the red main commit ships"
red_main_case 19 feat-fix-main-test "Fixes main: 777" ship script/tests/post-verdict.test.sh "PR that touches a test of the red main commit ships"
red_main_case 20 feat-fix-unrelated "Fixes main: 777" refuse notes/unrelated.txt "Fixes main with unrelated files refuses" failure "touches neither the files nor the tests"
red_main_case 21 feat-cancelled-main "" refuse script/post-verdict.sh "cancelled main says rerun or fix main first" cancelled "rerun or fix main first"

# gh failing while reading main's Checks run refuses and merges nothing.
mf_pr_add 22 feat-main-gh-fails "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-22.json")
mf_self_review 22 "$h"
set_checks 22 "$green_checks"
post_verdict 22 PASS "$h"
: > "$MF_GH_DIR/main-run-fails"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 22
rm -f "$MF_GH_DIR/main-run-fails"
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "cannot read the latest Checks run on main" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "gh failing on main's Checks run refuses"
else
  bad "gh failing on main's Checks run refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Only push runs count: a pull_request run from a fork's main branch must not.
if grep -q "run list .*--event push" "$MF_GH_LOG" || { : > "$MF_GH_LOG"; run_ship --repo example/repo --pr 22 >/dev/null; grep -q "run list .*--event push" "$MF_GH_LOG"; }; then
  ok "main run lookup is limited to push events"
else
  bad "main run lookup is limited to push events" "$(cat "$MF_GH_LOG")"
fi

# --mechanical: pure substitution or deletion lands with no Verdict (ported from the old merge script)
mech_case() { # <pr> <expect ship|refuse> <label> <text> <diff body>; the fake gh serves a PR diff of the file list, so fixtures use a wrapper
  local n=$1 expect=$2 label=$3 text=$4 diff=$5 h
  mf_pr_add "$n" "feat-mech-$n" "Body" "${6:-script/mech-$n.sh}"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); set_checks "$n" "$green_checks"
  mkdir -p "$MF_DIR/mech-$n"
  printf '#!/usr/bin/env bash\nif [ "$1 $2" = "pr diff" ]; then printf %%s "$MECH_DIFF"; exit 0; fi\nexec "%s/gh" "$@"\n' "$MF_BIN" > "$MF_DIR/mech-$n/gh"; chmod +x "$MF_DIR/mech-$n/gh"
  : > "$MF_GH_LOG"
  SHIP_OUT=$(MECH_DIFF="$diff" PATH="$MF_DIR/mech-$n:$PATH" bash "$here/ship.sh" --repo example/repo --pr "$n" --mechanical 2>&1); SHIP_RC=$?
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG" && grep -Fq "mechanical lane" <<<"$SHIP_OUT"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
SUBST=$'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1 +1 @@\n-echo old\n+echo new\n'
mech_case 150 ship "mechanical substitution needs no Verdict" "" "$SUBST"
mech_case 151 ship "mechanical allows whole file deletion" "" "$SUBST"$'diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n'
mech_case 152 refuse "mechanical refuses an added logic line" "pure substitution" $'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'
mech_case 153 refuse "mechanical names a path with spaces" 'script/a b/c.sh: 0 removed, 1 added' $'diff --git a/script/a b/c.sh b/script/a b/c.sh\n--- a/script/a b/c.sh\n+++ b/script/a b/c.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'
mech_case 154 refuse "mechanical refuses a new script" "new file" $'diff --git a/script/new.sh b/script/new.sh\nnew file mode 100755\n--- /dev/null\n+++ b/script/new.sh\n@@ -0,0 +1 @@\n+echo hi\n'
mech_case 155 refuse "mechanical refuses a rename" "renames" $'diff --git a/a b/b\nsimilarity index 90%\nrename from a\nrename to b\n'
mech_case 156 refuse "mechanical still refuses protected paths" "owner through Elon" "$SUBST" .claude/settings.json
mech_case 157 refuse "mechanical gate file still needs countersign" "Countersign" "$SUBST" script/ship.sh
# Template copies of owner only paths are gated too (issue #954)
mech_case 159 refuse "template hook copy waits for the owner" "owner through Elon" "$SUBST" templates/agent-team/.claude/hooks/guard-bash.py
mech_case 160 refuse "template settings copy waits for the owner" "owner through Elon" "$SUBST" templates/agent-team/.claude/settings.json
# Without the flag the same PR needs a Verdict
mf_pr_add 158 feat-mech-noflag "Body" script/mech-158.sh; set_checks 158 "$green_checks"
run_ship --repo example/repo --pr 158
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "missing Verdict comment" <<<"$SHIP_OUT"; then ok "without --mechanical the substitution needs a Verdict"; else bad "without --mechanical the substitution needs a Verdict" "rc=$SHIP_RC out=$SHIP_OUT"; fi
run_ship --repo example/repo --pr 158 --mechanical --verdict-from x/dotfiles#1
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "exclusive" <<<"$SHIP_OUT"; then ok "--verdict-from and --mechanical are exclusive"; else bad "--verdict-from and --mechanical are exclusive" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# --verdict-from: generated team copies land on the Verdict of the matching MERGED dotfiles PR (ported from the old merge script)
{
  # ship.sh renders templates from origin/main, so the fixture syncs from origin/main too: a branch that edits a template must not fail here.
  repo_root="$MF_DIR/main-tree"; mkdir -p "$repo_root"
  git -C "$here/.." archive origin/main | tar -x -C "$repo_root"
  fx="$MF_DIR/dot"; mkdir -p "$fx/script" "$fx/.agents/skills"
  cp "$here/ship.sh" "$here/agent-team.sh" "$here/check-skill-collisions.sh" "$here/apply-local-overlay.py" "$here/ship.config.example.json" "$fx/script/"
  cp -R "$here/lib" "$fx/script/lib"; cp -R "$repo_root/templates" "$fx/templates"
  cp -R "$repo_root/.agents/skills/setup-matt-pocock-skills" "$fx/.agents/skills/setup-matt-pocock-skills"
  "$MF_REAL_GIT" -C "$fx" init -q -b main && "$MF_REAL_GIT" -C "$fx" add . && "$MF_REAL_GIT" -C "$fx" commit -qm fx
  "$MF_REAL_GIT" -C "$fx" update-ref refs/remotes/origin/main HEAD
  g() { "$MF_REAL_GIT" -C "$MF_REPO" "$@"; }
  g fetch -q origin; g checkout -q -B main origin/main
  DOTFILES="$repo_root" bash "$here/agent-team.sh" project "$MF_REPO" --project-name acme >/dev/null 2>&1
  echo "# old" > "$MF_REPO/docs/agents/team.md"; echo "# old" >> "$MF_REPO/bin/changelog-compile.sh"
  g add -A && g commit -qm seed-base && g push -q origin main && g fetch -q origin
  base_sha=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  DOTFILES="$repo_root" bash "$here/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  g add -A && g commit -qm sync && g push -q -f origin feat-gen
  gen_head=$(g rev-parse HEAD)
  gen_files=$(g diff --name-only "$base_sha" "$gen_head" | jq -Rsc 'split("\n")[:-1]')
  mkpr() { # <n> <head> <files json> <body>
    jq -n --argjson n "$1" --arg h "$2" --arg base "$base_sha" --argjson fl "$3" --arg body "$4" \
      '{number:$n,state:"OPEN",baseRefName:"main",headRefName:"feat-gen",headRefOid:$h,baseRefOid:$base,changedFiles:($fl|length),body:$body,
        files:($fl|map({path:., filename:.})),comments:[],closingIssuesReferences:[],mergeable:"MERGEABLE",mergeCommit:null,statusCheckRollup:[]}' > "$MF_GH_DIR/pr-$1.json"
  }
  mkpr 200 "$gen_head" "$gen_files" "Body"; set_checks 200 "$green_checks"
  DH=dddddddddddddddddddddddddddddddddddddd99
  GOOD="Verdict: PASS head=$DH verifier=ctx_verify author=ctx_author agent=claude model=opus"
  BADF="Verdict: FAIL head=$DH verifier=ctx_verify author=ctx_author agent=claude model=opus"
  src() { # <state> <json comments> [builder line]
    jq -n --arg st "$1" --arg h "$DH" --argjson c "$2" --arg b "${3:-Builder: agent=claude model=sonnet}" \
      '{number:9,state:$st,headRefName:"src",headRefOid:$h,baseRefOid:$h,body:$b,comments:$c,files:[],changedFiles:0,mergeable:"MERGEABLE",mergeCommit:null}' > "$MF_GH_DIR/pr-9.json"
  }
  one() { jq -nc --arg b "$1" '[{body:$b}]'; }
  vf() { # <label> <expect rc> <text> [repo]
    local lbl=$1 want=$2 text=$3 r=${4:-example/repo} saved_dry=1
    : > "$MF_GH_LOG"
    SHIP_OUT=$(bash "$fx/script/ship.sh" --repo "$r" --pr 200 --verdict-from d/dotfiles#9 --dry-run 2>&1); SHIP_RC=$?
    if { [ "$want" = 0 ] && [ "$SHIP_RC" -eq 0 ]; } || { [ "$want" != 0 ] && [ "$SHIP_RC" -ne 0 ]; }; then
      if grep -Fq -- "$text" <<<"$SHIP_OUT"; then ok "$lbl"; else bad "$lbl" "missing [$text] in: $SHIP_OUT"; fi
    else bad "$lbl" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  }
  src MERGED "$(one "$GOOD")"
  vf "verdict-from refuses without local config" 1 "no configured verdict_from_repos"
  printf '{"verdict_from_repos":["example/repo","acme/project-beta"]}\n' > "$fx/script/ship.local.json"
  vf "generated copies land on the dotfiles PR Verdict" 0 "generated team copies"
  vf "verdict-from refuses an unconfigured repo" 1 "repo is not configured" other/repo
  src OPEN "$(one "$GOOD")";  vf "verdict-from refuses an unmerged dotfiles PR" 1 "not MERGED"
  src MERGED "$(one "$BADF")"; vf "verdict-from refuses a FAIL Verdict" 1 "no passing Verdict"
  src MERGED "$(one "${GOOD//$DH/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}")"; vf "verdict-from refuses a Verdict for another head" 1 "no passing Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$g},{body:$f}]')"; vf "verdict-from: a newer FAIL beats an older PASS" 1 "FAIL Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f},{body:$g}]')"; vf "verdict-from: an older FAIL beside a newer PASS refuses" 1 "FAIL Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,edited:true}]')"; vf "verdict-from: an edited Verdict is refused" 1 "edited or minimized"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,minimized:true}]')"; vf "verdict-from: a minimized Verdict is refused" 1 "edited or minimized"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,edited:true},{body:$g}]')"; vf "verdict-from: a fresh Verdict after an edited one lands" 0 "generated team copies"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f,edited:true},{body:$g}]')"; vf "verdict-from: an edited FAIL still refuses" 1 "FAIL Verdict"
  src MERGED "$(one "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_verify agent=claude model=opus")"; vf "verdict-from: author equal to verifier is refused" 1 "author cannot supply"
  src MERGED "$(one "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_author")"; vf "verdict-from: a Verdict without agent and model is refused" 1 "does not record the verifier agent and model"
  src MERGED "$(one "$GOOD")" "Builder: agent=claude model=opus"; vf "verdict-from: verifier with the builder's agent and model is refused" 1 "same agent and model as the builder"
  src MERGED "$(one "$GOOD")" "no builder here"; vf "verdict-from: a source PR without a Builder line is refused" 1 "no 'Builder: agent=<agent> model=<model>' line"
  src MERGED "$(one "$GOOD")"
  # The sync result equals the origin/main render, so the verdict lane does not call it a hand edit.
  # The Verdict gate still applies.
  : > "$MF_GH_LOG"; SHIP_OUT=$(bash "$here/ship.sh" --repo example/repo --pr 200 2>&1); SHIP_RC=$?
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "missing Verdict comment" <<<"$SHIP_OUT" && ! grep -Fq "edits generated team copy" <<<"$SHIP_OUT"; then
    ok "render-equal generated copies pass the verdict lane and still need a Verdict"
  else
    bad "render-equal generated copies pass the verdict lane and still need a Verdict" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  # Header string alone is not a generated copy
  g checkout -q -B feat-gen "$base_sha"
  printf '<!-- Generated from dotfiles templates/agent-team/.agents/skills/x by script/sync-team-skills.sh, do not edit. -->\n' > "$MF_REPO/spoof.md"
  g add -A && g commit -qm spoof && sp=$(g rev-parse HEAD)
  mkpr 200 "$sp" '["spoof.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a file that only carries the header string" 1 "spoof.md is not"
  # Hand edited generated copy fails agent-team.sh check
  g checkout -q -B feat-gen "$base_sha"; echo "hand edit" >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm edit && he=$(g rev-parse HEAD)
  mkpr 200 "$he" '["docs/agents/team.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a hand edited generated copy" 1 "agent-team.sh check fails"
  # Symlink in a managed path
  g checkout -q -B feat-gen "$base_sha"; ln -sf /etc/passwd "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm link && ln_h=$(g rev-parse HEAD)
  mkpr 200 "$ln_h" '["docs/agents/team.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a symlink inside a managed path" 1 "refuses symlink"
  # Unmerged template edits must not vouch for themselves
  echo "unmerged template edit" >> "$fx/templates/agent-team/docs/agents/team.md"
  vf "verdict-from refuses when the dotfiles tree differs from origin/main for templates/agent-team" 1 "not at origin/main"
  "$MF_REAL_GIT" -C "$fx" checkout -q -- templates/agent-team
  echo untracked > "$fx/templates/agent-team/untracked-template.md"
  vf "verdict-from refuses an untracked file under templates/agent-team" 1 "not at origin/main"
  rm -f "$fx/templates/agent-team/untracked-template.md"

  # A generated-copy PR may also delete the paths check flags: a canonical role file, or a shared
  # hook nothing kept loads. An add, an edit, a kept hook, or an unrelated deletion still refuses.
  src MERGED "$(one "$GOOD")"
  seed_base=$base_sha
  role_rel=.claude/agents/elon.md
  hook_rel=.claude/hooks/strikes.py
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude/agents" "$MF_REPO/.claude/hooks"
  printf 'canonical role\n' > "$MF_REPO/$role_rel"
  printf 'shared hook\n' > "$MF_REPO/$hook_rel"
  g add -A && g commit -qm legacy-copies && g push -q origin main
  legacy_base=$(g rev-parse HEAD)
  name_status=$(g diff --name-status "$legacy_base" "$gen_head")
  del_files=$(g diff --name-only "$legacy_base" "$gen_head" | jq -Rsc 'split("\n")[:-1]')
  if grep -q $'^D\t'"$role_rel" <<<"$name_status" && grep -q $'^D\t'"$hook_rel" <<<"$name_status"; then
    base_sha=$legacy_base
    mkpr 200 "$gen_head" "$del_files" "Body"; set_checks 200 "$green_checks"
    vf "verdict-from accepts generated copies plus deletion of a canonical role file and an unkept shared hook" 0 "generated team copies"
  else
    bad "verdict-from accepts generated copies plus deletion of a canonical role file and an unkept shared hook" "fixture diff missing demanded deletions: $name_status"
  fi
  g checkout -q -B feat-gen "$legacy_base"
  printf 'edited role\n' >> "$MF_REPO/$role_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm edit-role && g push -q -f origin feat-gen
  edit_head=$(g rev-parse HEAD)
  edit_files=$(g diff --name-only "$legacy_base" "$edit_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$legacy_base
  mkpr 200 "$edit_head" "$edit_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses an edit of a canonical role file" 1 "is not"
  g checkout -q -B feat-gen "$seed_base"
  mkdir -p "$MF_REPO/.claude/agents"
  printf 'added role\n' > "$MF_REPO/$role_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm add-role && g push -q -f origin feat-gen
  add_head=$(g rev-parse HEAD)
  add_files=$(g diff --name-only "$seed_base" "$add_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$seed_base
  mkpr 200 "$add_head" "$add_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses an added canonical role file" 1 "is not"
  g checkout -q -B main "$seed_base"
  printf 'notes\n' > "$MF_REPO/notes.txt"
  g add notes.txt && g commit -qm notes && g push -q -f origin main
  notes_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  rm "$MF_REPO/notes.txt"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm del-notes && g push -q -f origin feat-gen
  notes_head=$(g rev-parse HEAD)
  notes_files=$(g diff --name-only "$notes_base" "$notes_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$notes_base
  mkpr 200 "$notes_head" "$notes_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses deletion of an unrelated file" 1 "is not"
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude/hooks"
  printf 'shared hook\n' > "$MF_REPO/$hook_rel"
  printf 'loads strikes.py\n' > "$MF_REPO/.claude/hooks/local-keep.py"
  g add -A && g commit -qm kept-hook && g push -q -f origin main
  kept_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  rm "$MF_REPO/$hook_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm del-kept && g push -q -f origin feat-gen
  kept_head=$(g rev-parse HEAD)
  kept_files=$(g diff --name-only "$kept_base" "$kept_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$kept_base
  mkpr 200 "$kept_head" "$kept_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses deletion of a shared hook check keeps" 1 "is not"

  # Verdict lane: a generated copy whose bytes equal the origin/main render (same project name
  # substitution as agent-team.sh) may ride with project edits and a deletion check demands.
  # A hand edit, a render of a template that is not on origin/main, or a deletion check does
  # not demand still uses the hand-edit refusal.
  render_acme_from() { # <blob spec in the fixture dotfiles repo>
    python3 - "$fx" "$1" "$MF_REPO/docs/agents/team.md" <<'PY'
import subprocess, sys
fx, spec, dest = sys.argv[1:]
raw = subprocess.check_output(["git", "-C", fx, "cat-file", "blob", spec])
with open(dest, "wb") as fh:
    fh.write(raw.replace(b"{{PROJECT_NAME}}", b"acme"))
PY
  }
  open_lane() { # <pr> <base> <head>
    local files
    files=$(g diff --name-only "$2" "$3" | jq -Rsc 'split("\n")[:-1]')
    base_sha=$2
    mkpr "$1" "$3" "$files" "Body"
    set_checks "$1" "$green_checks"
    mf_self_review "$1" "$3"
    post_verdict "$1" PASS "$3"
    : > "$MF_GH_LOG"
    SHIP_OUT=$(bash "$fx/script/ship.sh" --repo example/repo --pr "$1" --dry-run 2>&1)
    SHIP_RC=$?
  }
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.agents/skills/tdd"
  printf 'stale skill copy\n' > "$MF_REPO/.agents/skills/tdd/SKILL.md"
  g add -A && g commit -qm 'skill copy on base'
  skill_base=$(g rev-parse HEAD)
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "origin/main:templates/agent-team/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  rm -f "$MF_REPO/.agents/skills/tdd/SKILL.md"
  g add -A && g commit -q -m "adopt" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 210 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -eq 0 ] && grep -Fq "[dry-run] would ship PR 210" <<<"$SHIP_OUT"; then
    ok "verdict lane accepts a mixed PR whose generated copies equal the origin/main render"
  else
    bad "verdict lane accepts a mixed PR whose generated copies equal the origin/main render" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "origin/main:templates/agent-team/docs/agents/team.md"
  printf '\nhand edit\n' >> "$MF_REPO/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "hand edit" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 211 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses a hand edited generated copy"
  else
    bad "verdict lane refuses a hand edited generated copy" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  printf '\nunmerged template line\n' >> "$fx/templates/agent-team/docs/agents/team.md"
  "$MF_REAL_GIT" -C "$fx" add templates/agent-team/docs/agents/team.md
  "$MF_REAL_GIT" -C "$fx" commit -qm 'unmerged template'
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "HEAD:templates/agent-team/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "unmerged render" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 212 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses a generated copy rendered from an unmerged template"
  else
    bad "verdict lane refuses a generated copy rendered from an unmerged template" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  "$MF_REAL_GIT" -C "$fx" checkout -q origin/main -- templates/agent-team/docs/agents/team.md
  g checkout -q -B feat-lane "$skill_base"
  rm -f "$MF_REPO/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "delete template file" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 213 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses deletion of a generated copy check does not demand"
  else
    bad "verdict lane refuses deletion of a generated copy check does not demand" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
} </dev/null

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
