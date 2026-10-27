#!/usr/bin/env bash
# Tests for lead-merge.sh with gh and git stubbed on PATH.
# shellcheck disable=SC2089,SC2090,SC2015
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/orca/workspaces/proj/lead-x" "$HOME/orca/workspaces/proj/fullstack-dev-x" "$tmp/other/lead-y" "$tmp/bin"
LEAD="$HOME/orca/workspaces/proj/lead-x"

REAL_GIT=$(command -v git); export REAL_GIT
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null  # offline: local paths only
# git stub: rev-parse --show-toplevel prints $FAKE_TOP.
cat > "$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "$1" = rev-parse ] && [ "${2:-}" = --show-toplevel ] && { echo "$FAKE_TOP"; exit 0; }
[ -z "${REAL_PATCH_REPO:-}" ] || exec "$REAL_GIT" -C "$REAL_PATCH_REPO" "$@"
case "$1" in
  cat-file|fetch) exit 0 ;;
  merge-base) echo cccccccccccccccccccccccccccccccccccccccc ;;
  diff) case "$*" in *--name-only*) printf '%s\n' "$TRUNK_FILES" ;; *) echo current ;; esac ;;
  *) exit 1 ;;
esac
EOS
# gh stub: view prints $PR_JSON (or $FINAL_JSON after a merge), diff prints the file $PR_DIFF_FILE,
# merge logs the call and fails MERGE_FAILS times first.
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  [[ "$*" = *--paginate* ]] || exit 1
  printf '%s' "$API_FILES"
  exit 0
fi
case "$2" in
  view)
    if [[ "$*" == *"--repo d/dotfiles"* ]]; then printf '%s' "$VERDICT_PR_JSON"; elif [ -f "$MERGE_LOG" ] && grep -q ok "$MERGE_LOG"; then printf '%s' "$FINAL_JSON"; else printf '%s' "$PR_JSON"; fi ;;
  diff) cat "$PR_DIFF_FILE" ;;
  merge)
    echo "$*" >> "$MERGE_LOG.calls"
    n=$(wc -l < "$MERGE_LOG.calls")
    if [ "$n" -le "${MERGE_FAILS:-0}" ]; then echo "boom" >&2; exit 1; fi
    echo ok >> "$MERGE_LOG" ;;
esac
EOS
# orca stub: run-list returns run_a and run_b. worker-list pages of FAKE_DISPATCHES
# (run_a, also the bound run when --run is absent) or FAKE_DISPATCHES_B (run_b), two ids per page.
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
[ "${FAKE_ORCA_FAIL:-}" != 1 ] || exit 1
if [ "$1 $2" = "orchestration run-list" ]; then
  echo '{"ok":true,"result":{"runs":[{"id":"run_a"},{"id":"run_b"}],"nextCursor":null}}'; exit 0
fi
[ "$1 $2" = "orchestration worker-list" ] || exit 1
start=0; prev=""; run=""
for a in "$@"; do
  [ "$prev" = --cursor ] && start=$a
  [ "$prev" = --run ] && run=$a
  prev=$a
done
if [ "$run" = run_b ]; then read -ra ids <<<"${FAKE_DISPATCHES_B:-}"; else read -ra ids <<<"$FAKE_DISPATCHES"; fi
w=""; for ((i=start; i<start+2 && i<${#ids[@]}; i++)); do w="$w${w:+,}{\"dispatchId\":\"${ids[i]}\"}"; done
next=null; [ $((start+2)) -ge ${#ids[@]} ] || next="\"$((start+2))\""
printf '{"ok":true,"result":{"workers":[%s],"page":{"nextCursor":%s}}}\n' "$w" "$next"
EOS
chmod +x "$tmp/bin/"*
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export PATH="$tmp/bin:$PATH"
export MERGE_LOG="$tmp/merge.log"

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
setup() {
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
  FAKE_TOP="$LEAD"; MERGE_FAILS=0; PR_DIFF=""
  COMMENTS_JSON=""; API_OVERRIDE=""; COUNT_OVERRIDE=""
  base_sha=cccccccccccccccccccccccccccccccccccccccc
  files='[{"path":"script/foo.sh"}]'
  body=$'## Verification\n- Ran script successfully.'
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
  checks="Checks: PASS head=$SHA"; countersign=""; TRUNK_FILES=""
  export TRUNK_FILES
  export FAKE_DISPATCHES="ctx_a ctx_b ctx_author ctx_other ctx_same ctx_verify"; unset FAKE_ORCA_FAIL FAKE_DISPATCHES_B
  export OLD
  state=OPEN base=main headsha=$SHA mergeable=MERGEABLE branch=feature
  FINAL_JSON='{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"url":"https://github.com/o/r/pull/7"}'
}
mkjson() {
  PR_JSON=$(printf '{"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","mergeable":"%s","url":"https://github.com/o/r/pull/7","files":%s}' \
    "$state" "$base" "$branch" "$headsha" "$mergeable" "$files")
  PR_JSON=$(jq --arg body "$body" --arg comments "$comments" --arg checks "$checks" --arg countersign "$countersign" --arg base "$base_sha" '. + {body:$body, baseRefOid:$base, closingIssuesReferences:('"${CLOSING_JSON:-[]}"'), comments:[$checks,$comments,$countersign | {body:.}]}' <<<"$PR_JSON")
  [ -z "$COMMENTS_JSON" ] || PR_JSON=$(jq --argjson comments "$COMMENTS_JSON" '.comments=$comments' <<<"$PR_JSON")
  API_FILES=${API_OVERRIDE:-$(jq '[.files[] | {filename:.path}]' <<<"$PR_JSON")}
  PR_JSON=$(jq --argjson count "${COUNT_OVERRIDE:-$(jq length <<<"$API_FILES")}" '.changedFiles=$count' <<<"$PR_JSON")
  export API_FILES
  printf '%s' "$PR_DIFF" > "$MERGE_LOG.diff"; export PR_DIFF_FILE="$MERGE_LOG.diff"
  export PR_JSON FINAL_JSON FAKE_TOP MERGE_FAILS
}

# Cases run in parallel, in two ways. Plain check calls in the main shell snapshot the
# mutable state (HOME, the fixture repo, a LEAD_MERGE gate dir)
# into $tmp/cases/N and run in the background. Setup heavy groups run as units
# (`unit; ( unit_init ... ) &`): a subshell with its own HOME, repo and gate dir, whose
# checks run inline. ONLY=<regex> runs just the cases whose name matches; JOBS=<n>
# sets the parallelism.
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
mkdir -p "$tmp/cases" "$tmp/units"; n=0; UNIT=0
throttle() { while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.02; done; }
unit() { UNIT=$((UNIT+1)); throttle; }
unit_init() {
  IN_UNIT=1; ucd="$tmp/units/$(printf %04d "$UNIT")"; cn=0
  mkdir -p "$ucd/home/orca/workspaces/proj/lead-x/.claude/hooks" "$ucd/home/orca/workspaces/proj/fullstack-dev-x" "$ucd/home/.config"
  export HOME="$ucd/home" MERGE_LOG="$ucd/merge.log"
  LEAD="$HOME/orca/workspaces/proj/lead-x"
}
run_case() { # result_file run_script name expected_exit output_regex [merge_calls] [merge_call_regex]
  local res=$1 run=$2; shift 2
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
  if [ -n "${REAL_PATCH_REPO:-}" ]; then
    # Offline origin: a local bare clone of the fixture repo.
    rm -rf "$REAL_PATCH_REPO.origin.git"
    cp -R "$REAL_PATCH_REPO/.git" "$REAL_PATCH_REPO.origin.git"
    "$REAL_GIT" -C "$REAL_PATCH_REPO.origin.git" config core.bare true
    "$REAL_GIT" -C "$REAL_PATCH_REPO" remote set-url origin "$REAL_PATCH_REPO.origin.git"
  fi
  mkjson
  # Linux refuses to exec anything when one env string passes 128KB (macOS does not); the generated
  # copy diff is far bigger, so it must reach the gh stub through a file, never the environment.
  big=$(awk 'BEGIN { for (k in ENVIRON) if (length(ENVIRON[k]) > m) m = length(ENVIRON[k]); print m + 0 }')
  if [ "$big" -gt 100000 ]; then printf 'FAIL %s (an exported variable is %s bytes, over the 128KB Linux exec limit)\n' "$1" "$big" > "$res"; return; fi
  out=$("$run" --repo "${REPO:-o/r}" --pr 7 --head "$SHA" ${VFROM:+--verdict-from "$VFROM"} ${MECH:+--mechanical} ${VCMD:+--verify-command "$VCMD"} 2>&1); code=$?
  calls=0; [ -f "$MERGE_LOG.calls" ] && calls=$(wc -l < "$MERGE_LOG.calls" | tr -d ' ')
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3" && [ "$calls" = "${4:-0}" ] \
    && { [ -z "${5:-}" ] || grep -qE -- "$5" "$MERGE_LOG.calls"; }; then echo "ok   $1" > "$res"
  else printf 'FAIL %s (exit %s, merge calls %s)\n%s\n' "$1" "$code" "$calls" "$out" > "$res"; fi
}
check() { # name expected_exit output_regex [merge_calls] [merge_call_regex]
  if [ -n "${ONLY:-}" ] && ! grep -qE -- "$ONLY" <<<"$1"; then return 0; fi
  if [ -n "${IN_UNIT:-}" ]; then
    cn=$((cn+1)); run_case "$ucd/result.$(printf %04d "$cn")" "${LEAD_MERGE:-$here/lead-merge.sh}" "$@"; return
  fi
  n=$((n+1)); local id cd; id=$(printf %04d "$n"); cd="$tmp/cases/$id"
  mkdir -p "$cd/home/orca/workspaces/proj/lead-x/.claude/hooks" "$cd/home/orca/workspaces/proj/fullstack-dev-x" "$cd/home/.config"
  [ ! -f "$LEAD/.claude/hooks/guard-bash.py" ] || cp "$LEAD/.claude/hooks/guard-bash.py" "$cd/home/orca/workspaces/proj/lead-x/.claude/hooks/"
  [ ! -d "$HOME/.config" ] || cp -R "$HOME/.config/." "$cd/home/.config/"
  throttle
  (
    old_home="$tmp/home"
    export HOME="$cd/home" MERGE_LOG="$cd/merge.log"
    FAKE_TOP="${FAKE_TOP/#$old_home/$HOME}"
    run_case "$cd/result" "$here/lead-merge.sh" "$@"
  ) &
}
report() {
  wait
  pass=0; fail=0
  for r in "$tmp"/cases/*/result "$tmp"/units/*/result.*; do
    [ -f "$r" ] || continue
    cat "$r"
    if [ "$(head -c 2 "$r")" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  done
  echo "passed $pass, failed $fail"
  [ "$fail" = 0 ]
}

# Fixture repo template, built once; copy_setup clones it by copy.
  r="$tmp/copy-template"
  "$REAL_GIT" init -q -b fixture "$r"
  "$REAL_GIT" -C "$r" config user.name Fixture
  "$REAL_GIT" -C "$r" config user.email fixture@example.invalid
  mkdir -p "$r/web/src/app/i18n/locales/en" "$r/marketing/content" "$r/marketing/src"
  printf '{"greeting":"Hello"}\n' > "$r/web/src/app/i18n/locales/en/translation.json"
  printf '{"greeting":"Hello"}\n' > "$r/web/src/app/i18n/locales/en/marketing.json"
  printf 'Welcome\n' > "$r/marketing/content/home.md"
  printf 'export default 1;\n' > "$r/marketing/src/home.ts"
  "$REAL_GIT" -C "$r" add .
  "$REAL_GIT" -C "$r" commit -qm base
  "$REAL_GIT" -C "$r" update-ref refs/heads/main "$("$REAL_GIT" -C "$r" rev-parse HEAD)"

setup; check "success merges with match-head-commit" 0 '^MERGED https://github.com/o/r/pull/7 [0-9a-f]+$' 1 "--merge --match-head-commit $SHA"
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
# Mechanical lane: substitution or deletion only, no Verdict.
SUBST=$'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1,2 +1,2 @@\n-cd /Users/x/dotfiles\n+cd "$HOME/dotfiles"\n echo hi\n'
MECH=1
setup; comments=""; PR_DIFF="$SUBST"; check "mechanical substitution needs no verdict" 0 'mechanical lane' 1
setup; comments=""; PR_DIFF="$SUBST"$'diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n'; check "mechanical allows whole file deletion" 0 'mechanical lane' 1
setup; comments=""; PR_DIFF=$'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'; check "mechanical refuses added logic line" 1 'pure substitution'
setup; comments=""; PR_DIFF=$'diff --git a/script/a b/c.sh b/script/a b/c.sh\n--- a/script/a b/c.sh\n+++ b/script/a b/c.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'; check "mechanical names a path with spaces" 1 'script/a b/c.sh: 0 removed, 1 added'
setup; comments=""; PR_DIFF=$'diff --git a/script/new.sh b/script/new.sh\nnew file mode 100755\n--- /dev/null\n+++ b/script/new.sh\n@@ -0,0 +1 @@\n+echo hi\n'; check "mechanical refuses new script" 1 'new file'
setup; comments=""; PR_DIFF=$'diff --git a/a b/b\nsimilarity index 90%\nrename from a\nrename to b\n'; check "mechanical refuses rename" 1 'renames'
setup; comments=""; PR_DIFF="$SUBST"; checks="Checks: PASS head=$SHA"$'\nUnchecked paths: script/foo.sh'; check "mechanical refuses unchecked paths" 1 'unchecked'
setup; comments=""; PR_DIFF="$SUBST"; files='[{"path":".codex/config.toml"}]'; check "mechanical still refuses protected paths" 1 'owner through Elon'
setup; comments=""; PR_DIFF="$SUBST"; files='[{"path":"script/lead-merge.sh"}]'; check "mechanical gate file still needs countersign" 1 'Countersign'
setup; comments=""; PR_DIFF="$SUBST"; checks=""; check "mechanical still needs Checks PASS" 1 'Checks'
unset MECH
setup; MERGE_FAILS=1; check "one retry then success" 0 '^MERGED' 2
setup; MERGE_FAILS=2; check "merge failure prints error, exits 1" 1 'merge failed: boom' 2
setup; FINAL_JSON='{"state":"OPEN","url":"u"}'; check "unconfirmed merge fails" 1 'not MERGED' 1

setup; body="No heading"; check "missing Verification refused" 1 'Verification'
setup; body="## Verification"; check "empty Verification refused" 1 '1 to 3'
setup; body=$'## Verification\n- one\n- two\n- three\n- four'; check "excess Verification bullets refused" 1 '1 to 3'
setup; FINAL_JSON='{"state":"MERGED","url":"u","mergeCommit":null}'; check "missing merge commit refused" 1 'no merge commit' 1
setup; comments=""; check "missing verdict refused" 1 'verdict'
setup; comments="Verdict: FAIL head=$SHA verifier=ctx_verify author=ctx_author"; check "FAIL verdict refused" 1 'verdict'
setup; comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"; check "stale verdict without clean merge proof refused" 1 'verdict'
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
setup; comments="Verdict: PASS head=$SHA verifier=ctx_ghost author=ctx_author"; check "unknown verifier dispatch refused" 1 'ctx_ghost is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_ghost"; check "unknown author dispatch refused" 1 'ctx_ghost is not a known dispatch'
setup; export FAKE_ORCA_FAIL=1; check "orca CLI failure refuses" 1 'cannot read orca'
setup; FAKE_DISPATCHES="ctx_author"; export FAKE_DISPATCHES_B="ctx_verify"; check "verifier only in a non-bound run passes" 0 '^MERGED' 1
setup; FAKE_DISPATCHES="ctx_author"; export FAKE_DISPATCHES_B="ctx_other"; check "verifier in no run refused" 1 'ctx_verify is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=unknown"; check "author=unknown accepted" 0 '^MERGED' 1
setup; comments="Verdict: PASS head=$SHA verifier=ctx_ghost author=unknown"; check "author=unknown still needs known verifier" 1 'ctx_ghost is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_random"; check "random author id refused" 1 'ctx_random is not a known dispatch'
# T3, T20, T22 (spec #286, R6): ignored Verdicts are named by comment URL with a fix; a FAIL is retired only by a supersedes Countersign.
vc() { jq -nc --arg checks "Checks: PASS head=$SHA" --argjson rest "$1" '[{body:$checks}] + $rest'; }
VP="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
VF="Verdict: FAIL head=$SHA verifier=ctx_other author=ctx_author"
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg v "$VP" '[{body:("Findings first."+"\n"+$v),url:"https://x.test/c#line2"}]')")
check "T3 Verdict on line 2 is named by URL with the fix line" 1 'ignored Verdict https://x.test/c#line2: .*first line.*Fix: .*post-verdict\.sh'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg v "Verdict: PASS head=$SHA verifier=ctx_verify" '[{body:$v,url:"https://x.test/c#noauthor"}]')")
check "T3 Verdict without author= is named by URL with the fix line" 1 'ignored Verdict https://x.test/c#noauthor: .*author=.*Fix: .*post-verdict\.sh'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg v "$VP" '[{body:$v,url:"https://x.test/c#edited",includesCreatedEdit:true}]')")
check "T20 an edited PASS is ignored and named by URL" 1 'ignored Verdict https://x.test/c#edited: .*edited or minimized.*Fix: .*post-verdict\.sh'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg v "$VP" '[{body:$v,url:"https://x.test/c#min",isMinimized:true}]')")
check "T20 a minimized PASS is ignored and named by URL" 1 'ignored Verdict https://x.test/c#min: .*edited or minimized'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg v "$VP" '[{body:$v,url:"https://x.test/c#edited",includesCreatedEdit:true},{body:$v,url:"https://x.test/c#fresh"}]')")
check "T20 a fresh PASS after an edited one merges and names nothing" 0 '^MERGED' 1
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" '[{body:$f,url:"https://x.test/c#fail",includesCreatedEdit:true},{body:$p,url:"https://x.test/c#pass"}]')")
check "T20 an edited FAIL still blocks and is not named as ignored" 1 'conflicting'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" '[{body:$f,url:"https://x.test/c#fail"},{body:$p,url:"https://x.test/c#pass"}]')")
check "T22 FAIL then PASS without a Countersign refuses" 1 'conflicting'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" --arg c "Countersign: Elon head=$SHA reason=supersedes https://x.test/c#fail" '[{body:$f,url:"https://x.test/c#fail"},{body:$p,url:"https://x.test/c#pass"},{body:$c}]')")
check "T22 FAIL, supersedes Countersign naming it, newer PASS: merges" 0 '^MERGED' 1
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" --arg c "Countersign: Elon head=$SHA reason=supersedes https://x.test/c#other" '[{body:$f,url:"https://x.test/c#fail"},{body:$p,url:"https://x.test/c#pass"},{body:$c}]')")
check "T22 a Countersign naming another comment does not retire the FAIL" 1 'conflicting'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" --arg c "Countersign: Elon head=$OLD reason=supersedes https://x.test/c#fail" '[{body:$f,url:"https://x.test/c#fail"},{body:$p,url:"https://x.test/c#pass"},{body:$c}]')")
check "T22 a supersedes Countersign for another head does not retire the FAIL" 1 'conflicting'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg c "Countersign: Elon head=$SHA reason=supersedes https://x.test/c#fail" '[{body:$f,url:"https://x.test/c#fail"},{body:$c}]')")
check "T22 a retired FAIL with no PASS still refuses for the missing PASS" 1 'missing passing verifier verdict'
setup; COMMENTS_JSON=$(vc "$(jq -nc --arg f "$VF" --arg p "$VP" --arg c "Countersign: Elon head=$SHA reason=supersedes https://x.test/c#fail" '[{body:$p,url:"https://x.test/c#pass"},{body:$f,url:"https://x.test/c#fail"},{body:$c}]')")
check "T22 a PASS older than the FAIL it retires does not count" 1 'missing passing verifier verdict'
setup; PR_DIFF=$'+test.todo("later")'; COMMENTS_JSON=$(vc "$(jq -nc --arg p "$VP" --arg c "Countersign: Elon head=$SHA reason=supersedes https://x.test/c#fail" '[{body:$p,url:"https://x.test/c#pass"},{body:$c}]')")
check "T22 a supersedes Countersign is not the gate Countersign" 1 'Countersign'
setup; FAKE_DISPATCHES="ctx_a ctx_b ctx_c ctx_d ctx_author ctx_verify"; check "dispatch ids found on a later page" 0 '^MERGED' 1
setup; PR_DIFF=$'+  it("test.todos", () => {})'; check "test.todos is not a skip trigger" 0 '^MERGED' 1
setup; PR_DIFF=$'+test.todo("later")'; check "test.todo needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+System.exit(1);'; check "System.exit is not a skip trigger" 0 '^MERGED' 1
setup; PR_DIFF=$'+foo.exit(0)'; check "foo.exit is not a skip trigger" 0 '^MERGED' 1
setup; PR_DIFF=$'+xit("case", () => {})'; check "xit needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+  xit('"'"; check "indented xit needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+.only("case")'; check "trigger .only needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+// eslint-disable-next-line'; check "trigger eslint-disable-next-line needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+// biome-ignore lint'; check "trigger biome-ignore lint needs countersign" 1 'Countersign'
setup; PR_DIFF=$'+// @ts-ignore'; check "trigger @ts-ignore needs countersign" 1 'Countersign'
setup; files='[{"path":".agents/head-checks.conf"}]'; PR_DIFF=$'+++ b/.agents/head-checks.conf\n+echo changed'; check "check config prints countersign trigger" 1 'head-checks.conf:\+echo changed'
setup; PR_DIFF=$'+test.skip("case", () => {})'; countersign="Countersign: Elon head=$SHA reason=fixture only"; check "countersigned skip allowed" 0 '^MERGED' 1
# A stale countersign requires proof that only clean merges of main followed it.
setup; PR_DIFF=$'+test.skip("case", () => {})'; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"; countersign="Countersign: Elon head=$OLD reason=fixture only"; check "stale countersign without clean merge proof refused" 1 'Countersign'
setup; PR_DIFF=$'+test.skip("case", () => {})'; comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"; countersign="Countersign: Elon head=$OLD reason=fixture only"; checks="Checks: PASS head=$OLD"; check "countersign refused without checks on the current head" 1 'Checks: PASS'
setup; TRUNK_FILES="script/foo.sh"; export TRUNK_FILES; check "overlapping trunk drift refused" 1 'rebase and rerun head-checks'
setup; TRUNK_FILES="unrelated.sh"; export TRUNK_FILES; check "disjoint trunk drift allowed" 0 '^MERGED' 1
setup; files='[{"path":".agents/skills/a/SKILL.md"}]'; comments=""; check "skills need verifier" 1 'verdict'

setup; API_OVERRIDE=$(jq -n '[range(101) | {filename:("docs/"+tostring+".md")}] + [{filename:".claude/hooks/late.py"}]'); check "paginated owner path after 100 refused" 1 'late.py'
setup; COUNT_OVERRIDE=2; check "incomplete file inventory refused" 1 'file count'

setup; body=$'## Verification\n- Ran script: passed.\n## Test plan:'; check "punctuated Test plan refused" 1 'Test plan'
setup; body=$'##  vERIFICATION :  \n- Ran script: passed.'; check "normalized Verification accepted" 0 '^MERGED' 1
setup; body=$'## Verification\n- Ran script: passed.\n   ##  Test    plan :  '; check "indented Test plan refused" 1 'Test plan'
setup; body=$'   ##  Verification  \n- Ran script: passed.'; check "indented Verification accepted" 0 '^MERGED' 1

setup; checks=$'Checks: PASS head='"$SHA"$'\nUnchecked paths: jellyfin/Thing.cs'; check "unchecked needs live verdict coverage" 1 'unchecked'
setup; checks=$'Checks: PASS head='"$SHA"$'\nUnchecked paths: jellyfin/Thing.cs'; comments+=$'\nRan unchecked Jellyfin paths live: passed.'; check "unchecked live coverage allows merge" 0 '^MERGED' 1

copy_setup() {
  setup
  export REAL_PATCH_REPO="${ucd:-$tmp}/copy-repo"
  rm -rf "$REAL_PATCH_REPO"
  cp -R "$tmp/copy-template" "$REAL_PATCH_REPO"
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" remote add origin "$REAL_PATCH_REPO"
}
copy_commit() {
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm copy
  SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
  PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
  files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})')
  checks="Checks: PASS head=$SHA"
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
}
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
# Every applicable Verdict counts; none of them can erase another.
verdict_json() { # body [edited] [minimized]
  jq -n --arg body "$1" --argjson edited "${2:-false}" --argjson min "${3:-false}" '{body:$body,includesCreatedEdit:$edited,isMinimized:$min}'
}
v_pass="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
v_fail="Verdict: FAIL head=$SHA verifier=ctx_other author=ctx_author"
comments_of() { jq -s --arg checks "$checks" '[{body:$checks}] + .'; }
COMMENTS_JSON=$({ verdict_json "$v_pass"; verdict_json "$v_fail"; } | comments_of)
check "conflicting PASS and FAIL verdicts refused" 1 'conflicting'
COMMENTS_JSON=$({ verdict_json "$v_fail"; verdict_json "$v_pass"; } | comments_of)
check "conflicting FAIL then PASS verdicts refused" 1 'conflicting'
COMMENTS_JSON=$({ verdict_json "$v_pass" true; } | comments_of)
check "edited verdict refused" 1 'edited or minimized'
COMMENTS_JSON=$({ verdict_json "$v_pass" false true; } | comments_of)
check "minimized verdict refused" 1 'edited or minimized'
COMMENTS_JSON=$({ verdict_json "$v_pass" true; verdict_json "$v_pass"; } | comments_of)
check "fresh Verdict after an edited one merges" 0 '^MERGED' 1
COMMENTS_JSON=$({ verdict_json "$v_fail" true; verdict_json "$v_pass"; } | comments_of)
check "edited FAIL still blocks a fresh PASS" 1 'conflicting'
COMMENTS_JSON=$({ verdict_json "Findings first."$'\n'"$v_pass"; } | comments_of)
check "Verdict below other text names the first-line rule" 1 'not the first line'
COMMENTS_JSON=$({ verdict_json "$v_pass"; } | comments_of)
check "locale copy merges on a plain Verdict" 0 '^MERGED' 1
# --verify-command: the newest Verdict must carry the same Command: line.
VCMD="bun test --isolate a.test.ts"
COMMENTS_JSON=$({ verdict_json "$v_pass"$'\nCommand:  bun test --isolate a.test.ts '; } | comments_of)
check "verify-command match merges" 0 '^MERGED' 1
COMMENTS_JSON=$({ verdict_json "$v_pass"$'\nCommand: bun test --isolate --no-deps a.test.ts'; } | comments_of)
check "verify-command mismatch refused" 1 'Command mismatch'
COMMENTS_JSON=$({ verdict_json "$v_pass"; } | comments_of)
check "verify-command missing line refused" 1 'no Command: line'
VCMD="  "
check "empty verify-command value refused" 1 'is empty'
VCMD=""
check "no verify-command flag leaves missing line alone" 0 '^MERGED' 1
COMMENTS_JSON=""

) </dev/null &
unit; (
unit_init
unset REAL_PATCH_REPO
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Exercise the script with real commit graphs and content changes.
setup
export REAL_PATCH_REPO="$ucd/patch-repo"
"$REAL_GIT" init -q "$REAL_PATCH_REPO"
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.name Fixture
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.email fixture@example.invalid
printf 'base\n' > "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add code
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm base
base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
printf 'value = "ab"\n' >> "$REAL_PATCH_REPO/code"
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
check "real rebase requires fresh verdict" 1 'verdict'
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
PR_DIFF=$'+test.skip("case", () => {})'
countersign="Countersign: Elon head=$OLD reason=fixture only"
check "real rebase requires fresh countersign" 1 'Countersign'
PR_DIFF=""; countersign=""
whitespace_verdict_head=$SHA
printf 'base\nvalue = "a b"\n' > "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qam whitespace
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
checks="Checks: PASS head=$SHA"
comments="Verdict: PASS head=$whitespace_verdict_head verifier=ctx_verify author=ctx_author"
check "real inline whitespace change invalidates verdict" 1 'verdict'
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"
PR_DIFF=$'+test.skip("case", () => {})'
countersign="Countersign: Elon head=$whitespace_verdict_head reason=fixture only"
check "real inline whitespace change invalidates countersign" 1 'Countersign'
PR_DIFF=""; countersign=""
comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"
rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
printf 'different\n' >> "$REAL_PATCH_REPO/code"
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qam different
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
checks="Checks: PASS head=$SHA"
check "real changed patch invalidates verdict" 1 'verdict'

G() { "$REAL_GIT" -C "$REAL_PATCH_REPO" "$@"; }
set_main() { G update-ref refs/heads/main "$1"; G update-ref refs/remotes/origin/main "$1"; base_sha=$1; }

# Retained verdict and countersign when main was merged into the branch (real graph).
rr() { G checkout -q -B "$1" "$2"; }
rr main2 "$(G rev-parse refs/heads/main)"; mkdir -p "$REAL_PATCH_REPO/lib"
seq 1 10 > "$REAL_PATCH_REPO/lib/pr2.txt"; G add .; G commit -qm lib; M1=$(G rev-parse HEAD); set_main "$M1"
rr pr2 "$M1"; echo pr >> "$REAL_PATCH_REPO/lib/pr2.txt"; G commit -qam pr2; P=$(G rev-parse HEAD)
rr main3 "$M1"; sed -i.bak 's/^1$/one/' "$REAL_PATCH_REPO/lib/pr2.txt"; rm -f "$REAL_PATCH_REPO/lib/pr2.txt.bak"
G commit -qam trunk-edit; M2=$(G rev-parse HEAD); set_main "$M2"
G checkout -q pr2; G merge -q --no-edit main3 >/dev/null; Q=$(G rev-parse HEAD)
echo more >> "$REAL_PATCH_REPO/lib/pr2.txt"; G commit -qam pr2-more; R=$(G rev-parse HEAD)
files='[{"path":"lib/pr2.txt"}]'; PR_DIFF=""; countersign=""
SHA=$Q; headsha=$Q; checks="Checks: PASS head=$Q"; comments="Verdict: PASS head=$P verifier=ctx_verify author=ctx_author"
check "retained verdict ignores trunk already in the current head" 0 '^MERGED' 1
SHA=$P; headsha=$P; checks="Checks: PASS head=$P"; comments="Verdict: PASS head=$P verifier=ctx_verify author=ctx_author"
check "exact head without trunk still refused" 1 'trunk changed lib/pr2.txt' 
SHA=$Q; headsha=$Q; checks="Checks: PASS head=$Q"; comments="Verdict: PASS head=$P verifier=ctx_verify author=ctx_author"
PR_DIFF=$'+test.skip("case", () => {})'; countersign="Countersign: Elon head=$P reason=fixture only"
check "real merge of main keeps the countersign" 0 '^MERGED' 1
SHA=$R; headsha=$R; checks="Checks: PASS head=$R"; comments="Verdict: PASS head=$R verifier=ctx_verify author=ctx_author"
check "real changed patch loses the countersign" 1 'Countersign'

) </dev/null &
# Cleanup after the merge never removes a lead-* worktree, even when it holds the PR branch.
unit; (
unit_init
copy_setup
printf 'echo hi\n' > "$REAL_PATCH_REPO/marketing/src/hello.sh"
copy_commit
LEADY="$HOME/orca/workspaces/proj/lead-y"
"$REAL_GIT" -C "$REAL_PATCH_REPO" worktree add -q -b feature "$LEADY" HEAD
check "cleanup keeps a lead-* worktree that holds the PR branch" 0 'protected: kept worktree .*lead-y' 1
if [ -d "$LEADY" ]; then echo "ok   lead-y worktree still on disk" > "$ucd/result.9999"
else echo "FAIL lead-y worktree removed" > "$ucd/result.9999"; fi
) </dev/null &
# Generated team copies merge on the Verdict of the matching MERGED dotfiles PR.
unit; (
unit_init
copy_setup
DOTFILES="$here/.." bash "$here/sync-team-skills.sh" "$REAL_PATCH_REPO" >/dev/null 2>&1
copy_commit
comments=""; REPO=acme/project-alpha; VFROM=d/dotfiles#9; export VERDICT_PR_JSON VFROM
# Fixture dotfiles root: a git repo whose origin/main matches its templates (the gate reads its own checkout).
fx="$ucd/dot"; mkdir -p "$fx/script"
cp "$here/lead-merge.sh" "$here/sync-team-skills.sh" "$here/apply-local-overlay.py" "$here/lead-merge.config.example.json" "$fx/script/"; cp -R "$here/../templates" "$fx/templates"
"$REAL_GIT" -C "$fx" init -q -b main && "$REAL_GIT" -C "$fx" add . && "$REAL_GIT" -C "$fx" -c user.name=t -c user.email=t@t commit -qm fx
"$REAL_GIT" -C "$fx" update-ref refs/remotes/origin/main HEAD
LEAD_MERGE="$fx/script/lead-merge.sh"
DH=dddddddddddddddddddddddddddddddddddddd99
vpr() { VERDICT_PR_JSON=$(jq -nc --arg st "$1" --arg h "$DH" --arg c "$2" '{state:$st,headRefOid:$h,comments:[{body:$c}]}'); export VERDICT_PR_JSON; }
vprx() { VERDICT_PR_JSON=$(jq -nc --arg h "$DH" --argjson c "$1" '{state:"MERGED",headRefOid:$h,comments:$c}'); export VERDICT_PR_JSON; }
BADF="Verdict: FAIL head=$DH verifier=ctx_verify author=ctx_author"
GOOD="Verdict: PASS head=$DH verifier=ctx_verify author=ctx_author"
vpr MERGED "$GOOD"
check "verdict-from refuses without local config" 1 'no configured verdict_from_repos'
printf '{"verdict_from_repos":["acme/project-alpha","acme/project-beta"]}\n' > "$fx/script/lead-merge.local.json"
check "generated copies merge on the dotfiles PR Verdict" 0 'generated team copies' 1
VFROM=""; check "same PR without the flag is refused as a hand edit of a generated copy" 1 'edits generated team copy'
VFROM=d/dotfiles#9
REPO=o/r; check "verdict-from refuses an unconfigured repo" 1 'repo is not configured'
REPO=acme/project-beta; check "verdict-from works for a second configured repo" 0 'generated team copies' 1
REPO=acme/project-alpha
vpr OPEN "$GOOD"; check "verdict-from refuses an unmerged dotfiles PR" 1 'not MERGED'
vpr MERGED "Verdict: FAIL head=$DH verifier=ctx_verify author=ctx_author"; check "verdict-from refuses a FAIL Verdict" 1 'no passing Verdict'
vpr MERGED "Verdict: PASS head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb verifier=ctx_verify author=ctx_author"; check "verdict-from refuses a Verdict for another head" 1 'no passing Verdict'
vpr MERGED "Verdict: PASS head=$DH verifier=ctx_nobody author=ctx_author"; check "verdict-from refuses an unknown verifier dispatch" 1 'not a known dispatch'
vprx "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$g},{body:$f}]')"; check "verdict-from: a newer FAIL beats an older PASS" 1 'FAIL Verdict'
vprx "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f},{body:$g}]')"; check "verdict-from: an older FAIL beside a newer PASS refuses" 1 'FAIL Verdict'
vprx "$(jq -nc --arg g "$GOOD" '[{body:$g,includesCreatedEdit:true}]')"; check "verdict-from: an edited Verdict is refused" 1 'edited or minimized'
vprx "$(jq -nc --arg g "$GOOD" '[{body:$g,isMinimized:true}]')"; check "verdict-from: a minimized Verdict is refused" 1 'edited or minimized'
vprx "$(jq -nc --arg g "$GOOD" '[{body:$g,includesCreatedEdit:true},{body:$g}]')"; check "verdict-from: a fresh Verdict after an edited one merges" 0 'generated team copies' 1
vprx "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f,includesCreatedEdit:true},{body:$g}]')"; check "verdict-from: an edited FAIL still refuses" 1 'FAIL Verdict'
vpr MERGED "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_nobody"; check "verdict-from: an unknown author dispatch is refused" 1 'author ctx_nobody is not a known dispatch'
vpr MERGED "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_verify"; check "verdict-from: author equal to verifier is refused" 1 'author cannot supply'
vpr MERGED "$GOOD"
# A non-generated file keeps the normal rule.
echo hand > "$REAL_PATCH_REPO/notes.txt"; "$REAL_GIT" -C "$REAL_PATCH_REPO" add . && "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm extra
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA; checks="Checks: PASS head=$SHA"
files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})'); PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
check "verdict-from refuses a diff with a non-generated file" 1 'notes.txt is not'
# A file that merely carries the header string is not a generated copy.
"$REAL_GIT" -C "$REAL_PATCH_REPO" reset -q --hard HEAD~1
printf '<!-- Generated from dotfiles templates/agent-team/.agents/skills/x by script/sync-team-skills.sh, do not edit. -->\n' > "$REAL_PATCH_REPO/spoof.md"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add . && "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm spoof
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA; checks="Checks: PASS head=$SHA"
files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})'); PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
check "verdict-from refuses a file that only carries the header string" 1 'spoof.md is not'
# A hand edited generated copy fails sync-team-skills --check.
"$REAL_GIT" -C "$REAL_PATCH_REPO" reset -q --hard HEAD~1
f=$(ls "$REAL_PATCH_REPO"/.agents/skills/*/SKILL.md | head -n1); echo "hand edit" >> "$f"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add . && "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm edit
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA; checks="Checks: PASS head=$SHA"
files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})'); PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
check "verdict-from refuses a hand edited generated copy" 1 'sync-team-skills.sh --check fails'
# A symlink slipped into an owned skill directory is refused (sync --check lists regular files only).
"$REAL_GIT" -C "$REAL_PATCH_REPO" reset -q --hard HEAD~1
d=$(ls -d "$REAL_PATCH_REPO"/.agents/skills/*/ | head -n1); ln -s /etc/passwd "$d/evil"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add . && "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm link
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA; checks="Checks: PASS head=$SHA"
files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})'); PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
check "verdict-from refuses a symlink inside an owned skill directory" 1 'refuses symlink'
# A PR that changes a template must not vouch for its own generated copies: the dotfiles tree has to match origin/main.
"$REAL_GIT" -C "$REAL_PATCH_REPO" reset -q --hard HEAD~1
echo "unmerged template edit" >> "$(ls "$fx"/templates/agent-team/.agents/skills/*/SKILL.md | head -n1)"
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA; checks="Checks: PASS head=$SHA"
files=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff --name-only "$base_sha...$SHA" | jq -Rsc 'split("\n")[:-1] | map({path:.})'); PR_DIFF=$("$REAL_GIT" -C "$REAL_PATCH_REPO" diff "$base_sha...$SHA")
check "verdict-from refuses when the dotfiles tree differs from origin/main for templates/agent-team" 1 'not at origin/main'
# An untracked template file is invisible to git diff but sync-team-skills.sh copies it, so it must be refused too.
"$REAL_GIT" -C "$fx" checkout -q -- templates/agent-team
echo "untracked" > "$fx/templates/agent-team/untracked-template.md"
check "verdict-from refuses an untracked file under templates/agent-team" 1 'not at origin/main'
) </dev/null &
# T1: every refusal that needs no head-checks prints in one run, before any gh comment or merge.
(
  unit; unit_init
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}   # the git stub must not shadow real git
  mf_setup
  export HOME="$MF_DIR/home" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"; cd "$MF_REPO" || exit 1
  res="$ucd/result.9001"; fails=""
  body=$'## Verification\n- a\n- b\n- c\n- d\n- e\n\n## Test plan\n- x'
  mf_pr_add 5 t1 "$body" docs/t1.md
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B main origin/main
  mkdir -p docs; echo drift > docs/t1.md; "$MF_REAL_GIT" add docs/t1.md; "$MF_REAL_GIT" commit -q -m drift; "$MF_REAL_GIT" push -q origin main
  : > "$MF_GH_LOG"
  head=$(jq -r .headRefOid "$MF_GH_DIR/pr-5.json")
  out=$(bash "$here/lead-merge.sh" --repo o/r --pr 5 --head "$head" 2>&1); code=$?
  [ "$code" = 1 ] || fails="$fails exit=$code"
  for want in 'Test plan heading is forbidden' 'Verification needs 1 to 3' 'trunk changed docs/t1.md' 'missing current-head or containing-train Checks'; do
    grep -q "$want" <<<"$out" || fails="$fails missing[$want]"
  done
  ! grep -qE '^gh pr (comment|merge)' "$MF_GH_LOG" || fails="$fails mutated"
  mf_teardown
  if [ -z "$fails" ]; then echo "ok   T1 every refusal prints in one run and nothing mutates" > "$res"; else printf 'FAIL T1%s\n%s\n' "$fails" "$out" > "$res"; fi
) </dev/null &

# T14: two single runs started together on disjoint PRs serialize on the merge lock; both end MERGED, no trunk refusal.
(
  unit_init
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}   # the git stub must not shadow real git
  mf_setup
  export HOME="$MF_DIR/home" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"; cd "$MF_REPO" || exit 1
  res="$ucd/result.9014"; fails=""
  export LEAD_MERGE_CLEANUP=true
  mf_pr_add 1 t14a $'## Verification\n- Passed.' docs/t14a.md
  mf_pr_add 2 t14b $'## Verification\n- Passed.' docs/t14b.md
  for n in 1 2; do
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    jq --arg c "Checks: PASS head=$h" '.comments += [{body:$c, author:"fixture", edited:false, minimized:false}]' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  done
  # A gh that holds each merge for two seconds, so an unserialized second run overlaps the first.
  mkdir -p "$MF_DIR/slow"
  cat > "$MF_DIR/slow/gh" <<EOS
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  echo "gh MERGE-BEGIN \$3" >> "$MF_GH_LOG"; sleep 2; "$MF_BIN/gh" "\$@"; rc=\$?; echo "gh MERGE-END \$3" >> "$MF_GH_LOG"; exit \$rc
fi
exec "$MF_BIN/gh" "\$@"
EOS
  chmod +x "$MF_DIR/slow/gh"; export PATH="$MF_DIR/slow:$PATH"
  : > "$MF_GH_LOG"
  h1=$(jq -r .headRefOid "$MF_GH_DIR/pr-1.json"); h2=$(jq -r .headRefOid "$MF_GH_DIR/pr-2.json")
  mf_run_limited 60 bash "$here/lead-merge.sh" --repo o/r --pr 1 --head "$h1" > "$MF_DIR/out1" 2>&1 &
  p1=$!
  i=0; until grep -q 'MERGE-BEGIN' "$MF_GH_LOG"; do i=$((i+1)); [ "$i" -gt 300 ] && break; sleep 0.1; done
  mf_run_limited 60 bash "$here/lead-merge.sh" --repo o/r --pr 2 --head "$h2" > "$MF_DIR/out2" 2>&1; c2=$?
  wait "$p1"; c1=$?
  [ "$c1" = 0 ] && [ "$c2" = 0 ] || fails="$fails exit=$c1/$c2"
  [ "$(jq -r .state "$MF_GH_DIR/pr-1.json")$(jq -r .state "$MF_GH_DIR/pr-2.json")" = MERGEDMERGED ] || fails="$fails notmerged"
  cat "$MF_DIR/out1" "$MF_DIR/out2" | grep -q 'trunk changed' && fails="$fails trunk-refusal"
  # The second run reads nothing until the first has finished its merge.
  end_line=$(grep -n 'MERGE-END' "$MF_GH_LOG" | head -1 | cut -d: -f1)
  begin_line=$(grep -n 'MERGE-BEGIN' "$MF_GH_LOG" | head -1 | cut -d: -f1)
  between=$(sed -n "${begin_line},${end_line}p" "$MF_GH_LOG" | grep -c 'pr view')
  [ "$between" = 0 ] || fails="$fails overlapped"
  [ ! -e "$("$MF_REAL_GIT" rev-parse --git-common-dir)/lead-merge.lock" ] || fails="$fails lock-left"
  out=$(cat "$MF_DIR/out1" "$MF_DIR/out2")
  mf_teardown
  if [ -z "$fails" ]; then echo "ok   T14 two single runs on disjoint PRs serialize and both merge" > "$res"; else printf 'FAIL T14%s\n%s\n' "$fails" "$out" > "$res"; fi
) </dev/null &

# Cleanup call site (spec #286 T5, T12): the issue comes only from closingIssuesReferences, a failing cleanup never fails the merge.
unit; (
unit_init
cat > "$ucd/cleanup-stub" <<'EOS'
#!/usr/bin/env bash
echo "cleanup-args: $*"
exit "${CLEANUP_EXIT:-0}"
EOS
chmod +x "$ucd/cleanup-stub"
export LEAD_MERGE_CLEANUP="$ucd/cleanup-stub"
setup; branch=s9-2105; CLOSING_JSON='[]'
check "T5 no closing reference: no issue passed to cleanup, even with a number in the branch name" 0 'cleanup-args: --branch s9-2105 --head-sha [0-9a-f]+$' 1
CLOSING_JSON='[{"number":2105}]'
check "T5 closing reference 2105 is passed to cleanup" 0 'cleanup-args: --branch s9-2105 --head-sha [0-9a-f]+ --issue 2105$' 1
CLOSING_JSON='[]'; body=$'## Verification\n- Ran script successfully.\nCloses #4411'
check "T5 a Closes line in the body is not used" 0 'cleanup-args: --branch s9-2105 --head-sha [0-9a-f]+$' 1
CLEANUP_EXIT=1; export CLEANUP_EXIT
check "T12 failing cleanup: merge still exits 0 and says so" 0 'cleanup: incomplete \(merge succeeded\)' 1
check "T12 a cleanup: line prints before cleanup starts" 0 'cleanup: starting for s9-2105' 1
cn=$((cn+1)); rm -f "$MERGE_LOG" "$MERGE_LOG.calls"; mkjson; out=$("$here/lead-merge.sh" --repo o/r --pr 7 --head "$SHA" 2>&1); code=$?
if [ "$code" = 0 ] && [ "$(echo "$out" | grep -n '^MERGED' | cut -d: -f1)" -lt "$(echo "$out" | grep -n '^cleanup: starting' | cut -d: -f1)" ]; then echo "ok   T12 MERGED prints before the cleanup: line" > "$ucd/result.$(printf %04d "$cn")"
else printf 'FAIL T12 order (exit %s)\n%s\n' "$code" "$out" > "$ucd/result.$(printf %04d "$cn")"; fi
) </dev/null &
# T31 (spec #286, R6): a configured coordinator id may be the author, the verifier must still be a known dispatch.
unit; (
unit_init
cx="$ucd/dot"; mkdir -p "$cx/script"
cp "$here/lead-merge.sh" "$here/apply-local-overlay.py" "$here/lead-merge.config.example.json" "$cx/script/"
LEAD_MERGE="$cx/script/lead-merge.sh"
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_coord"
check "T31 a coordinator author is refused when none is configured" 1 'author ctx_coord is not a known dispatch or a configured coordinator id.*coordinator_ids'
printf '{"coordinator_ids":["ctx_coord"]}\n' > "$cx/script/lead-merge.local.json"
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_coord"
check "T31 a configured coordinator author with a dispatch verifier merges" 0 '^MERGED' 1
setup; comments="Verdict: PASS head=$SHA verifier=ctx_ghost author=ctx_coord"
check "T31 the same author with an unknown verifier is refused" 1 'verifier ctx_ghost is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_coord author=ctx_coord"
check "T31 a coordinator cannot be both author and verifier" 1 'author cannot supply verifier verdict'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_random"
check "T31 an id that is not configured is still refused" 1 'ctx_random is not a known dispatch'
) </dev/null &
report
