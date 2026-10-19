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
if [ "$1" = api ]; then
  [[ "$*" = *--paginate* ]] || exit 1
  printf '%s' "$API_FILES"
  exit 0
fi
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
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls" "$APPROVAL"
  FAKE_TOP="$LEAD"; MERGE_FAILS=0; PR_DIFF=""
  COMMENTS_JSON=""; API_OVERRIDE=""; COUNT_OVERRIDE=""
  base_sha=cccccccccccccccccccccccccccccccccccccccc
  files='[{"path":"script/foo.sh"}]'
  body=$'## Verification\n- Ran script successfully.'
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"; OLD_PATCH=current
  checks="Checks: PASS head=$SHA"; countersign=""; TRUNK_FILES=""
  export TRUNK_FILES
  export FAKE_DISPATCHES="ctx_a ctx_b ctx_author ctx_other ctx_same ctx_verify"; unset FAKE_ORCA_FAIL FAKE_DISPATCHES_B
  export OLD OLD_PATCH
  state=OPEN base=main headsha=$SHA mergeable=MERGEABLE branch=feature
  FINAL_JSON='{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"url":"https://github.com/o/r/pull/7"}'
}
mkjson() {
  PR_JSON=$(printf '{"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","mergeable":"%s","url":"https://github.com/o/r/pull/7","files":%s}' \
    "$state" "$base" "$branch" "$headsha" "$mergeable" "$files")
  PR_JSON=$(jq --arg body "$body" --arg comments "$comments" --arg checks "$checks" --arg countersign "$countersign" --arg base "$base_sha" '. + {body:$body, baseRefOid:$base, comments:[$checks,$comments,$countersign | {body:.}]}' <<<"$PR_JSON")
  [ -z "$COMMENTS_JSON" ] || PR_JSON=$(jq --argjson comments "$COMMENTS_JSON" '.comments=$comments' <<<"$PR_JSON")
  API_FILES=${API_OVERRIDE:-$(jq '[.files[] | {filename:.path}]' <<<"$PR_JSON")}
  PR_JSON=$(jq --argjson count "${COUNT_OVERRIDE:-$(jq length <<<"$API_FILES")}" '.changedFiles=$count' <<<"$PR_JSON")
  export API_FILES
  export OLD_PATCH
  export PR_JSON FINAL_JSON PR_DIFF FAKE_TOP MERGE_FAILS
}

# Owner copy approval is a terminal-only file, never a GitHub comment.
mkdir -p "$LEAD/.claude/hooks"
printf 'APPROVAL_NAMESPACE = "proj"  # fixture\n' > "$LEAD/.claude/hooks/guard-bash.py"
APPROVAL="$HOME/.config/proj/approval.json"
write_approval() { # scope target [offset seconds] [by] [patch_id]
  mkdir -p "$(dirname "$APPROVAL")"
  jq -n --arg scope "$1" --arg target "$2" --argjson off "${3:-+1800}" --arg by "${4:-mingster}" --arg pid "${5:-}" \
    '{scope:$scope,target:$target,patch_id:(if $pid == "" then null else $pid end),schema:false,apply:false,created_at:(now|floor),expires_at:((now|floor)+$off),by:$by}' > "$APPROVAL"
}

# Cases run in parallel, in two ways. Plain check calls in the main shell snapshot the
# mutable state (HOME with the approval file, the fixture repo, a LEAD_MERGE gate dir)
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
  cp "$LEAD/.claude/hooks/guard-bash.py" "$ucd/home/orca/workspaces/proj/lead-x/.claude/hooks/"
  export HOME="$ucd/home" MERGE_LOG="$ucd/merge.log"
  LEAD="$HOME/orca/workspaces/proj/lead-x"; APPROVAL="$HOME/.config/proj/approval.json"
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
  out=$("$run" --repo o/r --pr 7 --head "$SHA" 2>&1); code=$?
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
setup; files='[{"path":"script/copy-only.config.json"}]'; PR_DIFF=$'+++ b/script/copy-only.config.json\n+{"sensitive_words":[]}'; check "copy gate config needs countersign" 1 'Countersign'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_ghost author=ctx_author"; check "unknown verifier dispatch refused" 1 'ctx_ghost is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_ghost"; check "unknown author dispatch refused" 1 'ctx_ghost is not a known dispatch'
setup; export FAKE_ORCA_FAIL=1; check "orca CLI failure refuses" 1 'cannot read orca'
setup; FAKE_DISPATCHES="ctx_author"; export FAKE_DISPATCHES_B="ctx_verify"; check "verifier only in a non-bound run passes" 0 '^MERGED' 1
setup; FAKE_DISPATCHES="ctx_author"; export FAKE_DISPATCHES_B="ctx_other"; check "verifier in no run refused" 1 'ctx_verify is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=unknown"; check "author=unknown accepted" 0 '^MERGED' 1
setup; comments="Verdict: PASS head=$SHA verifier=ctx_ghost author=unknown"; check "author=unknown still needs known verifier" 1 'ctx_ghost is not a known dispatch'
setup; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_random"; check "random author id refused" 1 'ctx_random is not a known dispatch'
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
# A countersign follows an equal patch-id head (checks and verdict still bind the current head).
setup; PR_DIFF=$'+test.skip("case", () => {})'; comments="Verdict: PASS head=$OLD verifier=ctx_verify author=ctx_author"; countersign="Countersign: Elon head=$OLD reason=fixture only"; check "countersign retained on equal patch-id" 0 '^MERGED' 1
setup; PR_DIFF=$'+test.skip("case", () => {})'; comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"; countersign="Countersign: Elon head=$OLD reason=fixture only"; OLD_PATCH=different; check "countersign refused on different patch-id" 1 'Countersign'
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
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: none'
}
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nPhone-width screenshots in tw, en and jp.'
check "missing topic attestation refuses light route" 0 'lane=normal' 1
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: None\nPhone-width screenshots in tw, en and jp.'
check "malformed topic attestation refuses light route" 0 'lane=normal' 1
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: owner\nPhone-width screenshots in tw, en and jp.'
check "verifier owner attestation needs owner approval" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval copy "$SHA"
check "verifier owner attestation accepts current owner approval" 0 'lane=normal' 1
COMMENTS_JSON=""
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: none\nPhone-width screenshots in tw, en and jp.'
check "verifier none attestation allows plain light route" 0 'lane=copy-only' 1
COMMENTS_JSON=$(jq -n --arg checks "$checks" --arg head "$SHA" '[{body:$checks},{body:("Verdict: PASS head="+$head+" verifier=ctx_verify author=ctx_author\nPhone-width screenshots in tw, en and jp.")},{body:"Copy topics: none"}]')
check "separate non-verifier attestation refuses light route" 0 'lane=normal' 1
COMMENTS_JSON=""
comments="Verdict: PASS head=$SHA verifier=ctx_author author=ctx_author"$'\nCopy topics: none\nPhone-width screenshots in tw, en and jp.'
check "author cannot attest copy topics" 1 'author cannot'

# Every applicable Verdict counts: a later none never erases an earlier owner.
verdict_json() { # body [edited] [minimized]
  jq -n --arg body "$1" --argjson edited "${2:-false}" --argjson min "${3:-false}" '{body:$body,includesCreatedEdit:$edited,isMinimized:$min}'
}
shot=$'\nPhone-width screenshots in tw, en and jp.'
v_owner="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: owner'"$shot"
v_none="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: none'"$shot"
v_other="Verdict: PASS head=$SHA verifier=ctx_other author=ctx_author"$'\nCopy topics: none'"$shot"
v_fail="Verdict: FAIL head=$SHA verifier=ctx_other author=ctx_author"$'\nCopy topics: none'"$shot"
comments_of() { jq -s --arg checks "$checks" '[{body:$checks}] + .'; }
rm -f "$APPROVAL"
COMMENTS_JSON=$({ verdict_json "$v_owner"; verdict_json "$v_none"; } | comments_of)
check "later none after owner still needs owner approval" 1 'owner copy approval'
COMMENTS_JSON=$({ verdict_json "$v_owner"; verdict_json "$v_other"; } | comments_of)
check "later none by another verifier after owner needs owner approval" 1 'owner copy approval'
write_approval copy "$SHA"
check "later none after owner merges with current owner approval" 0 'lane=normal' 1
rm -f "$APPROVAL"
COMMENTS_JSON=$({ verdict_json "$v_none"; verdict_json "$v_fail"; } | comments_of)
check "conflicting PASS and FAIL verdicts refused" 1 'conflicting'
COMMENTS_JSON=$({ verdict_json "$v_fail"; verdict_json "$v_none"; } | comments_of)
check "conflicting FAIL then PASS verdicts refused" 1 'conflicting'
COMMENTS_JSON=$({ verdict_json "$v_none" true; } | comments_of)
check "edited verdict refused" 1 'edited or minimized'
COMMENTS_JSON=$({ verdict_json "$v_none" false true; } | comments_of)
check "minimized verdict refused" 1 'edited or minimized'
COMMENTS_JSON=$({ verdict_json "$v_owner"; verdict_json "$v_none" true; } | comments_of)
check "edited none after owner refused" 1 'edited or minimized'
COMMENTS_JSON=$({ verdict_json "$v_none"; } | comments_of)
check "unedited single none still light" 0 'lane=copy-only' 1
COMMENTS_JSON=""

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
check "copy-only needs phone screenshots for all locales" 1 'screenshots'
comments+=$'\nPhone-width screenshots of every changed page in tw, en and jp.'
check "values-only locale uses copy-only route" 0 'lane=copy-only' 1
checks="Checks: FAIL head=$SHA"
check "copy-only still requires passing checks" 1 'Checks'
checks="Checks: PASS head=$SHA"
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: none\nPhone-width screenshots in tw and en.'
check "copy-only missing jp screenshot evidence refused" 1 'screenshots'

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome","extra":"New"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
check "added locale key uses normal route" 0 'lane=normal' 1

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
printf 'export default 2;\n' > "$REAL_PATCH_REPO/marketing/src/home.ts"
copy_commit
check "locale plus ts uses normal route" 0 'lane=normal' 1

) </dev/null &
unit; (
unit_init
copy_setup
printf 'export default 2;\n' > "$REAL_PATCH_REPO/marketing/src/home.ts"
copy_commit
check "marketing code uses normal route" 0 'lane=normal' 1

) </dev/null &
unit; (
unit_init
copy_setup
printf 'Come in\n' > "$REAL_PATCH_REPO/marketing/content/home.md"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "marketing content uses copy-only route" 0 'lane=copy-only' 1

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome","price":"100"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
check "sensitive added key keeps owner gate on normal route" 1 'owner copy approval'

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
printf 'export default 2;\n' > "$REAL_PATCH_REPO/marketing/content/code.ts"
copy_commit
check "code under marketing content remains normal" 0 'lane=normal' 1

) </dev/null &
unit; (
unit_init
copy_setup
printf '{"greeting":"Refund available"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "sensitive wording without owner approval refused" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval promote "$SHA"
check "approval file with wrong scope refused" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval copy "$OLD"
check "approval file with wrong sha refused" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval copy "$SHA" -5
check "expired approval file refused" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval copy "$SHA" +99999
check "approval file claiming more than 30 minutes refused" 1 'owner copy approval'
COMMENTS_JSON=""; jq -n --arg sha "$SHA" '{approvals:[{scope:"host",target:null,expires_at:(now+600)},{scope:"copy",target:$sha,expires_at:(now+600)}]}' > "$APPROVAL"
check "stacked approval file with current copy entry accepted" 0 'lane=normal' 1
COMMENTS_JSON=""; jq -n --arg sha "$SHA" '{approvals:[{scope:"copy",target:$sha,expires_at:(now-5)},{scope:"host",target:null,expires_at:(now+600)}]}' > "$APPROVAL"
check "stacked approval file without valid copy entry refused" 1 'owner copy approval'
COMMENTS_JSON=""; printf 'not json' > "$APPROVAL"
check "unreadable approval file refused" 1 'owner copy approval'
COMMENTS_JSON=$(jq -n --arg checks "$checks" --arg verdict "$comments" --arg head "$SHA" '[{body:$checks},{body:$verdict},{author:{login:"mingster"},body:("Copy approval: head="+$head)}]')
rm -f "$APPROVAL"
check "GitHub Copy approval comment no longer approves" 1 'owner copy approval'
COMMENTS_JSON=""; write_approval copy "$SHA"
check "owner sensitive approval permits normal route merge" 0 'lane=normal' 1

# Round-6 omissions must require approval on every eligible surface, even when
# their count is unchanged and quantities are spelled out (no digit fallback).
) </dev/null &
for surface in en tw jp marketing; do
  for wording in pricing cost charge 價錢 定價 售價 法律 値段 代金 契約 法的; do
    # The locale file name does not change the path: each locale keeps its own language's words.
    case "$surface:$wording" in marketing:*|en:pricing|en:cost|en:charge|tw:價錢|tw:定價|tw:售價|tw:法律|jp:値段|jp:代金|jp:契約|jp:法的) ;; *) continue ;; esac
unit; (
unit_init
    copy_setup
    if [ "$surface" = marketing ]; then
      probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
      printf '%s alpha\n' "$wording" > "$probe_file"
    else
      probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/$surface/translation.json"
      mkdir -p "$(dirname "$probe_file")"
      jq -n --arg value "$wording alpha" '{message:$value}' > "$probe_file"
    fi
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm vocabulary-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
    if [ "$surface" = marketing ]; then
      printf '%s beta\n' "$wording" > "$probe_file"
    else
      jq -n --arg value "$wording beta" '{message:$value}' > "$probe_file"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "$surface r6 $wording needs approval" 1 'owner copy approval'
    if [ "$wording" = pricing ] && [ "$surface" != tw ] && [ "$surface" != jp ]; then
      COMMENTS_JSON=""; write_approval copy "$SHA"
      check "$surface r6 $wording owner approved" 0 'lane=normal' 1
    fi
) </dev/null &
  done
done
unit; (
unit_init

# r7 core vocabulary stays gated even with a verifier's none attestation.
) </dev/null &
for wording in penalty waiver arbitration litigation breach dues levy fare rent retainer reimburse clawback rescission annulment pledge undertake always never commit 押金 尾款 價差 加收 入場料 担保金 頭金 敷金 礼金 返款 返現 退錢 退購 退票 返納 返済 返却 払い戻す 償還 違約 違約金 仲裁 訴訟 準據法 著作權 準拠法 著作権 一定 必定 絕對 包退 包換 必ず 絶対 確実 万全 deliver tomorrow today 準時 送達 隔日 お届け 翌日; do
unit; (
unit_init
  copy_setup
  probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
  jq -n --arg text "$wording alpha" '{greeting:$text}' > "$probe_file"
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm topic-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  jq -n --arg text "$wording beta" '{greeting:$text}' > "$probe_file"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "r7 $wording none cannot override backstop" 1 'owner copy approval'
) </dev/null &
done
for pair in 'checkout_sign_in|Sign In|Continue'; do
unit; (
unit_init
  IFS='|' read -r key before after <<<"$pair"
  copy_setup
  probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
  jq -n --arg key "$key" --arg text "$before" '{($key):$text}' > "$probe_file"
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm label-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  jq -n --arg key "$key" --arg text "$after" '{($key):$text}' > "$probe_file"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "unchanged $key context alone stays light" 0 'lane=copy-only' 1
) </dev/null &
done
unit; (
unit_init

# Count-preserving topic changes still require current-head owner approval.
) </dev/null &
for surface in marketing locale; do
  for probe in price refund scope replace; do
unit; (
unit_init
    copy_setup
    case "$probe" in
      price) before="Price: \$100"; after="Price: \$200"; before_json='{"price":"100"}'; after_json='{"price":"200"}' ;;
      refund) before='Refund within 30 days'; after='Refund within 0 days'; before_json='{"refund":"within 30 days"}'; after_json='{"refund":"within 0 days"}' ;;
      scope) before='We promise service for one day'; after='We promise service for a thousand years'; before_json='{"message":"We promise service for one day"}'; after_json='{"message":"We promise service for a thousand years"}' ;;
      replace) before=$'We promise email support\nWelcome'; after=$'Welcome\nWe promise phone support'; before_json='{"first":"We promise email support","second":"Welcome"}'; after_json='{"first":"Welcome","second":"We promise phone support"}' ;;
    esac
    if [ "$surface" = marketing ]; then
      probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
      printf '%s\n' "$before" > "$probe_file"
    else
      probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
      printf '%s\n' "$before_json" > "$probe_file"
    fi
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm topic-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
    if [ "$surface" = marketing ]; then
      printf '%s\n' "$after" > "$probe_file"
    else
      printf '%s\n' "$after_json" > "$probe_file"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "$surface unchanged-count $probe needs approval" 1 'owner copy approval'
) </dev/null &
  done
done
unit; (
unit_init

# Retained text must participate when edits assemble a new sensitive occurrence.
) </dev/null &
for surface in marketing locale; do
  for probe in reorder replace; do
unit; (
unit_init
    copy_setup
    if [ "$probe" = reorder ]; then
      before=$'pro\nhello\nmise'
      after=$'pro\nmise\nhello'
      before_json='{"first":"pro","second":"hello","third":"mise"}'
      after_json='{"first":"pro","third":"mise","second":"hello"}'
    else
      before=$'pro\nWelcome'
      after=$'pro\nmise'
      before_json='{"first":"pro","second":"Welcome"}'
      after_json='{"first":"pro","second":"mise"}'
    fi
    if [ "$surface" = marketing ]; then
      probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
      printf '%s\n' "$before" > "$probe_file"
    else
      probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
      printf '%s\n' "$before_json" > "$probe_file"
    fi
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm fragment-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
    if [ "$surface" = marketing ]; then
      printf '%s\n' "$after" > "$probe_file"
    else
      printf '%s\n' "$after_json" > "$probe_file"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "$surface $probe across unchanged fragments needs approval" 1 'owner copy approval'
) </dev/null &
  done
done
unit; (
unit_init

# Existing sensitive wording may remain once while unrelated copy changes.
) </dev/null &
for surface in marketing locale; do
unit; (
unit_init
  copy_setup
  if [ "$surface" = marketing ]; then
    probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
    printf 'Our promise\nWelcome\n' > "$probe_file"
  else
    probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
    printf '{"first":"Our promise","second":"Welcome"}\n' > "$probe_file"
  fi
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm existing-term-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  if [ "$surface" = marketing ]; then
    printf 'Our promise\nCome in\n' > "$probe_file"
  else
    printf '{"first":"Our promise","second":"Come in"}\n' > "$probe_file"
  fi
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  if [ "$surface" = marketing ]; then
    check "marketing existing topic requires approval for any file edit" 1 'owner copy approval'
  else
    check "locale unchanged topic in another key uses light route" 0 'lane=copy-only' 1
  fi
  # An existing occurrence cannot hide a second occurrence of the same term.
  if [ "$surface" = marketing ]; then
    printf 'Our promise\npromise\n' > "$probe_file"
  else
    printf '{"first":"Our promise","second":"promise"}\n' > "$probe_file"
  fi
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "$surface increased sensitive count needs approval" 1 'owner copy approval'
) </dev/null &
done
unit; (
unit_init

# Literal currency symbols must not turn ordinary words into sensitive topics.
) </dev/null &
for wording in Continue; do
unit; (
unit_init
  copy_setup
  printf '{"greeting":"%s","price":"100"}\n' "$wording" > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm unchanged-price-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  printf '{"greeting":"%s please","price":"100"}\n' "$wording" > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "ordinary $wording beside unchanged price uses light route" 0 'lane=copy-only' 1
) </dev/null &
done
unit; (
unit_init

# Quantities are owner-held even when neither value nor key names a topic.
) </dev/null &
for surface in marketing locale; do
  for probe in digits '$' 'NT$' '¥' 元 円 USD TWD JPY '%'; do
    case "$surface:$probe" in marketing:*|locale:digits|'locale:$') ;; *) continue ;; esac
unit; (
unit_init
    copy_setup
    before='Open 10'; after='Open 20'
    if [ "$probe" != digits ]; then before="Open 10 $probe"; after='Open 10'; fi
    if [ "$surface" = marketing ]; then
      probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
      printf '%s\n' "$before" > "$probe_file"
    else
      probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
      jq -n --arg value "$before" '{greeting:$value}' > "$probe_file"
    fi
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm quantity-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
    if [ "$surface" = marketing ]; then
      printf '%s\n' "$after" > "$probe_file"
    else
      jq -n --arg value "$after" '{greeting:$value}' > "$probe_file"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "$surface changed $probe requires approval" 1 'owner copy approval'
) </dev/null &
  done
done
unit; (
unit_init

# Removed topic keys stay gated; an unchanged nested key alone stays light.
) </dev/null &
for probe in removed nested; do
unit; (
unit_init
  copy_setup
  probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
  printf '{"refund":{"message":"Available"},"greeting":"Hello"}\n' > "$probe_file"
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm nested-topic-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  if [ "$probe" = removed ]; then
    printf '{"greeting":"Hello"}\n' > "$probe_file"
  else
    printf '{"refund":{"message":"Unavailable"},"greeting":"Hello"}\n' > "$probe_file"
  fi
  copy_commit
  if [ "$probe" = removed ]; then
    check "$probe locale topic requires approval" 1 'owner copy approval'
  else
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "unchanged nested key context alone stays light" 0 'lane=copy-only' 1
  fi
) </dev/null &
done
unit; (
unit_init

# Diff-like content is still marketing text, never a patch header.
) </dev/null &
for wording in '++promise' '+++promise' '-- promise'; do
unit; (
unit_init
  copy_setup
  printf '%s\n' "$wording" > "$REAL_PATCH_REPO/marketing/content/home.md"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "diff-like marketing wording $wording needs approval" 1 'owner copy approval'
) </dev/null &
done
unit; (
unit_init

# Accents cannot conceal promises in any supported locale's changed values.
) </dev/null &
for locale in en tw; do
unit; (
unit_init
  copy_setup
  locale_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/$locale/translation.json"
  if [ "$locale" != en ]; then
    mkdir -p "$(dirname "$locale_file")"
    printf '{"greeting":"Hello"}\n' > "$locale_file"
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm locale-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  fi
  case "$locale" in
    en) wording='prómise' ;;
    tw) wording='保́證服務' ;;
    jp) wording='プラ́イバシー' ;;
  esac
  jq -n --arg value "$wording" '{greeting:$value}' > "$locale_file"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "combining marks in $locale locale need approval" 1 'owner copy approval'
) </dev/null &
done
unit; (
unit_init
copy_setup
printf '{"greeting":"prómise"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "precomposed English accent needs approval" 1 'owner copy approval'

# Each configured policy term is independently sensitive in added marketing text.
) </dev/null &
for wording in 'We promise unlimited service forever' PROMISE guarantee unlimited forever lifetime free refund price discount '%' 'NT$' '$' warranty compensation legal terms privacy 保證 承諾 無限 永久 終身 免費 退款 價格 折扣 優惠 賠償 條款 隱私 保証 約束 無制限 無料 返金 価格 割引 補償 規約 プライバシー pricing cost charge rate tariff billing payment subscription plan cancellation policy contract agreement liability promise 價錢 價目 售價 定價 收費 費率 付款 訂閱 方案 退費 政策 契約 合約 協議 責任 保固 値段 費用 手数料 支払 購読 サブスク プラン 払い戻し キャンセル 利用規約 ポリシー 同意 帳務 履約 定期購入 課金 解約 价格 价钱 定价 费用 无偿 無償; do
unit; (
unit_init
  copy_setup
  printf '%s\n' "$wording" > "$REAL_PATCH_REPO/marketing/content/home.md"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "sensitive added wording $wording needs approval" 1 'owner copy approval'
) </dev/null &
done
unit; (
unit_init
copy_setup
printf '{"greeting":"UnLiMiTeD service"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "locale customer promise needs approval" 1 'owner copy approval'

) </dev/null &
unit; (
unit_init
copy_setup
printf 'Refund available\n' > "$REAL_PATCH_REPO/marketing/content/home.md"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add .
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm sensitive-base
base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
printf 'Come in\n' > "$REAL_PATCH_REPO/marketing/content/home.md"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "removed marketing topic requires approval" 1 'owner copy approval'

# Rendered sensitive wording must retain the owner gate across copy surfaces.
) </dev/null &
for surface in marketing locale; do
  for wording in 'We pro**mise** unlim**ited** service for**ever**' '保**證**無**限**服務' '保**証**と無**制限**サービス' 'pro<strong>mise</strong>' '保<strong>證</strong>服務' '保<strong>証</strong>サービス' 'pro​mise' '保​證' '保​証' 'ＰＲＯＭＩＳＥ' 'pro&#109;ise' '保&#x8B49;' '保&#x8A3C;' $'pro\nmise'; do
    if [ "$surface" = locale ]; then case "$wording" in 'pro&#109;ise'|$'pro\nmise') ;; *) continue ;; esac; fi
unit; (
unit_init
    copy_setup
    if [ "$surface" = marketing ]; then
      printf '%s\n' "$wording" > "$REAL_PATCH_REPO/marketing/content/home.md"
    else
      jq -n --arg value "$wording" '{greeting:$value}' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "normalized $surface wording $wording needs approval" 1 'owner copy approval'
) </dev/null &
  done
done
unit; (
unit_init

) </dev/null &
unit; (
unit_init
copy_setup
printf 'Come in\n' > "$REAL_PATCH_REPO/marketing/content/hello world.md"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "plain copy path with spaces uses light route" 0 'lane=copy-only' 1
printf 'pro**mise**\n' > "$REAL_PATCH_REPO/marketing/content/hello world.md"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "sensitive copy path with spaces needs approval" 1 'owner copy approval'

) </dev/null &
unit; (
unit_init
copy_setup
printf 'bad \377 text\n' > "$REAL_PATCH_REPO/marketing/content/home.md"
copy_commit
comments+=$'\nPhone-width screenshots in tw, en and jp.'
check "undecodable copy requires approval" 1 'owner copy approval'

# Unreadable or invalid policy cannot silently waive the owner gate.
) </dev/null &
for policy in missing 'not json' '{"sensitive_words":[]}' '{"sensitive_words":[1]}' '{"sensitive_word_groups":{}}' '{"sensitive_word_groups":{"topic":{"en":{"words":["fee"]}}}}' '{"sensitive_word_groups":{"topic":{"en":{"words":["fee"]},"tw":{"words":[]},"jp":{"words":["料金"]}}}}'; do
unit; (
unit_init
  mkdir -p "$ucd/gate"; cp "$here/lead-merge.sh" "$ucd/gate/lead-merge.sh"; LEAD_MERGE="$ucd/gate/lead-merge.sh"
  copy_setup
  printf 'Come in\n' > "$REAL_PATCH_REPO/marketing/content/home.md"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  rm -f "$ucd/gate/copy-only.config.json"
  [ "$policy" = missing ] || printf '%s\n' "$policy" > "$ucd/gate/copy-only.config.json"
  check "invalid sensitive policy $policy needs approval" 1 'owner copy approval'
) </dev/null &
done
unit; (
unit_init
unset LEAD_MERGE

# Copy paths must contain ordinary text blobs, including additions.
) </dev/null &
for kind in binary symlink submodule deleted renamed; do
unit; (
unit_init
  copy_setup
  case "$kind" in
    binary) printf 'image\0data\n' > "$REAL_PATCH_REPO/marketing/content/home.md" ;;
    symlink) rm "$REAL_PATCH_REPO/marketing/content/home.md"; ln -s ../../marketing/src/home.ts "$REAL_PATCH_REPO/marketing/content/home.md" ;;
    submodule) "$REAL_GIT" -C "$REAL_PATCH_REPO" rm -q marketing/content/home.md; "$REAL_GIT" -C "$REAL_PATCH_REPO" update-index --add --cacheinfo "160000,$base_sha,marketing/content/home.md"; mkdir -p "$REAL_PATCH_REPO/marketing/content/home.md" ;;
    deleted) rm "$REAL_PATCH_REPO/marketing/content/home.md" ;;
    renamed) "$REAL_GIT" -C "$REAL_PATCH_REPO" mv marketing/content/home.md marketing/content/renamed.md ;;
  esac
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "$kind marketing file uses normal route" 0 'lane=normal' 1
) </dev/null &
done
unit; (
unit_init

) </dev/null &
unit; (
unit_init
unset REAL_PATCH_REPO
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Exercise the script with real commit graphs and git patch-id, not asserted IDs.
setup
export REAL_PATCH_REPO="$ucd/patch-repo"
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

# Owner copy approval survives a content neutral head move (main merged into the branch).
G() { "$REAL_GIT" -C "$REAL_PATCH_REPO" "$@"; }
approval_pid() { # sha: the owner-approve.sh fingerprint, zero context against main
  G diff -U0 "$(G merge-base refs/remotes/origin/main "$1")" "$1" | "$REAL_GIT" patch-id --stable | awk '{print $1}'
}
set_main() { G update-ref refs/heads/main "$1"; G update-ref refs/remotes/origin/main "$1"; base_sha=$1; }
approval_attest() {
  checks="Checks: PASS head=$SHA"
  comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: owner\nPhone-width screenshots in tw, en and jp.'
}
copy_setup
tr_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
printf '{\n"a":"1",\n"b":"2",\n"c":"3",\n"d":"4",\n"e":"5",\n"f":"6",\n"g":"7"\n}\n' > "$tr_file"
G add .; G commit -qm base2; set_main "$(G rev-parse HEAD)"; M0=$base_sha
G checkout -q -b pr; sed -i.bak 's/"d":"4"/"d":"four"/' "$tr_file"; rm -f "$tr_file.bak"
G add .; G commit -qm copy; A=$(G rev-parse HEAD); SHA=$A; headsha=$A
PID_A=$(approval_pid "$A")
write_approval copy "$A" +1800 mingster "$PID_A"; approval_attest
check "approved head merges" 0 'lane=normal' 1
# Another PR edits the neighbouring lines of the same file, then main is merged in.
G checkout -q fixture 2>/dev/null || G checkout -q main
G checkout -q -B mainwork "$M0"; sed -i.bak 's/"b":"2"/"b":"two"/; s/"f":"6"/"f":"six"/' "$tr_file"; rm -f "$tr_file.bak"
G add .; G commit -qm other-pr; OTHER=$(G rev-parse HEAD); set_main "$OTHER"
G checkout -q pr; G merge -q --no-edit main >/dev/null; B=$(G rev-parse HEAD); SHA=$B; headsha=$B
PR_DIFF=$(G diff "$base_sha...$B")
approval_attest
check "main merged into branch with no content change still merges" 0 'lane=normal' 1
write_approval copy "$A" +1800 mingster
check "approval without a patch id does not follow the moved head" 1 'owner copy approval'
write_approval copy "$A" -10 mingster "$PID_A"
check "expired approval refuses even when the patch id matches" 1 'owner copy approval'
write_approval copy "$A" +5000 mingster "$PID_A"
check "approval expiring beyond the ttl window refuses" 1 'owner copy approval'
write_approval copy "$A" +1800 mingster "$(G diff -U0 "$M0" "$OTHER" | "$REAL_GIT" patch-id --stable | awk '{print $1}')"
check "a different PR's patch id refuses" 1 'owner copy approval'
write_approval copy "$A" +1800 mingster "$PID_A"
sed -i.bak 's/"g":"7"/"g":"seven"/' "$tr_file"; rm -f "$tr_file.bak"
G add .; G commit -qm one-more-line; C=$(G rev-parse HEAD); SHA=$C; headsha=$C
PR_DIFF=$(G diff "$base_sha...$C"); approval_attest
check "one changed line after approval refuses" 1 'owner copy approval'
rm -f "$APPROVAL"

# Retained verdict and countersign when main was merged into the branch (real graph).
rr() { G checkout -q -B "$1" "$2"; }
rm -f "$APPROVAL"
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

# Spelled-out quantities (issue 3832 item 2): a changed number word is owner-held
# even though it has no digit, currency marker or topic word.
) </dev/null &
for surface in marketing locale; do
  while IFS='|' read -r before after; do
    if [ "$surface" = locale ]; then case "$before" in 滿一百送一|'Open one hundred') ;; *) continue ;; esac; fi
unit; (
unit_init
    copy_setup
    if [ "$surface" = marketing ]; then
      probe_file="$REAL_PATCH_REPO/marketing/content/home.md"
      printf '%s\n' "$before" > "$probe_file"
    else
      probe_file="$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
      jq -n --arg value "$before" '{greeting:$value}' > "$probe_file"
    fi
    "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
    "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm spelled-base
    base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
    "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
    if [ "$surface" = marketing ]; then
      printf '%s\n' "$after" > "$probe_file"
    else
      jq -n --arg value "$after" '{greeting:$value}' > "$probe_file"
    fi
    copy_commit
    comments+=$'\nPhone-width screenshots in tw, en and jp.'
    check "$surface spelled quantity $before to $after requires approval" 1 'owner copy approval'
) </dev/null &
  done <<'CASES'
滿一百送一|滿二百送一
一百人|二百人
百人|千人
百名様|千名様
一千円|二千円
Open one hundred|Open two hundred
Seats: Hundred|Seats: Thousand
CASES
done
unit; (
unit_init
# Unchanged number words and wording that keeps the same number words stay light.
) </dev/null &
for pair in '一起來|一起來吧' 'Welcome one and all|Welcome one and all, friends'; do
unit; (
unit_init
  copy_setup
  before=${pair%%|*}; after=${pair#*|}
  printf '%s\n' "$before" > "$REAL_PATCH_REPO/marketing/content/home.md"
  "$REAL_GIT" -C "$REAL_PATCH_REPO" add .
  "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm spelled-same-base
  base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/heads/main "$base_sha"
  printf '%s\n' "$after" > "$REAL_PATCH_REPO/marketing/content/home.md"
  copy_commit
  comments+=$'\nPhone-width screenshots in tw, en and jp.'
  check "same number words ($before) stay on the light route" 0 'lane=copy-only' 1
) </dev/null &
done
unit; (
unit_init

# Missing guard-bash.py (issue 3832 item 3): fall back to the configured namespace
# or print a clear diagnostic, and still fail closed.
) </dev/null &
unit; (
unit_init
mkdir -p "$ucd/gate2"
cp "$here/lead-merge.sh" "$ucd/gate2/lead-merge.sh"
LEAD_MERGE="$ucd/gate2/lead-merge.sh"
hooks_file="$LEAD/.claude/hooks/guard-bash.py"
mv "$hooks_file" "$hooks_file.away"
copy_setup
printf '{"greeting":"Welcome"}\n' > "$REAL_PATCH_REPO/web/src/app/i18n/locales/en/translation.json"
copy_commit
comments="Verdict: PASS head=$SHA verifier=ctx_verify author=ctx_author"$'\nCopy topics: owner\nPhone-width screenshots in tw, en and jp.'
jq 'del(.approval_namespace)' "$here/copy-only.config.json" > "$ucd/gate2/copy-only.config.json"
check "missing guard-bash.py without configured namespace prints diagnostic" 1 'no approval namespace'
jq '. + {approval_namespace:"proj"}' "$here/copy-only.config.json" > "$ucd/gate2/copy-only.config.json"
check "missing guard-bash.py with configured namespace still needs approval" 1 'owner copy approval'
write_approval copy "$SHA"
check "missing guard-bash.py falls back to configured namespace" 0 'lane=normal' 1
rm -f "$APPROVAL"
mv "$hooks_file.away" "$hooks_file"
unset LEAD_MERGE

) </dev/null &
report
