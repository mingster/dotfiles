#!/usr/bin/env bash
# Tests for lead-merge.sh with gh and git stubbed on PATH.
# shellcheck disable=SC2089,SC2090,SC2015
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/orca/workspaces/proj/lead-x" "$HOME/orca/workspaces/proj/fullstack-dev-x" "$tmp/other/lead-y" "$tmp/bin"
LEAD="$HOME/orca/workspaces/proj/lead-x"

REAL_GIT=$(command -v git); export REAL_GIT
# git stub: rev-parse --show-toplevel prints $FAKE_TOP.
cat > "$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "$1" = rev-parse ] && { echo "$FAKE_TOP"; exit 0; }
[ -z "${REAL_PATCH_REPO:-}" ] || exec "$REAL_GIT" -C "$REAL_PATCH_REPO" "$@"
case "$1" in
  cat-file|fetch) exit 0 ;;
  merge-base) echo cccccccccccccccccccccccccccccccccccccccc ;;
  diff) case "$*" in *--name-only*) printf '%s\n' "$TRUNK_FILES" ;; *"$OLD"*) echo "$OLD_PATCH" ;; *) echo current ;; esac ;;
  patch-id) read -r patch; [ -n "$patch" ] && echo "$patch commit" ;;
  *) exit 1 ;;
esac
EOS
# gh stub: view prints $PR_JSON (or $FINAL_JSON after a merge), diff prints $PR_DIFF,
# merge logs the call and fails MERGE_FAILS times first.
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
case "$2" in
  view)
    if [ -f "$MERGE_LOG" ] && grep -q ok "$MERGE_LOG"; then printf '%s' "$FINAL_JSON"; else printf '%s' "$PR_JSON"; fi ;;
  diff) printf '%s' "$PR_DIFF" ;;
  merge)
    echo "$*" >> "$MERGE_LOG.calls"
    n=$(wc -l < "$MERGE_LOG.calls")
    if [ "$n" -le "${MERGE_FAILS:-0}" ]; then echo "boom" >&2; exit 1; fi
    echo ok >> "$MERGE_LOG" ;;
esac
EOS
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export MERGE_LOG="$tmp/merge.log"

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
setup() {
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
  FAKE_TOP="$LEAD"; MERGE_FAILS=0; PR_DIFF=""
  COMMENTS_JSON=""
  base_sha=cccccccccccccccccccccccccccccccccccccccc
  files='[{"path":"script/foo.sh"}]'
  body=$'## Verification\n- Ran script successfully.'
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"; OLD_PATCH=current
  checks="Checks: PASS head=$SHA"; countersign=""; TRUNK_FILES=""
  export TRUNK_FILES
  export OLD OLD_PATCH
  state=OPEN base=main headsha=$SHA mergeable=MERGEABLE branch=feature
  FINAL_JSON='{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"url":"https://github.com/o/r/pull/7"}'
}
mkjson() {
  PR_JSON=$(printf '{"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","mergeable":"%s","url":"https://github.com/o/r/pull/7","files":%s}' \
    "$state" "$base" "$branch" "$headsha" "$mergeable" "$files")
  PR_JSON=$(jq --arg body "$body" --arg comments "$comments" --arg checks "$checks" --arg countersign "$countersign" --arg base "$base_sha" '. + {body:$body, baseRefOid:$base, comments:[$checks,$comments,$countersign | {body:.}]}' <<<"$PR_JSON")
  [ -z "$COMMENTS_JSON" ] || PR_JSON=$(jq --argjson comments "$COMMENTS_JSON" '.comments=$comments' <<<"$PR_JSON")
  export OLD_PATCH
  export PR_JSON FINAL_JSON PR_DIFF FAKE_TOP MERGE_FAILS
}

pass=0; fail=0
check() { # name expected_exit output_regex [merge_calls]
  mkjson
  out=$("$here/lead-merge.sh" --repo o/r --pr 7 --head "$SHA" 2>&1); code=$?
  calls=0; [ -f "$MERGE_LOG.calls" ] && calls=$(wc -l < "$MERGE_LOG.calls" | tr -d ' ')
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3" && [ "$calls" = "${4:-0}" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1 (exit $code, merge calls $calls)"; echo "$out"; fi
}

setup; check "success merges with match-head-commit" 0 '^MERGED https://github.com/o/r/pull/7 [0-9a-f]+$' 1
grep -q -- "--merge --match-head-commit $SHA" "$MERGE_LOG.calls" && { pass=$((pass+1)); echo "ok   merge flags"; } || { fail=$((fail+1)); echo "FAIL merge flags"; }

setup; FAKE_TOP="$HOME/orca/workspaces/proj/fullstack-dev-x"; check "non lead worktree refused" 1 'lead-\*'
setup; FAKE_TOP="$tmp/other/lead-y"; check "lead outside orca workspaces refused" 1 'not under'
setup; state=MERGED; check "closed PR refused" 1 'not open'
setup; base=staging; check "base not main refused" 1 'base is not main'
setup; headsha=def456; check "head sha mismatch refused" 1 'head is def456'
setup; mergeable=CONFLICTING; check "not mergeable refused" 1 'not MERGEABLE'
setup; branch=production; check "production head branch refused" 1 'production'
setup; branch=staging; check "staging head branch refused" 1 'staging'
setup; files='[{"path":".claude/hooks/x.sh"}]'; check "hooks refused" 1 'claude/hooks'
setup; files='[{"path":".claude/settings.json"}]'; check "settings refused" 1 'settings.json'
setup; files='[{"path":"bin/owner-approve.sh"}]'; check "owner-approve refused" 1 'owner-approve'
setup; files='[{"path":"templates/codex/lead-merge.rules"}]'; check ".rules refused" 1 'lead-merge.rules'
setup; files='[{"path":".codex/rules/default.rules"}]'; check ".codex refused" 1 'codex'
setup; files='[{"path":"docs/intent/a/intent.md"}]'
PR_DIFF=$'diff --git a/docs/intent/a/intent.md b/docs/intent/a/intent.md\n+++ b/docs/intent/a/intent.md\n-Status: Proposed 2026-10-01\n+Status: Proposed 2026-10-01 · Accepted 2026-10-17\n'
check "intent accepted refused" 1 'accepts an intent'
setup; files='[{"path":"docs/intent/a/intent.md"}]'
PR_DIFF=$'+++ b/docs/intent/a/intent.md\n+Some text mentioning Accepted\n'
check "intent edit without status change allowed" 0 '^MERGED' 1
setup; MERGE_FAILS=1; check "one retry then success" 0 '^MERGED' 2
setup; MERGE_FAILS=2; check "merge failure prints error, exits 1" 1 'merge failed: boom' 2
setup; FINAL_JSON='{"state":"OPEN","url":"u"}'; check "unconfirmed merge fails" 1 'not MERGED' 1

setup; body="No heading"; check "missing Verification refused" 1 'Verification'
setup; body="## Verification"; check "empty Verification refused" 1 '1 to 3'
setup; body=$'## Verification\n- one\n- two\n- three\n- four'; check "excess Verification bullets refused" 1 '1 to 3'
setup; FINAL_JSON='{"state":"MERGED","url":"u","mergeCommit":null}'; check "missing merge commit refused" 1 'no merge commit' 1
setup; comments=""; check "missing verdict refused" 1 'verdict'
setup; comments="Verdict: FAIL head=$SHA verifier=ctx_verify author=ctx_author"; check "FAIL verdict refused" 1 'verdict'
setup; comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"; OLD_PATCH=different; check "stale different patch refused" 1 'verdict'
setup; comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"; check "stale equal patch allowed" 0 '^MERGED' 1
setup; comments="Verdict: PASS+NOTES head=$SHA verifier=ctx_verify author=ctx_author"; check "PASS+NOTES allowed" 0 '^MERGED' 1
setup; files='[{"path":"docs/guide.txt"},{"path":"README.md"},{"path":"changelog.d/change.txt"}]'; comments=""; check "docs only skips verdict" 0 '^MERGED' 1
setup; files='[{"path":".claude/agents/qa-sdet.md"}]'; comments=""; check "agent instructions require verdict" 1 'verdict'
setup; files='[{"path":"docs/guide.md"}]'; body=""; comments=""; check "docs still needs Verification" 1 'Verification'

setup; files='[{"path":"templates/agent-team/.claude/agents/qa-sdet.md"}]'; comments=""; check "template agents require verdict" 1 'verdict'
setup; COMMENTS_JSON=$(jq -n --arg sha "$SHA" '[{body:("Checks: PASS head="+$sha)},{body:("Verdict: PASS head="+$sha+" verifier=ctx_verify author=ctx_author")},{body:("Verdict: FAIL head="+$sha+" verifier=ctx_verify author=ctx_author")}]'); check "newer FAIL supersedes PASS" 1 'verdict'

setup; body=$'## Verification\n- Ran the script: passed.\n## Test plan'; check "Test plan forbidden" 1 'Test plan'
setup; checks=""; check "missing exact head checks refused" 1 'Checks'
setup; checks="Checks: FAIL head=$SHA"; check "failed checks refused" 1 'Checks'
setup; checks="Checks: PASS head=$OLD"; check "stale checks refused" 1 'Checks'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_same author=ctx_same"; check "author cannot verify" 1 'verdict'
setup; PR_DIFF=$'+test.skip("case", () => {})'; check "test skip needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+// @ts-expect-error intentional'; check "suppression needs countersign" 1 'Countersign'
setup; files='[{"path":".agents/head-checks.conf"}]'; check "check config needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+test.skip("case", () => {})'; countersign="Countersign: Elon head=$SHA reason=fixture only"; check "countersigned skip allowed" 0 '^MERGED' 1
setup; TRUNK_FILES="script/foo.sh"; export TRUNK_FILES; check "overlapping trunk drift refused" 1 'rebase and rerun head-checks'
setup; TRUNK_FILES="unrelated.sh"; export TRUNK_FILES; check "disjoint trunk drift allowed" 0 '^MERGED' 1
setup; files='[{"path":".agents/skills/a/SKILL.md"}]'; comments=""; check "skills need verifier" 1 'verdict'

# Exercise the script with real commit graphs and git patch-id, not asserted IDs.
setup
export REAL_PATCH_REPO="$tmp/patch-repo"
"$REAL_GIT" init -q "$REAL_PATCH_REPO"
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.name Fixture
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.email fixture@example.invalid
printf 'base\n' > "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add code
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm base
base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
printf 'change\n' >> "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qam change
OLD=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REAL_PATCH_REPO" checkout -q --detach "$base_sha"
printf 'unrelated\n' > "$REAL_PATCH_REPO/other"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add other
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm advance-base
base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
"$REAL_GIT" -C "$REAL_PATCH_REPO" remote add origin "$REAL_PATCH_REPO"
"$REAL_GIT" -C "$REAL_PATCH_REPO" cherry-pick "$OLD" >/dev/null
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"
checks="Checks: PASS head=$SHA"
check "real rebase keeps stable patch verdict" 0 '^MERGED' 1
rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
printf 'different\n' >> "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qam different
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
checks="Checks: PASS head=$SHA"
check "real changed patch invalidates verdict" 1 'verdict'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
