#!/usr/bin/env bash
# Tests script/pr-review.sh with fake gh and claude on the PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$tmp/gh" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
case "$1" in
  repo)
    echo "fake/o"
    ;;
  pr)
    case "$2" in
      list)
        [ -f "$FAKE/pr-list.json" ] && cat "$FAKE/pr-list.json" || echo "[]"
        ;;
      view)
        case "$*" in
          *comments*) [ -f "$FAKE/issue-comments.json" ] && cat "$FAKE/issue-comments.json" || echo "[]" ;;
          *closingIssuesReferences*) echo 41 ;;
          *headRefOid*)
            if [[ "$*" == *state* ]]; then
              printf '{"headRefOid":"%s","state":"%s"}' "$FAKE_HEAD" "${FAKE_PR_STATE:-OPEN}"
            else
              echo "$FAKE_HEAD"
            fi
            ;;
          *labels*)
            if [ "${FAKE_LABEL_STRONG:-}" = 1 ]; then echo review-strong; fi
            ;;
          *) echo "{}" ;;
        esac
        ;;
      diff)
        case "$*" in
          *name-only*) cat "$FAKE/files" ;;
          *) [ -f "$FAKE/diff-patch" ] && cat "$FAKE/diff-patch" || echo "diff" ;;
        esac
        ;;
      comment) cp "${@: -1}" "$FAKE/posted" ;;
      edit) : ;;
    esac
    ;;
  issue)
    echo "issue $3 asks for a refund button"
    ;;
  api)
    if [[ "$*" == *"/statuses/"* ]]; then
      [ -z "${FAKE_STATUS_FAIL:-}" ] || exit 1
      echo "$*" >> "$FAKE/status-calls"
    elif [[ "$2" == "user" ]]; then
      # gh applies --jq to API output; pr-review uses `gh api user --jq .login` with GITHUB_ACTOR fallback.
      if [ -n "${FAKE_USER_FAIL:-}" ]; then
        exit 1
      fi
      case "$*" in
        *--jq*) printf '%s\n' "${FAKE_LOGIN:-reviewer}" ;;
        *) echo "{\"login\":\"${FAKE_LOGIN:-reviewer}\"}" ;;
      esac
    elif [[ "$*" == *"/issues/"*"/comments"* ]]; then
      [ -f "$FAKE/issue-comments.json" ] && cat "$FAKE/issue-comments.json" || echo "[]"
    elif [[ "$*" == *"/pulls/"*"/files"* ]]; then
      [ -f "$FAKE/files-api-lines" ] && cat "$FAKE/files-api-lines"
    else
      tar -czf - -T /dev/null
    fi
    ;;
esac
F
cat > "$tmp/claude" <<'F'
#!/usr/bin/env bash
echo "$*" > "$FAKE/claude-args"
cat issues.json > "$FAKE/seen-issues"
if [ -n "${FAKE_DUAL_DISAGREE:-}" ]; then
  n=$( (wc -l < "$FAKE/claude-invocations") 2>/dev/null | tr -d ' ' ) || true
  n=${n:-0}
  if [ "$n" -eq 0 ]; then
    cat "$FAKE/answer"
  elif [ -f "$FAKE/answer2" ]; then
    cat "$FAKE/answer2"
  else
    cat "$FAKE/answer"
  fi
  echo 1 >> "$FAKE/claude-invocations"
  exit 0
fi
echo 1 >> "$FAKE/claude-invocations"
cat "$FAKE/answer"
F
cat > "$tmp/git" <<'F'
#!/usr/bin/env bash
# Fake verbatim patch-id for tests; optional FAKE_PATCH_ID overrides stdin hash.
if [ "$1" = "patch-id" ] && [ "${2:-}" = "--verbatim" ]; then
  cat >/dev/null  # drain pipe from gh pr diff (avoid SIGPIPE 141)
  if [ -n "${FAKE_PATCH_ID:-}" ]; then
    echo "${FAKE_PATCH_ID} 0000000000000000000000000000000000000000"
    exit 0
  fi
fi
exec /usr/bin/git "$@"
F
cat > "$tmp/review-usage-gate" <<'F'
#!/usr/bin/env bash
echo "$*" > "$FAKE/gate-args"
echo "--agent claude --model sonnet"
F
chmod +x "$tmp/review-usage-gate"
chmod +x "$tmp/gh" "$tmp/claude" "$tmp/git"

# REST issue comments: unedited (created_at == updated_at), in time order.
issue_comments_set() {
  local login=${FAKE_LOGIN:-reviewer}
  local dest=$tmp/issue-comments.json
  : >"$tmp/ic-lines.ndjson"
  local i=0
  for body in "$@"; do
    i=$((i + 1))
    ts=$(printf '2026-01-01T00:%02d:00Z' "$i")
    jq -nc --arg login "$login" --arg body "$body" --arg ts "$ts" --argjson id "$i" \
      '{id: $id, user: {login: $login}, body: $body, created_at: $ts, updated_at: $ts}' \
      >>"$tmp/ic-lines.ndjson"
  done
  if [ ! -s "$tmp/ic-lines.ndjson" ]; then
    echo '[]' >"$dest"
    return
  fi
  jq -s '.' "$tmp/ic-lines.ndjson" >"$dest"
}

run() {
  run_pr 7
}
run_pr() {
  local pr_num=$1
  rm -f "$tmp/posted" "$tmp/calls" "$tmp/claude-args" "$tmp/status-calls" "$tmp/claude-invocations" "$tmp/gate-args"
  local pr_head=${PR_HEAD:-$sha}
  FAKE="$tmp" FAKE_HEAD=${FAKE_HEAD:-${HEAD_NOW:-$pr_head}} PATH="$tmp:$PATH" \
    GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-fake/o}" \
    REVIEW_USAGE_GATE="$tmp/review-usage-gate" \
    AUTHOR_FAMILY="${AUTHOR_FAMILY:-claude}" \
    REVIEW_POST_STATUS="${REVIEW_POST_STATUS:-}" \
    FAKE_PATCH_ID="${FAKE_PATCH_ID:-}" \
    FAKE_DUAL_DISAGREE="${FAKE_DUAL_DISAGREE:-}" \
    FAKE_PR_STATE="${FAKE_PR_STATE:-}" \
    bash "$root/script/pr-review.sh" "$pr_num" "$pr_head" >/dev/null
}
fail() { echo "FAIL: $1"; exit 1; }
issue_comments_set
echo web/src/a.ts > "$tmp/files"

printf 'Review: PASS\nLooks right.\n' > "$tmp/answer"
run
grep -qE "^Review: PASS head=$sha model=sonnet( patch=[^ ]+)?\$" "$tmp/posted" || fail "PASS is posted with the head and model"
grep -q -- 'pick --role reviewer --avoid-family claude' "$tmp/gate-args" || fail "usage gate picks cross-family reviewer"

# Prompt lists the three questions and says style is never a FAIL
grep -q 'Does the diff meet each acceptance line' "$tmp/claude-args" || fail "prompt names acceptance question"
grep -q 'Is there a real bug' "$tmp/claude-args" || fail "prompt names bug question"
grep -q 'Would the new test go red without the fix' "$tmp/claude-args" || fail "prompt names test question"
grep -qi 'style.*never a FAIL' "$tmp/claude-args" || fail "prompt says style is never a FAIL"
grep -qi 'every defect' "$tmp/claude-args" || fail "prompt says to name every defect"
grep -qi 'customer-visible' "$tmp/claude-args" || fail "prompt names customer-visible failure first"
grep -qi 'changelog' "$tmp/claude-args" || fail "prompt says changelog-only claims are notes not FAIL alone"
[ -s "$root/script/review-prompt.txt" ] || fail "script/review-prompt.txt exists and is non-empty"
while IFS= read -r prompt_line || [ -n "$prompt_line" ]; do
  [ -n "$prompt_line" ] || continue
  grep -Fq -- "$prompt_line" "$tmp/claude-args" || fail "prompt contains review-prompt.txt with PR number substituted"
done < <(sed 's/{{PR}}/7/g' "$root/script/review-prompt.txt")
! grep -Fq '{{PR}}' "$tmp/claude-args" || fail "prompt substitutes {{PR}}"

# Missing or empty review-prompt.txt fails closed with a one-line reason
rm -f "$tmp/posted" "$tmp/claude-args"
mkdir -p "$tmp/no-prompt-script"
cp "$root/script/pr-review.sh" "$tmp/no-prompt-script/pr-review.sh"
if FAKE="$tmp" FAKE_HEAD=$sha PATH="$tmp:$PATH" GITHUB_REPOSITORY="fake/o" \
  REVIEW_USAGE_GATE="$tmp/review-usage-gate" AUTHOR_FAMILY="claude" \
  bash "$tmp/no-prompt-script/pr-review.sh" 7 "$sha" >"$tmp/missing-prompt.out" 2>&1; then
  fail "missing review-prompt.txt must exit non-zero"
fi
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "missing review-prompt.txt fails closed before invoking agent or posting"
[ -s "$tmp/missing-prompt.out" ] && [ "$(wc -l <"$tmp/missing-prompt.out" | tr -d ' ')" -eq 1 ] \
  || fail "missing review-prompt.txt prints a one-line reason"

: > "$tmp/no-prompt-script/review-prompt.txt"
if FAKE="$tmp" FAKE_HEAD=$sha PATH="$tmp:$PATH" GITHUB_REPOSITORY="fake/o" \
  REVIEW_USAGE_GATE="$tmp/review-usage-gate" AUTHOR_FAMILY="claude" \
  bash "$tmp/no-prompt-script/pr-review.sh" 7 "$sha" >"$tmp/empty-prompt.out" 2>&1; then
  fail "empty review-prompt.txt must exit non-zero"
fi
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "empty review-prompt.txt fails closed before invoking agent or posting"
[ -s "$tmp/empty-prompt.out" ] && [ "$(wc -l <"$tmp/empty-prompt.out" | tr -d ' ')" -eq 1 ] \
  || fail "empty review-prompt.txt prints a one-line reason"
run

grep -q 'issue 41 asks for a refund button' "$tmp/seen-issues" || fail "the reviewer gets the linked issue text"

issue_comments_set "Review: PASS head=$sha model=sonnet patch=dummy"
run
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "a reviewed head is skipped"

# FAIL at current head: settled; no second review
issue_comments_set "Review: FAIL head=$sha model=sonnet"
run
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "FAIL at current head settles without agent or new comment"

# Verdict PASS at this head: settled (newest line wins); no second review
issue_comments_set "Verdict: PASS head=$sha model=x"
run
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "Verdict PASS at current head settles without agent or new comment"

issue_comments_set
HEAD_NOW=bbbb run
[ ! -e "$tmp/claude-args" ] || fail "a stale head is skipped"

sed -i.bak '2i\
[ -z "${FAKE_GH_DOWN:-}" ] || exit 1
' "$tmp/gh"
if FAKE_GH_DOWN=1 run; then fail "a GitHub failure fails the run"; fi

# gh api user fails (workflow_run token): no GITHUB_ACTOR is fatal; with GITHUB_ACTOR the run proceeds
if GITHUB_ACTOR='' FAKE_USER_FAIL=1 run; then fail "gh api user fail without GITHUB_ACTOR must exit non-zero"; fi
issue_comments_set
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_USER_FAIL=1 GITHUB_ACTOR=reviewer run
grep -qE "^Review: PASS head=$sha model=sonnet( patch=[^ ]+)?\$" "$tmp/posted" \
  || fail "GITHUB_ACTOR fallback when gh api user fails"

echo 'I think it is fine' > "$tmp/answer"
if run; then fail "a malformed answer fails the run"; fi
[ ! -e "$tmp/posted" ] || fail "a malformed answer posts nothing"

printf 'I read the code.\n\nReview: FAIL\nBroken.\n' > "$tmp/answer"
run
grep -qE "^Review: FAIL head=$sha model=sonnet( patch=[^ ]+)?\$" "$tmp/posted" || fail "a verdict after a preamble still counts"
grep -q '^Broken\.$' "$tmp/posted" || fail "the defects after the verdict are posted"

printf 'Review: FAIL\nFirst finding.\nSecond finding.\n' > "$tmp/answer"
run
grep -q '^First finding\.$' "$tmp/posted" || fail "verdict on line 1 keeps all finding lines"
grep -q '^Second finding\.$' "$tmp/posted" || fail "verdict on line 1 keeps all finding lines"
grep -q 'model=sonnet' "$tmp/posted" || fail "verdict on line 1 still posts header"

printf 'Intro line.\nReview: FAIL\nOnly after verdict.\n' > "$tmp/answer"
run
grep -q '^Only after verdict\.$' "$tmp/posted" || fail "preamble plus verdict keeps only lines after verdict"
! grep -q '^Intro line\.$' "$tmp/posted" || fail "text before verdict must not appear in posted body"

issue_comments_set
printf 'Review: PASS\n' > "$tmp/answer"
echo src/lib/payment/x.ts > "$tmp/files"
run
grep -q 'model=opus' "$tmp/posted" || fail "money paths use the stronger model"
dual_n=$(wc -l < "$tmp/claude-invocations" 2>/dev/null | tr -d ' ')
dual_n=${dual_n:-0}
[ "$dual_n" -eq 2 ] || fail "money paths run the agent twice (got $dual_n)"

# Strong gate paths without money dual still use opus once
issue_comments_set
printf 'Review: PASS\n' > "$tmp/answer"
echo .github/workflows/checks.yml > "$tmp/files"
rm -f "$tmp/claude-invocations"
run
grep -q 'model=opus' "$tmp/posted" || fail "workflow paths use opus"
ledger_n=$(wc -l < "$tmp/claude-invocations" 2>/dev/null | tr -d ' ')
ledger_n=${ledger_n:-0}
[ "$ledger_n" -eq 1 ] || fail "workflow strong paths run once (got $ledger_n)"

issue_comments_set
printf 'Review: PASS\n' > "$tmp/answer"
echo src/billing/ledger.ts > "$tmp/files"
rm -f "$tmp/claude-invocations"
run
grep -q 'model=opus' "$tmp/posted" || fail "billing paths use opus"
claim1_n=$(wc -l < "$tmp/claude-invocations" 2>/dev/null | tr -d ' ')
claim1_n=${claim1_n:-0}
[ "$claim1_n" -eq 2 ] || fail "billing money paths run twice (got $claim1_n)"

issue_comments_set
printf 'Review: PASS\n' > "$tmp/answer"
echo script/secrets-pack.sh > "$tmp/files"
rm -f "$tmp/claude-invocations"
run
grep -q 'model=opus' "$tmp/posted" || fail "secrets paths use opus"
claim2_n=$(wc -l < "$tmp/claude-invocations" 2>/dev/null | tr -d ' ')
claim2_n=${claim2_n:-0}
[ "$claim2_n" -eq 2 ] || fail "secrets money paths run twice (got $claim2_n)"

# Money paths: disagreeing verdicts post FAIL
issue_comments_set
echo src/stripe/webhook.ts > "$tmp/files"
printf 'Review: PASS\nok\n' > "$tmp/answer"
printf 'Review: FAIL\nbalance race.\n' > "$tmp/answer2"
unset FAKE_DUAL_DISAGREE
FAKE_DUAL_DISAGREE=1 run
grep -qE "^Review: FAIL head=$sha model=opus" "$tmp/posted" || fail "money disagree posts FAIL"
grep -q 'balance race' "$tmp/posted" || fail "money disagree keeps defect text"
grep -qi 'disagree' "$tmp/posted" || fail "money disagree names the split"

# Non-money: one agent run
issue_comments_set
echo web/src/a.ts > "$tmp/files"
printf 'Review: PASS\n' > "$tmp/answer"
rm -f "$tmp/claude-invocations"
run
nonmoney_n=$(wc -l < "$tmp/claude-invocations" 2>/dev/null | tr -d ' ')
nonmoney_n=${nonmoney_n:-0}
[ "$nonmoney_n" -eq 1 ] || fail "non-money runs the agent once (got $nonmoney_n)"

# review-strong label raises plain PR to opus
issue_comments_set
printf 'Review: PASS\n' > "$tmp/answer"
echo web/src/a.ts > "$tmp/files"
FAKE_LABEL_STRONG=1 run
grep -q 'model=opus' "$tmp/posted" || fail "review-strong uses the stronger model"

echo web/src/a.ts > "$tmp/files"
printf 'Review: FAIL\nBroken.\n' > "$tmp/answer"
issue_comments_set "$(printf 'Review: FAIL head=%040d model=sonnet\n' 1)" "$(printf 'Review: FAIL head=%040d model=sonnet\n' 2)"
run
grep -q 'edit' "$tmp/calls" && grep -q 'needs-elon' "$tmp/calls" || fail "the third failed head gets the label"

issue_comments_set "$(printf 'Review: FAIL head=%040d model=sonnet\n' 1)"
run
if grep -q needs-elon "$tmp/calls"; then fail "the second failed head gets no label"; fi

# REVIEW_POST_STATUS=1: PASS posts success status at head sha (status before comment)
issue_comments_set
echo web/src/a.ts > "$tmp/files"
printf 'Review: PASS\nok\n' > "$tmp/answer"
REVIEW_POST_STATUS=1 run
grep -q "statuses/$sha" "$tmp/status-calls" && grep -qi -- "-f state=success" "$tmp/status-calls" \
  && grep -qi -- "-f context=review" "$tmp/status-calls" || fail "PASS posts review status success at head"
awk '/statuses\/aaaaaaaa/{s=NR} /pr comment/{c=NR} END{exit !(s && c && s<c)}' "$tmp/calls" || fail "status API runs before pr comment on PASS"

# FAIL posts failure before comment
issue_comments_set
printf 'Review: FAIL\nx\n' > "$tmp/answer"
REVIEW_POST_STATUS=1 run
grep -qi -- "-f state=failure" "$tmp/status-calls" || fail "FAIL posts review status failure"
awk '/statuses\/aaaaaaaa/{s=NR} /pr comment/{c=NR} END{exit !(s && c && s<c)}' "$tmp/calls" || fail "status API runs before pr comment on FAIL"

# Unset REVIEW_POST_STATUS: no status API
issue_comments_set
printf 'Review: PASS\nok\n' > "$tmp/answer"
run
[ ! -e "$tmp/status-calls" ] || fail "unset REVIEW_POST_STATUS skips status API"

# REVIEW_POST_STATUS=0 (review.yml): no status API
issue_comments_set
printf '%s\n%s\n' docs/a.md changelog.d/z.md > "$tmp/files"
printf 'Review: PASS\nok\n' > "$tmp/answer"
REVIEW_POST_STATUS=0 run
[ ! -e "$tmp/status-calls" ] || fail "REVIEW_POST_STATUS=0 skips status API"

# docs/changelog only: no claude, auto PASS model=none, status before comment when REVIEW_POST_STATUS is on
issue_comments_set
printf '%s\n%s\n' docs/a.md changelog.d/z.md > "$tmp/files"
REVIEW_POST_STATUS=1 run
[ ! -e "$tmp/claude-args" ] || fail "docs-only change does not call claude"
grep -qE "^Review: PASS head=$sha model=none( patch=[^ ]+)?\$" "$tmp/posted" || fail "docs-only posts PASS and model=none"
grep -qi -- "-f state=success" "$tmp/status-calls" || fail "docs-only with status on posts success"
awk '/statuses\/aaaaaaaa/{s=NR} /pr comment/{c=NR} END{exit !(s && c && s<c)}' "$tmp/calls" || fail "docs-only posts status before comment"

# docs-only with review-strong: must run agent with opus, not docs shortcut
issue_comments_set
printf '%s\n%s\n' docs/a.md changelog.d/z.md > "$tmp/files"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_LABEL_STRONG=1 run
[ -e "$tmp/claude-args" ] || fail "docs-only with review-strong calls claude"
grep -q 'model=opus' "$tmp/posted" || fail "docs-only with review-strong uses the stronger model"

# model=none PASS at same patch must not carry when review-strong is present (run agent at opus)
issue_comments_set
pid=dddddddddddddddddddddddddddddddddddddddd
printf '%s\n%s\n' docs/a.md changelog.d/z.md > "$tmp/files"
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=none patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_PATCH_ID=$pid FAKE_LABEL_STRONG=1 run
[ -e "$tmp/claude-args" ] || fail "review-strong blocks carry of model=none PASS, agent runs"
grep -q 'model=opus' "$tmp/posted" || fail "after prior model=none PASS, review-strong uses opus"

# Empty file list: no auto PASS; agent path runs
issue_comments_set
: > "$tmp/files"
printf 'Review: PASS\n.\n' > "$tmp/answer"
run
[ -e "$tmp/claude-args" ] || fail "empty change list does not auto PASS"

# Mixed docs and code: agent review, not docs-only shortcut
issue_comments_set
printf '%s\n%s\n' docs/a.md web/src/a.ts > "$tmp/files"
printf 'Review: PASS\n.\n' > "$tmp/answer"
run
[ -e "$tmp/claude-args" ] || fail "mixed docs and code calls the agent"

# Rename into docs: PR files API `previous_filename` is required (`gh pr diff --name-only` is new path only)
issue_comments_set
printf '%s\n' docs/agents/qa.md > "$tmp/files"
printf '%s\n%s\n' docs/agents/qa.md .claude/agents/qa.md > "$tmp/files-api-lines"
printf 'Review: PASS\n.\n' > "$tmp/answer"
run
[ -e "$tmp/claude-args" ] || fail "rename from outside docs to docs still gets a review"

# Already reviewed: second run posts nothing and does not call agent
rm -f "$tmp/diff-patch" "$tmp/files-api-lines"
issue_comments_set
printf '%s\n%s\n' docs/a.md changelog.d/z.md > "$tmp/files"
REVIEW_POST_STATUS=1 run
mv "$tmp/posted" "$tmp/posted-first"
issue_comments_set "$(cat "$tmp/posted-first")"
run
[ ! -e "$tmp/posted" ] && [ ! -e "$tmp/claude-args" ] || fail "already reviewed head posts no second comment"

# Failed status post: no comment; rerun is not blocked by head already reviewed
rm -f "$tmp/diff-patch" "$tmp/files-api-lines"
issue_comments_set
echo web/src/a.ts > "$tmp/files"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_STATUS_FAIL=1 REVIEW_POST_STATUS=1 run || true
[ ! -e "$tmp/posted" ] || fail "failed status leaves no comment"
FAKE_STATUS_FAIL= REVIEW_POST_STATUS=1 run
grep -qE "^Review: PASS head=$sha model=sonnet( patch=[^ ]+)?\$" "$tmp/posted" || fail "after status recovery the review posts"

# Same patch as last PASS with patch= carries PASS with model=carried and no agent
rm -f "$tmp/files-api-lines"
issue_comments_set
echo web/src/a.ts > "$tmp/files"
pid=$sha
printf 'Review: PASS\nolder\n' > "$tmp/diff-patch"
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid"
FAKE_PATCH_ID=$pid run
[ ! -e "$tmp/claude-args" ] || fail "same patch carry skips the agent"
grep -q "^Review: PASS head=$sha model=carried patch=$pid\$" "$tmp/posted" || fail "carry posts PASS with model=carried and patch id"

# Different patch id: full review
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_PATCH_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run
[ -e "$tmp/claude-args" ] || fail "changed patch runs the agent"

# FAIL after last PASS with patch: carry blocked
issue_comments_set \
  "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid" \
  "Review: FAIL head=0000000000000000000000000000000000000000 model=sonnet"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_PATCH_ID=$pid run
[ -e "$tmp/claude-args" ] || fail "FAIL after PASS blocks patch carry"

# Edited issue comment is skipped (REST updated_at != created_at): not "already reviewed"
issue_comments_set
jq --arg sha "$sha" -n \
  '[{
    id: 1,
    user: {login: "reviewer"},
    body: ("Review: PASS head=" + $sha + " model=x patch=eee"),
    created_at: "2026-01-01T00:01:00Z",
    updated_at: "2026-01-02T00:00:00Z"
  }]' >"$tmp/issue-comments.json"
printf 'Review: PASS\nok\n' > "$tmp/answer"
run
[ -e "$tmp/claude-args" ] || fail "edited prior PASS comment does not skip the run"

# State table (skip vs review): newest verdict line per head; see script/pr-review.sh
# FAIL at A then PASS at B (other head), rerun for B: skip (settled at B)
hA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1 hB=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2
issue_comments_set \
  "Review: FAIL head=$hA model=sonnet" \
  "Review: PASS head=$hB model=sonnet patch=$pid"
PR_HEAD=$hB HEAD_NOW=$hB run
[ ! -e "$tmp/claude-args" ] || fail "FAIL at A then PASS at B: rerun for B skips"

# PASS at old head, no FAIL anywhere: same patch -> carry; changed patch -> review
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid"
FAKE_PATCH_ID=$pid run
[ ! -e "$tmp/claude-args" ] || fail "PASS at old head same patch carries without agent"
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_PATCH_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run
[ -e "$tmp/claude-args" ] || fail "PASS at old head changed patch runs agent"

# FAIL at A then PASS at B, push C (same patch as B): review (carry blocked by open FAIL at A)
hC=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3
issue_comments_set \
  "Review: FAIL head=$hA model=sonnet" \
  "Review: PASS head=$hB model=sonnet patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
PR_HEAD=$hC run
[ -e "$tmp/claude-args" ] || fail "FAIL at A blocks carry for same patch at head C after B"

# Verdict FAIL then Verdict PASS+NOTES at this head: skip on rerun
issue_comments_set \
  "Verdict: FAIL head=$sha model=x" \
  "Verdict: PASS+NOTES head=$sha model=x"
run
[ ! -e "$tmp/claude-args" ] || fail "Verdict FAIL then PASS+NOTES at this head skips on rerun"

# FAIL then newest PASS at this head (matching patch): skip (settled)
issue_comments_set \
  "Review: FAIL head=$sha model=sonnet" \
  "Review: PASS head=$sha model=sonnet patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
FAKE_PATCH_ID=$pid run
[ ! -e "$tmp/claude-args" ] || fail "FAIL then PASS at this head with same patch skips"

# PASS at this head then FAIL at this head: skip on rerun for this head
issue_comments_set \
  "Review: PASS head=$sha model=sonnet patch=$pid" \
  "Review: FAIL head=$sha model=sonnet"
run
[ ! -e "$tmp/claude-args" ] || fail "PASS then FAIL at this head settles without agent on rerun"

# review-strong at same patch as prior PASS: must review (not carry)
issue_comments_set "Review: PASS head=0000000000000000000000000000000000000000 model=sonnet patch=$pid"
printf 'Review: PASS\nok\n' > "$tmp/answer"
echo web/src/a.ts > "$tmp/files"
FAKE_PATCH_ID=$pid FAKE_LABEL_STRONG=1 run
[ -e "$tmp/claude-args" ] || fail "review-strong at same patch forces agent"

# Real git: indentation-only diff yields different ids with patch-id --verbatim
whitespace_patch_id_differs() {
  local d x y
  d=$(mktemp -d)
  (
    cd "$d" || exit 1
    git init -q
    printf '%s\n' 'int main(){' 'return 0;' '}' > f.c
    git add f.c && git -c user.name=t -c user.email=t@e.invalid commit -qm init
  )
  x=$(
    cd "$d" || exit 1
    git checkout -q -- . 2>/dev/null || true
    printf '%s\n' 'int main(){' '  return 0;' '}' > f.c
    git diff | /usr/bin/git patch-id --verbatim | awk 'NF { print $1; exit }'
  )
  y=$(
    cd "$d" || exit 1
    git checkout -q -- . 2>/dev/null || true
    printf '%s\n' 'int main(){' '    return 0;' '}' > f.c
    git diff | /usr/bin/git patch-id --verbatim | awk 'NF { print $1; exit }'
  )
  rm -rf "$d"
  [ -n "$x" ] && [ -n "$y" ] && [ "$x" != "$y" ]
}
whitespace_patch_id_differs || fail "git patch-id --verbatim differs for indentation-only change"

# Empty PR number + merged head: resolve via pr list, skip without agent
issue_comments_set
rm -f "$tmp/posted" "$tmp/claude-args" "$tmp/pr-list.json"
jq -n --arg h "$sha" '[{number: 7453, state: "MERGED", headRefOid: $h}]' >"$tmp/pr-list.json"
out=$(
  FAKE="$tmp" FAKE_HEAD=$sha PATH="$tmp:$PATH" bash "$root/script/pr-review.sh" "" "$sha" 2>&1
) || fail "empty pr with merged head must exit 0"
grep -q 'PR already merged or closed; skipping review' <<<"$out" || fail "merged skip message"
[ ! -e "$tmp/claude-args" ] || fail "merged head skips agent when pr empty"

# Empty PR number + open PR: resolve number and review normally
issue_comments_set
printf 'Review: PASS\nLooks right.\n' > "$tmp/answer"
jq -n --arg h "$sha" '[{number: 99, state: "OPEN", headRefOid: $h}]' >"$tmp/pr-list.json"
FAKE_PR_STATE=OPEN run_pr ""
grep -qE "^Review: PASS head=$sha model=sonnet( patch=[^ ]+)?\$" "$tmp/posted" \
  || fail "empty pr resolves open PR and posts review"
grep -q ' pr view 99 ' "$tmp/calls" || grep -q 'pr view 99' "$tmp/calls" \
  || fail "empty pr resolves to PR 99"

# Explicit merged PR: skip without agent
issue_comments_set
rm -f "$tmp/posted" "$tmp/claude-args" "$tmp/pr-list.json"
FAKE_PR_STATE=MERGED out=$(
  FAKE="$tmp" FAKE_HEAD=$sha FAKE_PR_STATE=MERGED PATH="$tmp:$PATH" \
    bash "$root/script/pr-review.sh" 7 "$sha" 2>&1
) || fail "explicit merged PR must exit 0"
grep -q 'PR already merged or closed; skipping review' <<<"$out" || fail "explicit merged skip message"
[ ! -e "$tmp/claude-args" ] || fail "explicit merged PR skips agent"

# Empty pr with invalid or missing head: usage error
err_f=$tmp/usage.err
if FAKE="$tmp" PATH="$tmp:$PATH" bash "$root/script/pr-review.sh" "" short 2>"$err_f"; then
  fail "empty pr with short head must exit non-zero"
fi
grep -qi 'head' "$err_f" || fail "usage mentions head requirement"
if FAKE="$tmp" PATH="$tmp:$PATH" bash "$root/script/pr-review.sh" "" "" 2>"$err_f"; then
  fail "empty pr and empty head must exit non-zero"
fi

# No PR for head after merge: skip
issue_comments_set
rm -f "$tmp/posted" "$tmp/claude-args"
echo '[]' >"$tmp/pr-list.json"
out=$(
  FAKE="$tmp" FAKE_HEAD=$sha PATH="$tmp:$PATH" bash "$root/script/pr-review.sh" "" "$sha" 2>&1
) || fail "empty pr with no matching PR must exit 0"
grep -q 'PR already merged or closed; skipping review' <<<"$out" || fail "no PR skip message"

echo "pr-review tests passed"
