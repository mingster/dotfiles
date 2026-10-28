#!/usr/bin/env bash
# --dry-run on the single PR path: gates run, nothing merges, retargets or cleans up.
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
# Every gh call is logged so a test can assert what never ran.
mv "$tmp/bin/gh" "$tmp/bin/gh.real"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
exec "$(dirname "$0")/gh.real" "$@"
EOS
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log"
cat > "$tmp/cleanup.sh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG.cleanup"
EOS
export LEAD_MERGE_CLEANUP="$tmp/cleanup.sh"

pass=0; fail=0
run() { # name expected_exit output_regex forbidden_gh_regex args...
  local name=$1 want=$2 re=$3 forbid=$4; shift 4
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls" "$GH_LOG" "$GH_LOG.cleanup"
  mkjson
  out=$(bash "$here/lead-merge.sh" --repo o/r "$@" 2>&1); code=$?
  bad=""
  [ "$code" = "$want" ] || bad="exit $code"
  grep -qE "$re" <<<"$out" || bad="$bad output"
  [ -z "$forbid" ] || ! grep -qE "$forbid" "$GH_LOG" 2>/dev/null || bad="$bad forbidden gh call"
  [ ! -f "$GH_LOG.cleanup" ] || [ -z "$forbid" ] || bad="$bad cleanup ran"
  if [ -z "$bad" ]; then echo "ok   $name"; pass=$((pass+1))
  else printf 'FAIL %s (%s)\n%s\n' "$name" "$bad" "$out"; fail=$((fail+1)); fi
}
NOMERGE='pr (merge|edit)'

setup; run "dry-run --pr passes gates, no merge" 0 "^\[dry-run\] would merge PR 7 head=$SHA\$" "$NOMERGE" --pr 7 --head "$SHA" --dry-run
setup; run "dry-run --pr output has no MERGED line" 0 '^\[dry-run\]' "$NOMERGE" --pr 7 --head "$SHA" --dry-run
grep -q '^MERGED' <<<"$out" && { echo "FAIL dry-run printed MERGED"; fail=$((fail+1)); } || { echo "ok   dry-run prints no MERGED"; pass=$((pass+1)); }
setup; run "dry-run --batch with one PR passes gates, no merge" 0 "^\[dry-run\] would merge PR 7 head=$SHA\$" "$NOMERGE" --batch 7 --dry-run
setup; mergeable=CONFLICTING; run "dry-run failing gate refuses like a real run" 1 'not MERGEABLE' "" --pr 7 --head "$SHA" --dry-run
setup; mergeable=CONFLICTING; run "real run same failing gate" 1 'not MERGEABLE' "" --pr 7 --head "$SHA"
setup; run "real run still merges" 0 '^MERGED ' "" --pr 7 --head "$SHA"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
