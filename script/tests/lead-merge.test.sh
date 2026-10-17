#!/usr/bin/env bash
# Tests for lead-merge.sh with gh and git stubbed on PATH.
# shellcheck disable=SC2089,SC2090,SC2015
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/orca/workspaces/proj/lead-x" "$HOME/orca/workspaces/proj/fullstack-dev-x" "$tmp/other/lead-y" "$tmp/bin"
LEAD="$HOME/orca/workspaces/proj/lead-x"

# git stub: rev-parse --show-toplevel prints $FAKE_TOP.
cat > "$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "$1" = rev-parse ] && { echo "$FAKE_TOP"; exit 0; }
exit 1
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

SHA=abc123
setup() {
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
  FAKE_TOP="$LEAD"; MERGE_FAILS=0; PR_DIFF=""
  files='[{"path":"script/foo.sh"}]'
  state=OPEN base=main headsha=$SHA mergeable=MERGEABLE branch=feature
  FINAL_JSON='{"state":"MERGED","url":"https://github.com/o/r/pull/7"}'
}
mkjson() {
  PR_JSON=$(printf '{"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","mergeable":"%s","url":"https://github.com/o/r/pull/7","files":%s}' \
    "$state" "$base" "$branch" "$headsha" "$mergeable" "$files")
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

setup; check "success merges with match-head-commit" 0 '^MERGED https://github.com/o/r/pull/7$' 1
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

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
