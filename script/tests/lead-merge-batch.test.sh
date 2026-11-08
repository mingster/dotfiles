#!/usr/bin/env bash
# Batch train tests for lead-merge.sh; forge and network-facing git calls are fake.
set -u
export MF_SELF_REVIEW=1
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
export HOME="$tmp/home" PATH="$tmp/bin:$PATH"
mkdir -p "$HOME/orca/workspaces/fixture/lead-x" "$tmp/bin"
export FAKE_TOP="$HOME/orca/workspaces/fixture/lead-x"
export EVENT_LOG="$tmp/events" COMMENT_DIR="$tmp/comments" MERGED_DIR="$tmp/merged"
export MAIN_TREE_FILE="$tmp/main-tree" UNKNOWN_COUNT_FILE="$tmp/unknown-count"
mkdir -p "$COMMENT_DIR" "$MERGED_DIR"

heads=(
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  cccccccccccccccccccccccccccccccccccccccc
)
base=dddddddddddddddddddddddddddddddddddddddd
BATCH_PRS_JSON=$(jq -nc --arg base "$base" --arg h1 "${heads[0]}" --arg h2 "${heads[1]}" --arg h3 "${heads[2]}" '
  {"11":{state:"OPEN",baseRefName:"main",headRefName:"feature-11",headRefOid:$h1,mergeable:"MERGEABLE",url:"https://example.invalid/pull/11",changedFiles:1,body:"## Verification\n- Passed.\n\n## Self-review\n"+$h1,comments:[],baseRefOid:$base},
   "12":{state:"OPEN",baseRefName:"main",headRefName:"feature-12",headRefOid:$h2,mergeable:"MERGEABLE",url:"https://example.invalid/pull/12",changedFiles:1,body:"## Verification\n- Passed.\n\n## Self-review\n"+$h2,comments:[],baseRefOid:$base},
   "13":{state:"OPEN",baseRefName:"main",headRefName:"feature-13",headRefOid:$h3,mergeable:"MERGEABLE",url:"https://example.invalid/pull/13",changedFiles:1,body:"## Verification\n- Passed.\n\n## Self-review\n"+$h3,comments:[],baseRefOid:$base}}')
export BATCH_PRS_JSON BASE_SHA="$base"

cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = rev-parse ] && [ "${2:-}" = --show-toplevel ]; then echo "$FAKE_TOP"; exit 0; fi
if [ "$1" = rev-parse ] && [[ "${*: -1}" == 'origin/main^{tree}' ]]; then
  [ ! -f "$MAIN_TREE_FILE" ] || { cat "$MAIN_TREE_FILE"; exit 0; }
  echo "$BASE_SHA"; exit 0
fi
if [ "$1" = rev-parse ] && [[ "${*: -1}" == *'^{tree}' ]]; then
  value=${*: -1}; echo "${value%\^\{tree\}}"; exit 0
fi
if [ "$1" = rev-parse ] && [[ "${*: -1}" == origin/main* ]]; then echo "$BASE_SHA"; exit 0; fi
case "$1" in
  cat-file|fetch) exit 0 ;;
  merge-base) echo "$BASE_SHA" ;;
  diff) [ "${2:-}" = --name-only ] && printf '%s\n' "${TRUNK_FILES:-}" || echo "" ;;
  merge-tree) printf '%040x\n' "$((16#${3:0:2} + 1))" ;;
  commit-tree)
    while [ $# -gt 0 ]; do [ "$1" = -p ] && last=$2; shift; done
    case "$last" in
      a*) echo 1111111111111111111111111111111111111111 ;;
      b*) echo 2222222222222222222222222222222222222222 ;;
      c*) echo 3333333333333333333333333333333333333333 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  api_pr=$(grep -oE 'pulls/[0-9]+' <<<"$*" | cut -d/ -f2)
  file=docs/change.md
  { [ -z "${BATCH_FILE_PR:-}" ] || [ "$BATCH_FILE_PR" = "$api_pr" ]; } && file=${BATCH_FILE:-docs/change.md}
  jq -nc --arg file "$file" '[{filename:$file}]'; exit 0
fi
cmd=$2; pr=${3:-}
case "$cmd" in
  view)
    data=$(jq -c --arg pr "$pr" '.[$pr]' <<<"$BATCH_PRS_JSON")
    if [ "${UNKNOWN_PR:-}" = "$pr" ] && [[ "$*" == *mergeable* ]]; then
      count=0; [ ! -f "$UNKNOWN_COUNT_FILE" ] || count=$(cat "$UNKNOWN_COUNT_FILE")
      if [ "$count" -lt "${UNKNOWN_READS:-0}" ]; then
        count=$((count+1)); printf '%s\n' "$count" > "$UNKNOWN_COUNT_FILE"
        data=$(jq -c '.mergeable="UNKNOWN"' <<<"$data")
      fi
    fi
    if [ -f "$COMMENT_DIR/$pr" ]; then
      data=$(jq --rawfile body "$COMMENT_DIR/$pr" '.comments += [{body:$body}]' <<<"$data")
    fi
    if [ -f "$MERGED_DIR/$pr" ]; then
      jq -c --arg pr "$pr" '.state="MERGED" | .mergeCommit={oid:("e"+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+$pr+"0000000000000000000")[:40]}' <<<"$data"
    else printf '%s\n' "$data"; fi ;;
  diff) { [ -z "${BATCH_DIFF_PR:-}" ] || [ "$BATCH_DIFF_PR" = "$pr" ]; } && printf '%s' "${BATCH_DIFF:-}"; true ;;
  comment)
    body_file=""; prev=""
    for arg in "$@"; do [ "$prev" = --body-file ] && body_file=$arg; prev=$arg; done
    cp "$body_file" "$COMMENT_DIR/$pr"; echo "comment $pr" >> "$EVENT_LOG" ;;
  merge)
    touch "$MERGED_DIR/$pr"; echo "merge $pr" >> "$EVENT_LOG"
    case "$pr" in 11) tree=1111111111111111111111111111111111111111 ;; 12) tree=2222222222222222222222222222222222222222 ;; 13) tree=3333333333333333333333333333333333333333 ;; esac
    [ "${DRIFT_AFTER_PR:-}" != "$pr" ] || tree=ffffffffffffffffffffffffffffffffffffffff
    printf '%s\n' "$tree" > "$MAIN_TREE_FILE" ;;
  list)
    if [ -n "${STACKED_PR:-}" ] && [[ "$*" == *"--base $STACKED_BASE"* ]]; then
      printf '[{"number":%s}]\n' "$STACKED_PR"
    else echo '[]'; fi ;;
  edit) echo "retarget $pr" >> "$EVENT_LOG" ;;
  *) exit 1 ;;
esac
EOF

cat > "$tmp/bin/head-checks" <<'EOF'
#!/usr/bin/env bash
head=""; heads=""; prev=""
for arg in "$@"; do
  [ "$prev" = --ref ] && head=$arg
  [ "$prev" = --train-heads ] && heads=$arg
  prev=$arg
done
echo "head-checks $head $heads" >> "$EVENT_LOG"
printf 'Checks: %s head=%s main=2222222222222222222222222222222222222222 train-heads=%s\n' "$([ -n "${FAIL_HEAD:-}" ] && [[ ",$heads," == *",$FAIL_HEAD,"* ]] && echo FAIL || echo PASS)" "$head" "$heads"
red() { printf 'Command: bun run test\n(fail) widget keeps its label\n 1 fail\nResult: exit 1; remaining checks stopped\n\nReceipt cut to fit 20000 characters. Full log: /logs/head-checks-%s.log\n' "${head:0:12}"; exit 1; }
if [ -n "${FAIL_HEAD:-}" ] && [[ ",$heads," == *",$FAIL_HEAD,"* ]]; then red; fi
if [ -n "${FAIL_EXACT_HEADS:-}" ] && [ "$heads" = "$FAIL_EXACT_HEADS" ]; then
  red
fi
EOF

cat > "$tmp/bin/cleanup" <<'EOF'
#!/usr/bin/env bash
echo "cleanup $*" >> "$EVENT_LOG"
exit "${CLEANUP_EXIT:-0}"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$EVENT_LOG"
EOF
chmod +x "$tmp/bin/"*
export LEAD_MERGE_HEAD_CHECKS="$tmp/bin/head-checks" LEAD_MERGE_CLEANUP="$tmp/bin/cleanup"

pass=0 fail=0
put_pass() { local i; for i in 0 1 2; do printf 'Checks: PASS head=%s\n' "${heads[$i]}" > "$COMMENT_DIR/$((11+i))"; done; } # entry gate: every batch PR needs Checks
reported() { grep -A3 "dropped PR #$1" <<<"$out" | grep -q "$2"; } # PR number, text in its refusal list
check() {
  name=$1; shift
  if "$@"; then echo "ok   $name"; pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi
}

: > "$EVENT_LOG"
rm -f "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
out=$(DRY_RUN=1 bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "dry run succeeds" test "$code" -eq 0
check "dry run prints one head-checks run" test "$(grep -c 'head-checks' <<<"$out")" -eq 1
check "dry run prints three merges" test "$(grep -c '\[dry-run\] merge PR' <<<"$out")" -eq 3

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
printf 'Checks: PASS head=%s\n' "${heads[0]}" > "$COMMENT_DIR/11"
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 2>&1); code=$?
check "batch of one succeeds" test "$code" -eq 0
check "batch of one is not refused for its size" test "$(grep -c 'at least two' <<<"$out")" -eq 0
check "batch of one merges as a single PR" grep -qx 'merge 11' "$EVENT_LOG"
check "batch of one builds no train" test "$(grep -c '^head-checks' "$EVENT_LOG")" -eq 0
check "batch of one prints no batch summary" test "$(grep -c 'batch complete' <<<"$out")" -eq 0

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
FAIL_HEAD=${heads[1]}; export FAIL_HEAD
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "red train still merges passing PRs" test "$code" -eq 0
check "red train names the failing PR" grep -q 'failing PR #12' <<<"$out"
check "red train does not merge the failing PR" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "red train merges both passing PRs" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
check "red train prints the failing command" grep -q 'Command: bun run test' <<<"$out"
check "red train prints the failing test line" grep -q '(fail) widget keeps its label' <<<"$out"
check "red train prints the full log path" grep -q 'Full log: /logs/head-checks-' <<<"$out"

# T33: cleanup runs once, after the last merge, and a failing cleanup never fails the batch.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; unset FAIL_HEAD; put_pass
CLEANUP_EXIT=1; export CLEANUP_EXIT
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
unset CLEANUP_EXIT
check "batch exits 0 though cleanup fails" test "$code" -eq 0
check "batch merges all three" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 3
check "a green train prints no failure excerpt" test "$(grep -c 'train checks failed' <<<"$out")" -eq 0
check "batch runs cleanup once" test "$(grep -c '^cleanup ' "$EVENT_LOG")" -eq 1
check "cleanup starts after the last merge" test "$(grep -n '^cleanup ' "$EVENT_LOG" | cut -d: -f1)" -gt "$(grep -n '^merge 13$' "$EVENT_LOG" | cut -d: -f1)"
check "the one cleanup names all three merged heads" test "$(grep '^cleanup ' "$EVENT_LOG" | grep -o -- '--head-sha' | wc -l | tr -d ' ')" -eq 3
check "every MERGED prints before the cleanup line" test "$(grep -n '^MERGED' <<<"$out" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^cleanup: starting' <<<"$out" | cut -d: -f1)"
check "a failing cleanup is reported" grep -q 'cleanup: incomplete' <<<"$out"

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; unset FAIL_HEAD; put_pass
FAIL_EXACT_HEADS=$(IFS=,; echo "${heads[*]}"); export FAIL_EXACT_HEADS
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "interaction-red train returns cleanly" test "$code" -eq 0
check "interaction-red train is reported" grep -q 'red interaction could not isolate one PR' <<<"$out"
check "interaction-red train merges nothing" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 0
check "interaction-red train prints why it failed" grep -q '(fail) widget keeps its label' <<<"$out"
unset FAIL_EXACT_HEADS

# A refused PR is dropped and reported; the rest of the batch merges.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
BATCH_FILE='.claude/hooks/x.sh'; BATCH_FILE_PR=12; export BATCH_FILE BATCH_FILE_PR
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "batch drops a PR with a protected path" test "$code" -eq 0
check "dropped protected PR is reported" reported 12 'claude/hooks'
check "dropped protected PR does not merge" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "the rest of the batch merges" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
unset BATCH_FILE BATCH_FILE_PR

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
BATCH_DIFF=$'+test.skip("case", () => {})\n'; BATCH_DIFF_PR=12; export BATCH_DIFF BATCH_DIFF_PR
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "batch drops an uncountersigned PR" test "$code" -eq 0
check "dropped uncountersigned PR is reported" reported 12 'Countersign'
check "uncountersigned PR does not merge" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "the rest of the batch merges past an uncountersigned PR" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
unset BATCH_DIFF BATCH_DIFF_PR

# Main changing to an untested tree after the first merge stops the batch before PR 12.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
export DRIFT_AFTER_PR=11
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "main drift stops the batch" test "$code" -eq 1
check "main drift reports stale train" grep -q 'main changed since batch train checks' <<<"$out"
check "main drift prevents the next merge" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 1
unset DRIFT_AFTER_PR

# Environment variables alone cannot turn a plain single-PR call into train mode.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
printf 'Checks: PASS head=%s train-heads=%s\n' \
  1111111111111111111111111111111111111111 "$(IFS=,; echo "${heads[*]}")" > "$COMMENT_DIR/11"
out=$(LEAD_MERGE_TRAIN_HEAD=1111111111111111111111111111111111111111 \
  LEAD_MERGE_TRAIN_HEADS="$(IFS=,; echo "${heads[*]}")" \
  bash "$here/lead-merge.sh" --repo example/repo --pr 11 --head "${heads[0]}" 2>&1); code=$?
check "plain PR ignores train environment" test "$code" -eq 1
check "plain PR still requires exact head checks" grep -q 'missing current-head' <<<"$out"
check "plain PR with train environment merges nothing" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 0

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
printf 'Checks: PASS head=%s\n' "${heads[0]}" > "$COMMENT_DIR/11"
export TRUNK_FILES=docs/change.md
out=$(LEAD_MERGE_TRAIN_HEAD=1111111111111111111111111111111111111111 \
  LEAD_MERGE_TRAIN_HEADS="$(IFS=,; echo "${heads[*]}")" \
  bash "$here/lead-merge.sh" --repo example/repo --pr 11 --head "${heads[0]}" 2>&1); code=$?
check "plain PR with train environment runs trunk drift check" test "$code" -eq 1
check "plain PR reports overlapping trunk drift" grep -q 'trunk changed docs/change.md' <<<"$out"
unset TRUNK_FILES

# GitHub can transiently report UNKNOWN after the previous batch item merges.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
export UNKNOWN_PR=12 UNKNOWN_READS=2
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "UNKNOWN mergeability is retried" test "$code" -eq 0
check "UNKNOWN retry waits briefly" test "$(grep -c '^sleep ' "$EVENT_LOG")" -eq 2
check "batch merges after UNKNOWN clears" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 3
unset UNKNOWN_PR UNKNOWN_READS

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; put_pass
export UNKNOWN_PR=11 UNKNOWN_READS=9
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "persistent UNKNOWN drops only that PR" test "$code" -eq 0
check "persistent UNKNOWN is reported as not MERGEABLE" reported 11 'not MERGEABLE'
check "persistent UNKNOWN retries three times" test "$(grep -c '^sleep ' "$EVENT_LOG")" -eq 3
check "persistent UNKNOWN merges the other two" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
unset UNKNOWN_PR UNKNOWN_READS

# A stacked PR is retargeted before cleanup can delete the merged branch.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; unset FAIL_HEAD
export STACKED_PR=99 STACKED_BASE=feature-11
printf 'Checks: PASS head=%s\n' "${heads[0]}" > "$COMMENT_DIR/11"
bash "$here/lead-merge.sh" --repo example/repo --pr 11 --head "${heads[0]}" >/dev/null 2>&1
retarget_line=$(grep -n '^retarget 99$' "$EVENT_LOG" | cut -d: -f1)
cleanup_line=$(grep -n '^cleanup ' "$EVENT_LOG" | cut -d: -f1)
check "retarget happens before cleanup" test -n "$retarget_line" -a "$retarget_line" -lt "$cleanup_line"

# Cases on the shared fixture: real git, stateful fake gh and orca.
# fx_checks_pass <pr>...: the entry gate needs a Checks PASS at the head of every PR that should enter a train.
fx_checks_pass() {
  local n h
  for n in "$@"; do
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    jq --arg b "Checks: PASS head=$h" '.comments += [{body:$b, author:"fixture", edited:false, minimized:false}]' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  done
}
fx_suite() {
  # shellcheck source=lib/merge-fixture.sh
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}   # the git stub above must not shadow real git
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca"
  export MF_TOPLEVEL="$HOME/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export FX_HC_LOG="$MF_DIR/hc.log" EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
echo "head-checks $heads" >> "$FX_HC_LOG"
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
# FX_BREAK_PR: the PR body loses its Verification heading after preflight, so the gate drops it.
if [ -n "${FX_BREAK_PR:-}" ]; then
  f="$MF_GH_DIR/pr-$FX_BREAK_PR.json"; jq '.body="Verification:\n- Edited."' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
fi
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks" LEAD_MERGE_CLEANUP="$tmp/bin/cleanup"
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' h12 out code

  # T2: a PR that preflight refuses never takes part in a head-checks train.
  mf_pr_add 11 f11 "$ok" docs/a11.md; mf_pr_add 12 f12 $'Verification:\n- Passed.' docs/a12.md; mf_pr_add 13 f13 "$ok" docs/a13.md
  fx_checks_pass 11 12 13
  h12=$(jq -r .headRefOid "$MF_GH_DIR/pr-12.json")
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   T2 batch with a refused PR still exits 0" || echo "FAIL T2 exit $code: $out"
  grep -A3 'dropped PR #12' <<<"$out" | grep -q 'missing ## Verification heading' && echo "ok   T2 refusal is reported with its reason" || echo "FAIL T2 report: $out"
  ! grep -q "$h12" "$FX_HC_LOG" && echo "ok   T2 head-checks never saw the refused head" || echo "FAIL T2 train held refused head"
  [ "$(grep -c . "$FX_HC_LOG")" -eq 1 ] && echo "ok   T2 one head-checks run for the survivors" || echo "FAIL T2 run count"
  # T26: the survivors merge.
  [ "$(jq -r .state "$MF_GH_DIR/pr-11.json")$(jq -r .state "$MF_GH_DIR/pr-13.json")" = MERGEDMERGED ] && echo "ok   T26 the rest of the batch merges" || echo "FAIL T26 merge states"
  [ "$(jq -r .state "$MF_GH_DIR/pr-12.json")" = OPEN ] && echo "ok   T26 the refused PR stays open" || echo "FAIL T26 refused PR merged"

  # T27: a PR the gate drops after train checks takes every later train-mate with it, so main only
  # ever receives a prefix of the train that head-checks tested.
  local n states
  for n in 14 15 16; do mf_pr_add "$n" "f$n" "$ok" "docs/a$n.md"; done; fx_checks_pass 14 15 16
  out=$(FX_BREAK_PR=14 bash "$here/lead-merge.sh" --repo example/repo --batch 14 15 16 2>&1); code=$?
  states=$(for n in 14 15 16; do jq -r .state "$MF_GH_DIR/pr-$n.json"; done | tr '\n' ' ')
  [ "$states" = "OPEN OPEN OPEN " ] && echo "ok   T27 nothing merges after the first train PR is dropped" || echo "FAIL T27 states $states: $out"
  grep -q 'PR #15: .*untested without PR #14' <<<"$out" && echo "ok   T27 later train-mates are reported" || echo "FAIL T27 report: $out"
  for n in 17 18 19; do mf_pr_add "$n" "f$n" "$ok" "docs/a$n.md"; done; fx_checks_pass 17 18 19
  out=$(FX_BREAK_PR=19 bash "$here/lead-merge.sh" --repo example/repo --batch 17 18 19 2>&1)
  states=$(for n in 17 18 19; do jq -r .state "$MF_GH_DIR/pr-$n.json"; done | tr '\n' ' ')
  [ "$states" = "MERGED MERGED OPEN " ] && echo "ok   T27 the tested prefix before the dropped PR merges" || echo "FAIL T27 prefix states $states: $out"
}

# T24: a 13 PR train with a huge log posts every receipt through a gh that rejects bodies over 65536.
fx_receipts() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export HEAD_CHECKS_LOG_DIR="$MF_DIR/logs"; mkdir -p "$HEAD_CHECKS_LOG_DIR"
  export EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"
  printf '#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n' > "$MF_DIR/reader"; chmod +x "$MF_DIR/reader"
  export HEAVY_GATE_READER="$MF_DIR/reader" HEAVY_GATE_POLL_SECONDS=0.02
  unset HEAD_CHECKS_SLOTS
  mkdir -p "$MF_REPO/.agents"
  printf '%s\n' "head -c 200000 /dev/zero | tr '\\\\0' x; echo" > "$MF_REPO/.agents/head-checks.conf"
  "$MF_REAL_GIT" -C "$MF_REPO" add .agents && "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m conf && "$MF_REAL_GIT" -C "$MF_REPO" push -q origin main && "$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
  cat > "$MF_BIN/real-head-checks" <<EOS
#!/usr/bin/env bash
args=(); skip=0
for a in "\$@"; do
  if [ \$skip = 1 ]; then args+=("$MF_REPO"); skip=0
  else args+=("\$a"); [ "\$a" = --repo ] && skip=1; fi
done
exec env -u MF_TOPLEVEL bash "$here/head-checks.sh" "\${args[@]}"
EOS
  chmod +x "$MF_BIN/real-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/real-head-checks" LEAD_MERGE_CLEANUP="$tmp/bin/cleanup"
  cd "$MF_REPO" || return 1
  local n prs=() out code merged=0 body=$'## Verification\n- Passed.'
  for n in $(seq 21 33); do mf_pr_add "$n" "r$n" "$body" "docs/r$n.md"; prs+=("$n"); done; fx_checks_pass "${prs[@]}"
  out=$(bash "$here/lead-merge.sh" --repo example/repo --dry-run --batch "${prs[@]}" 2>&1)
  grep -n 'receipt' <<<"$out" | head -1 | grep -q 'receipt .*65536' && echo "ok   T24 dry run prints the receipt size" || echo "FAIL T24 dry run receipt line: $out"
  [ "$(grep -n 'receipt' <<<"$out" | head -1 | cut -d: -f1)" -lt "$(grep -n 'head-checks' <<<"$out" | head -1 | cut -d: -f1)" ] && echo "ok   T24 receipt size comes before the head-checks line" || echo "FAIL T24 order"
  out=$(mf_run_limited 280 bash "$here/lead-merge.sh" --repo example/repo --batch "${prs[@]}" 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   T24 13 PR batch with a large log exits 0" || echo "FAIL T24 exit $code: $(tail -5 <<<"$out")"
  for n in "${prs[@]}"; do [ "$(jq -r .state "$MF_GH_DIR/pr-$n.json")" != MERGED ] || merged=$((merged+1)); done
  [ "$merged" -eq 13 ] && echo "ok   T24 every PR merges" || echo "FAIL T24 merged $merged of 13: $(grep -B3 "gate dropped PR #21" <<<"$out" | head -12)"
  local size; size=$(jq -r '.comments[-1].body | length' "$MF_GH_DIR/pr-21.json" 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] && [ "$size" -le 65536 ] && echo "ok   T24 receipt is posted under the limit ($size)" || echo "FAIL T24 receipt size $size"
  jq -r '.comments[-1].body' "$MF_GH_DIR/pr-21.json" | grep -q "Full log: $HEAD_CHECKS_LOG_DIR/" && echo "ok   T24 receipt names the full log" || echo "FAIL T24 no log name"
}

# T13 and T34: one merge run per repo, and a batch that finds main moved merges nothing.
fx_lock() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"; cd "$MF_REPO" || return 1
  export LEAD_MERGE_CLEANUP=true
  local ok=$'## Verification\n- Passed.' out code n lock holder dead
  lock="$MF_REPO/.git/lead-merge.lock"
  mf_barrier_make hc
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
if [ -n "${FX_BLOCK:-}" ]; then : > "$MF_DIR/barrier-hc.waiting"; read -r _ < "$MF_DIR/barrier-hc"; fi
if [ -n "${FX_PUSH_MAIN:-}" ]; then
  w=$(mktemp -d); "$MF_REAL_GIT" clone -q "$MF_ORIGIN" "$w"; echo outside > "$w/outside.txt"
  "$MF_REAL_GIT" -C "$w" add outside.txt; "$MF_REAL_GIT" -C "$w" commit -q -m outside; "$MF_REAL_GIT" -C "$w" push -q origin HEAD:main; rm -rf "$w"
fi
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks"
  for n in 11 12 13 14 15; do mf_pr_add "$n" "k$n" "$ok" "docs/k$n.md"; done; fx_checks_pass 11 12 13 14  # PR 15 has no Checks: it stays a preflight refusal

  # T13: a batch blocked in head-checks holds the lock; a single merge waits, then refuses naming the holder.
  FX_BLOCK=1 mf_run_limited 60 bash "$here/lead-merge.sh" --repo o/r --batch 11 12 > "$MF_DIR/batch.out" 2>&1 &
  local bp=$!
  mf_barrier_wait_until_blocked hc 20 && echo "ok   T13 batch reaches head-checks" || echo "FAIL T13 batch never reached head-checks"
  holder=$(cat "$lock/pid" 2>/dev/null)
  [ -n "$holder" ] && echo "ok   T13 batch holds a lock dir with its pid" || echo "FAIL T13 no lock dir with a pid"
  out=$(LEAD_MERGE_LOCK_WAIT_SECONDS=2 bash "$here/lead-merge.sh" --repo o/r --pr 13 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")" 2>&1); code=$?
  [ "$code" -ne 0 ] && echo "ok   T13 single merge refuses while the batch holds the lock" || echo "FAIL T13 single exit $code"
  grep -q "holder.*$holder\|pid $holder" <<<"$out" && echo "ok   T13 refusal names the holder pid" || echo "FAIL T13 holder not named: $out"
  mf_run_limited 10 mf_barrier_release hc  # bounded: an unread fifo would block the write forever
  wait "$bp"; code=$?
  [ "$code" -eq 0 ] && [ "$(jq -r .state "$MF_GH_DIR/pr-11.json")$(jq -r .state "$MF_GH_DIR/pr-12.json")" = MERGEDMERGED ] \
    && echo "ok   T13 after the fifo opens the batch merges every PR" || echo "FAIL T13 batch exit $code: $(tail -5 "$MF_DIR/batch.out")"
  [ ! -e "$lock" ] && echo "ok   T13 lock is released after the batch" || echo "FAIL T13 lock left behind"

  # T13: a stale takeover is serialized; while another waiter is mid-takeover nobody else clears the lock.
  dead=$(bash -c 'echo $$'); mkdir "$lock" "$lock.takeover"; echo "$dead" > "$lock/pid"; date +%s > "$lock/started"
  out=$(LEAD_MERGE_LOCK_WAIT_SECONDS=2 bash "$here/lead-merge.sh" --repo o/r --pr 13 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")" 2>&1); code=$?
  [ "$code" -ne 0 ] && [ "$(cat "$lock/pid" 2>/dev/null)" = "$dead" ] \
    && echo "ok   T13 no second takeover while one is in progress" || echo "FAIL T13 took over during another takeover (exit $code): $out"
  rm -rf "$lock" "$lock.takeover"

  # T13: a lock dir whose pid is gone is taken over, and released again on a refusal exit.
  dead=$(bash -c 'echo $$'); mkdir "$lock"; echo "$dead" > "$lock/pid"; date +%s > "$lock/started"
  out=$(LEAD_MERGE_LOCK_WAIT_SECONDS=2 bash "$here/lead-merge.sh" --repo o/r --pr 15 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-15.json")" 2>&1)
  grep -qi 'stale' <<<"$out" && echo "ok   T13 dead pid lock is taken over" || echo "FAIL T13 no takeover: $out"
  grep -q 'missing current-head' <<<"$out" && echo "ok   T13 run past the lock reaches preflight" || echo "FAIL T13 did not reach preflight: $out"
  [ ! -e "$lock" ] && echo "ok   T13 lock is released on a refusal exit" || echo "FAIL T13 lock left after refusal"

  # T34: an outside push moves origin/main during the train run: nothing merges.
  out=$(FX_PUSH_MAIN=1 bash "$here/lead-merge.sh" --repo o/r --batch 13 14 2>&1); code=$?
  [ "$code" -ne 0 ] && echo "ok   T34 exit is non-zero" || echo "FAIL T34 exit $code"
  grep -q 'main moved' <<<"$out" && echo "ok   T34 prints main moved" || echo "FAIL T34 message: $out"
  [ "$(jq -r .state "$MF_GH_DIR/pr-13.json")$(jq -r .state "$MF_GH_DIR/pr-14.json")" = OPENOPEN ] && echo "ok   T34 0 merges" || echo "FAIL T34 merged something"
  [ ! -e "$lock" ] && echo "ok   T34 lock is released" || echo "FAIL T34 lock left behind"
}

# T20: an edited PASS drops its PR in preflight, named by comment URL; the rest of the batch merges.
fx_verdict() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export FX_HC_LOG="$MF_DIR/hc.log" EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
echo "head-checks $heads" >> "$FX_HC_LOG"
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks" LEAD_MERGE_CLEANUP="$tmp/bin/cleanup"
  mf_orca_add_run run_a; mf_orca_add_worker run_a ctx_verify completed /w/v; mf_orca_add_worker run_a ctx_author completed /w/a
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' n h out code f
  for n in 51 52 53; do mf_pr_add "$n" "v$n" "$ok" "script/v$n.sh"; done; fx_checks_pass 51 52 53
  for n in 51 52 53; do
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    f="$MF_GH_DIR/pr-$n.json"
    jq --arg v "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" --arg u "https://example.test/pull/$n#c1" --argjson e "$([ "$n" = 52 ] && echo true || echo false)" \
      '.comments += [{body:$v, url:$u, edited:$e, minimized:false}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-52.json")
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 51 52 53 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   T20 batch with an edited PASS exits 0" || echo "FAIL T20 exit $code: $out"
  grep -A4 'dropped PR #52' <<<"$out" | grep -q 'ignored Verdict https://example.test/pull/52#c1: .*edited or minimized' && echo "ok   T20 the dropped PR names the edited Verdict by URL" || echo "FAIL T20 report: $out"
  ! grep -q "$h" "$FX_HC_LOG" && echo "ok   T20 head-checks never saw the dropped head" || echo "FAIL T20 train held the dropped head"
  [ "$(jq -r .state "$MF_GH_DIR/pr-51.json")$(jq -r .state "$MF_GH_DIR/pr-53.json")" = MERGEDMERGED ] && echo "ok   T20 the rest of the batch merges" || echo "FAIL T20 merge states: $out"
  [ "$(jq -r .state "$MF_GH_DIR/pr-52.json")" = OPEN ] && echo "ok   T20 the dropped PR stays open" || echo "FAIL T20 dropped PR merged"
}


# T15: a batch of 3 PRs that each need a Verdict reads the dispatch inventory once, parent and children together.
fx_dispatches() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export FX_HC_LOG="$MF_DIR/hc.log" EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
echo "head-checks $heads" >> "$FX_HC_LOG"
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks" LEAD_MERGE_CLEANUP="$tmp/bin/cleanup"
  mf_orca_add_run run_1; mf_orca_add_worker run_1 ctx_verify dispatched "$MF_DIR/wt"; mf_orca_add_worker run_1 ctx_author dispatched "$MF_DIR/wt-author"
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' n h out code runs merged=0
  for n in 41 42 43; do
    mf_pr_add "$n" "v$n" "$ok" "src/v$n.sh"; fx_checks_pass "$n"
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    jq --arg b "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" '.comments += [{body:$b, author:"fixture", edited:false, minimized:false}]' \
      "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  done
  : > "$MF_ORCA_LOG"
  out=$(mf_run_limited 120 bash "$here/lead-merge.sh" --repo example/repo --batch 41 42 43 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   T15 batch with Verdicts exits 0" || echo "FAIL T15 exit $code: $out"
  for n in 41 42 43; do [ "$(jq -r .state "$MF_GH_DIR/pr-$n.json")" != MERGED ] || merged=$((merged+1)); done
  [ "$merged" -eq 3 ] && echo "ok   T15 every PR merges" || echo "FAIL T15 merged $merged of 3: $out"
  runs=$(grep -c 'run-list' "$MF_ORCA_LOG")
  [ "$runs" -eq 1 ] && echo "ok   T15 run-list called once across parent and children" || echo "FAIL T15 run-list called $runs times"
  # Helper: a PR whose Verdict names verifier $2.
  fx_verdict_pr() {
    local n=$1 who=$2 h
    mf_pr_add "$n" "v$n" "$ok" "src/v$n.sh"
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    jq --arg b "Verdict: PASS head=$h verifier=$who author=ctx_author" --arg c "Checks: PASS head=$h" '.comments += [{body:$c, author:"fixture", edited:false, minimized:false},{body:$b, author:"fixture", edited:false, minimized:false}]' \
      "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  }
  fx_verdict_pr 44 ctx_verify; fx_verdict_pr 45 ctx_verify
  # A batch child with a missing inventory file falls back to one live read, not to a refusal.
  : > "$MF_ORCA_LOG"
  out=$(LEAD_MERGE_BATCH_CHILD=1 LEAD_MERGE_LOCK_HELD=1 LEAD_MERGE_DISPATCHES_FILE="$MF_DIR/missing" mf_run_limited 120 bash "$here/lead-merge.sh" --repo example/repo --pr 44 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-44.json")" 2>&1); code=$?
  [ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out" && echo "ok   T15 batch child with a missing inventory file falls back to a live read" || echo "FAIL T15 child fallback exit $code: $out"
  [ "$(grep -c 'run-list' "$MF_ORCA_LOG")" -eq 1 ] && echo "ok   T15 child fallback reads once" || echo "FAIL T15 child fallback reads"
  # A plain run ignores an inherited inventory file, even one that would validate the Verdict.
  printf 'ctx_verify\n' > "$MF_DIR/stray"
  : > "$MF_ORCA_LOG"
  out=$(LEAD_MERGE_DISPATCHES_FILE="$MF_DIR/stray" mf_run_limited 120 bash "$here/lead-merge.sh" --repo example/repo --pr 45 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-45.json")" 2>&1); code=$?
  [ "$code" -eq 0 ] && grep -q '^MERGED' <<<"$out" && echo "ok   T15 plain run with a stray export merges" || echo "FAIL T15 stray exit $code: $out"
  [ "$(grep -c 'run-list' "$MF_ORCA_LOG")" -eq 1 ] && echo "ok   T15 plain run ignores an inherited inventory file" || echo "FAIL T15 plain run used the stray file"
  # The cache is replaced by mv, never truncated in place, and holds whole ids.
  fx_verdict_pr 49 ctx_verify
  : > "$MF_DIR/cache"; before=$(ls -i "$MF_DIR/cache" | awk '{print $1}')
  out=$(LEAD_MERGE_BATCH_CHILD=1 LEAD_MERGE_LOCK_HELD=1 LEAD_MERGE_DISPATCHES_FILE="$MF_DIR/cache" mf_run_limited 120 bash "$here/lead-merge.sh" --repo example/repo --pr 49 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-49.json")" 2>&1); code=$?
  after=$(ls -i "$MF_DIR/cache" | awk '{print $1}')
  [ "$before" != "$after" ] && echo "ok   T15 cache is written by temp file and mv" || echo "FAIL T15 cache rewritten in place"
  grep -Fxq ctx_verify "$MF_DIR/cache" && [ "$(ls "$MF_DIR" | grep -c '^cache\.')" -eq 0 ] && echo "ok   T15 cache holds the whole id and no temp file is left" || echo "FAIL T15 cache content: $(cat "$MF_DIR/cache")"
  # Once the cache is filled, a later child still refuses an unknown verifier.
  fx_verdict_pr 46 ctx_verify; fx_verdict_pr 47 ctx_ghost; fx_verdict_pr 48 ctx_verify
  : > "$MF_ORCA_LOG"
  out=$(mf_run_limited 120 bash "$here/lead-merge.sh" --repo example/repo --batch 46 47 48 2>&1); code=$?
  [ "$(jq -r .state "$MF_GH_DIR/pr-47.json")" = OPEN ] && echo "ok   T15 unknown verifier refused from the filled cache" || echo "FAIL T15 unknown verifier merged: $out"
  [ "$(jq -r .state "$MF_GH_DIR/pr-46.json")$(jq -r .state "$MF_GH_DIR/pr-48.json")" = MERGEDMERGED ] && echo "ok   T15 known verifiers around it merge" || echo "FAIL T15 neighbours: $out"
  [ "$(grep -c 'run-list' "$MF_ORCA_LOG")" -eq 1 ] && echo "ok   T15 refusal batch reads the inventory once" || echo "FAIL T15 refusal batch reads"
}


# #497: a PR enters a train only with Checks PASS at its head, or carried across a clean merge of main.
fx_gate() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export FX_HC_LOG="$MF_DIR/hc.log" EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"; : > "$FX_HC_LOG"
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
echo "head-checks $heads" >> "$FX_HC_LOG"
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks" LEAD_MERGE_CLEANUP=true
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' reason='no Checks: PASS at the current head; run head-checks before the train' out code h h0 w
  # comment <pr> <body>
  gate_comment() { jq --arg b "$2" '.comments += [{body:$b, author:"fixture", edited:false, minimized:false}]' "$MF_GH_DIR/pr-$1.json" > "$MF_GH_DIR/pr-$1.tmp" && mv "$MF_GH_DIR/pr-$1.tmp" "$MF_GH_DIR/pr-$1.json"; }
  gate_pass() { gate_comment "$1" "Checks: PASS head=$(jq -r .headRefOid "$MF_GH_DIR/pr-$1.json")"; }
  gate_state() { jq -r .state "$MF_GH_DIR/pr-$1.json"; }
  # gate_advance <pr> [merge]: add a commit to the PR branch (or merge origin/main into it) and move the PR head.
  gate_advance() {
    local b; b=$(jq -r .headRefName "$MF_GH_DIR/pr-$1.json")
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
    if [ "${2:-}" = merge ]; then "$MF_REAL_GIT" -C "$MF_REPO" merge -q --no-ff -m "merge main" origin/main
    else echo more > "$MF_REPO/more-$1.txt"; "$MF_REAL_GIT" -C "$MF_REPO" add . && "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m more; fi
    "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
    h=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
    # An authored commit needs a new self-review; a merge of main carries the old one.
    jq --arg h "$h" --arg keep "${2:-}" '.headRefOid as $old | (if $keep == "merge" then . else .body |= sub($old; $h) end) | .headRefOid = $h' "$MF_GH_DIR/pr-$1.json" > "$MF_GH_DIR/pr-$1.tmp" && mv "$MF_GH_DIR/pr-$1.tmp" "$MF_GH_DIR/pr-$1.json"
  }

  # Criterion 1: no Checks comment on PR 12.
  for n in 11 12 13; do mf_pr_add "$n" "g$n" "$ok" "docs/g$n.md"; done
  gate_pass 11; gate_pass 13
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-12.json")
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   R3 batch with an unchecked PR exits 0" || echo "FAIL R3 exit $code: $out"
  grep -A3 'dropped PR #12' <<<"$out" | grep -qF "$reason" && echo "ok   R3 unchecked PR is dropped with the reason" || echo "FAIL R3 report: $out"
  ! grep -q "$h" "$FX_HC_LOG" && echo "ok   R3 head-checks never saw the unchecked head" || echo "FAIL R3 train held the unchecked head"
  [ "$(grep -c . "$FX_HC_LOG")" -eq 1 ] && echo "ok   R3 one head-checks run" || echo "FAIL R3 run count $(grep -c . "$FX_HC_LOG")"
  [ "$(gate_state 11)$(gate_state 13)$(gate_state 12)" = MERGEDMERGEDOPEN ] && echo "ok   R3 the checked PRs merge, PR 12 stays open" || echo "FAIL R3 states"

  # Criterion 2: a FAIL at the head after an older PASS.
  : > "$FX_HC_LOG"
  for n in 21 22 23; do mf_pr_add "$n" "g$n" "$ok" "docs/g$n.md"; done
  gate_pass 21; gate_pass 23; gate_pass 22; gate_advance 22
  gate_comment 22 "Checks: FAIL head=$(jq -r .headRefOid "$MF_GH_DIR/pr-22.json")"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-22.json")
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 21 22 23 2>&1); code=$?
  grep -A3 'dropped PR #22' <<<"$out" | grep -qF "$reason" && echo "ok   R3 a Checks FAIL at the head is dropped" || echo "FAIL R3 fail report: $out"
  ! grep -q "$h" "$FX_HC_LOG" && echo "ok   R3 head-checks never saw the failed head" || echo "FAIL R3 train held the failed head"
  [ "$(gate_state 21)$(gate_state 23)$(gate_state 22)" = MERGEDMERGEDOPEN ] && echo "ok   R3 the rest merge after a FAIL drop" || echo "FAIL R3 fail states"

  # Criterion 3: a PASS on an older head and only a clean merge of main since.
  : > "$FX_HC_LOG"
  mf_pr_add 32 g32 "$ok" docs/g32.md; gate_pass 32; h0=$(jq -r .headRefOid "$MF_GH_DIR/pr-32.json")
  w=$(mktemp -d); "$MF_REAL_GIT" clone -q "$MF_ORIGIN" "$w"; echo up > "$w/up.txt"; "$MF_REAL_GIT" -C "$w" add up.txt
  "$MF_REAL_GIT" -C "$w" commit -q -m up; "$MF_REAL_GIT" -C "$w" push -q origin HEAD:main; rm -rf "$w"
  "$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin; "$MF_REAL_GIT" -C "$MF_REPO" merge -q --ff-only origin/main
  gate_advance 32 merge
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-32.json")
  mf_pr_add 31 g31 "$ok" docs/g31.md; mf_pr_add 33 g33 "$ok" docs/g33.md; gate_pass 31; gate_pass 33
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 31 32 33 2>&1); code=$?
  [ "$h" != "$h0" ] && grep -q "$h" <<<"$(cat "$FX_HC_LOG" "$MF_GH_DIR/pr-32.json")" && echo "ok   R3 a PASS carried across a merge of main enters the train" || echo "FAIL R3 carry: $out"
  [ "$(gate_state 31)$(gate_state 32)$(gate_state 33)" = MERGEDMERGEDMERGED ] && echo "ok   R3 carried PR merges with the others in one run" || echo "FAIL R3 carry states: $out"
  [ "$(grep -c . "$FX_HC_LOG")" -eq 1 ] && echo "ok   R3 carry batch is one head-checks run" || echo "FAIL R3 carry run count"
}


# #499: every run that held the lock appends one line to lead-merge.log in the git common dir on release.
fx_log() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"; cd "$MF_REPO" || return 1
  export LEAD_MERGE_CLEANUP=true
  local ok=$'## Verification\n- Passed.' out code n log line bp
  log="$MF_REPO/.git/lead-merge.log"
  mf_barrier_make hc
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
if [ -n "${FX_BLOCK:-}" ]; then : > "$MF_DIR/barrier-hc.waiting"; read -r _ < "$MF_DIR/barrier-hc"; fi
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  chmod +x "$MF_BIN/fake-head-checks"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks"
  for n in 61 62 63 64 65 66; do mf_pr_add "$n" "l$n" "$ok" "docs/l$n.md"; done; fx_checks_pass 61 62 63 64 66

  out=$(bash "$here/lead-merge.sh" --repo o/r --batch 61 62 63 2>&1); code=$?
  line=$(tail -1 "$log" 2>/dev/null)
  [ "$(grep -c . "$log" 2>/dev/null)" -eq 1 ] && echo "ok   #499 a batch run appends one log line" || echo "FAIL #499 log lines: $(cat "$log" 2>&1): $out"
  grep -Eq '^start=[0-9T:Z-]+ end=[0-9T:Z-]+ hold_seconds=[0-9]+ prs=61,62,63 head_checks_runs=1 outcome=ok$' <<<"$line" && echo "ok   #499 the line holds start, end, hold seconds, PRs, run count and outcome" || echo "FAIL #499 line: $line"

  out=$(bash "$here/lead-merge.sh" --repo o/r --pr 65 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-65.json")" 2>&1); code=$?
  line=$(tail -1 "$log")
  [ "$(grep -c . "$log")" -eq 2 ] && grep -Eq 'prs=65 head_checks_runs=0 outcome=refused$' <<<"$line" && echo "ok   #499 a refused run still writes a line" || echo "FAIL #499 refused line: $line"

  FX_BLOCK=1 bash "$here/lead-merge.sh" --repo o/r --batch 64 66 > "$MF_DIR/kill.out" 2>&1 &
  bp=$!
  mf_barrier_wait_until_blocked hc 20 || echo "FAIL #499 run never reached head-checks"
  pkill -TERM -P "$bp"; kill -TERM "$bp"
  wait "$bp" 2>/dev/null
  line=$(tail -1 "$log")
  [ "$(grep -c . "$log")" -eq 3 ] && grep -Eq 'prs=64,66 head_checks_runs=1 outcome=killed$' <<<"$line" && echo "ok   #499 a killed run still writes a line" || echo "FAIL #499 killed line: $line"
  [ ! -e "$MF_REPO/.git/lead-merge.lock" ] && echo "ok   #499 the lock is gone after the log line" || echo "FAIL #499 lock left"
}


# #564: a configured host runs the real head-checks through remote-heavy.sh and ssh. The ssh here is a fake remote:
# it logs what was sent and answers with a framed receipt chosen by FX_REMOTE.
fx_remote() {
  . "$here/tests/lib/merge-fixture.sh"
  PATH=${PATH#"$tmp/bin:"}
  mf_setup; trap mf_teardown EXIT
  export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
  mkdir -p "$MF_TOPLEVEL"
  export FX_HC_LOG="$MF_DIR/hc.log" FX_SSH_LOG="$MF_DIR/ssh.log" EVENT_LOG="$MF_DIR/events"; : > "$EVENT_LOG"
  cat > "$MF_BIN/fake-head-checks" <<'EOS'
#!/usr/bin/env bash
echo "local head-checks ran" >> "$FX_HC_LOG"
ref="" heads="" prev=""
for a in "$@"; do [ "$prev" = --ref ] && ref=$a; [ "$prev" = --train-heads ] && heads=$a; prev=$a; done
printf 'Checks: PASS head=%s train-heads=%s\n' "$ref" "$heads"
EOS
  cat > "$MF_BIN/ssh" <<'EOS'
#!/usr/bin/env bash
# Stand in for remote-heavy.sh's ssh call: host, bash, -c, <script>, remote-heavy, then eight base64 words.
host=$1; shift 5
b() { printf '%s' "$1" | base64 -d; }
sha=$(b "$2"); cmd=$(b "$6"); tag=$(b "$8")
mem=$(b "$9"); mem=${mem#m}
cat > /dev/null
eval "set -- $cmd"   # bash -c <script> _ <ref> <base> <train-heads>
ref=$5 heads=${7:-}
echo "ssh host=$host sent=$sha ref=$ref heads=$heads memory=$mem" >> "$FX_SSH_LOG"
case "${FX_REMOTE:-pass}" in
  sshfail) echo "ssh: connect to host failed" >&2; exit 255 ;;
  noreceipt) printf '@@begin-%s@@\n@@end-%s-0@@\n' "$tag" "$tag"; exit 0 ;;
esac
kind=PASS status=0; reported=$ref reported_heads=$heads
if [ -n "${FX_FAIL_HEAD:-}" ] && [[ ",$heads," == *",$FX_FAIL_HEAD,"* || "$ref" = "$FX_FAIL_HEAD" ]]; then kind=FAIL status=1; fi
[ "${FX_REMOTE:-}" != wrongsha ] || reported=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
[ "${FX_REMOTE:-}" != wrongheads ] || reported_heads=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
printf '@@begin-%s@@\n' "$tag"
printf 'Checks: %s head=%s%s\n\n' "$kind" "$reported" "${reported_heads:+ train-heads=$reported_heads}"
[ "$kind" = PASS ] || printf 'Command: bun run test\n(fail) remote widget\nResult: exit 1; remaining checks stopped\n'
printf '\n@@end-%s-%s@@\n' "$tag" "$status"
EOS
  chmod +x "$MF_BIN/fake-head-checks" "$MF_BIN/ssh"
  export LEAD_MERGE_HEAD_CHECKS="$MF_BIN/fake-head-checks" LEAD_MERGE_CLEANUP=true
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' out code n h states ref
  for n in 71 72 73 74 75 76 77 78; do mf_pr_add "$n" "q$n" "$ok" "docs/q$n.md"; done
  fx_checks_pass 71 72 73 74 75 76 77 78
  local on='LEAD_MERGE_REMOTE_HOST=chk-host LEAD_MERGE_REMOTE_REPO_DIR=/srv/repo LEAD_MERGE_REMOTE_DIR=/srv/work'
  state() { for n in "$@"; do jq -r .state "$MF_GH_DIR/pr-$n.json"; done | tr '\n' ' '; }
  comments() { jq -r '[.comments[].body | select(startswith("Checks: ") and contains("train-heads="))] | length' "$MF_GH_DIR/pr-$1.json"; }

  # Setting off: the local head-checks runs and ssh is never called.
  : > "$FX_HC_LOG"; : > "$FX_SSH_LOG"
  out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 71 72 2>&1); code=$?
  [ "$code" -eq 0 ] && [ "$(grep -c . "$FX_HC_LOG")" -eq 1 ] && [ ! -s "$FX_SSH_LOG" ] && [ "$(state 71 72)" = "MERGED MERGED " ] \
    && echo "ok   #564 setting off keeps the local run and never calls ssh" || echo "FAIL #564 off: exit $code: $out"

  # Setting on, green: one remote run for the batch, the receipt on every PR, the local override unused.
  mf_pr_add 73 q73 "$ok" docs/q73.md; mf_pr_add 74 q74 "$ok" docs/q74.md; mf_pr_add 75 q75 "$ok" docs/q75.md; fx_checks_pass 73 74 75
  : > "$FX_HC_LOG"; : > "$FX_SSH_LOG"
  out=$(env $on bash "$here/lead-merge.sh" --repo example/repo --batch 73 74 75 2>&1); code=$?
  [ "$code" -eq 0 ] && [ "$(grep -c . "$FX_SSH_LOG")" -eq 1 ] && [ ! -s "$FX_HC_LOG" ] \
    && echo "ok   #564 batch runs one head check on the named host, not locally" || echo "FAIL #564 on: exit $code ssh=$(cat "$FX_SSH_LOG") local=$(cat "$FX_HC_LOG"): $out"
  grep -q 'host=chk-host sent=\([0-9a-f]\{40\}\) ref=\1 ' "$FX_SSH_LOG" && echo "ok   #564 the exact train commit is what ships" || echo "FAIL #564 sent: $(cat "$FX_SSH_LOG")"
  grep -q ' memory=9216$' "$FX_SSH_LOG" && echo "ok   #568 remote head checks declare 9216 MiB by default" || echo "FAIL #568 remote memory: $(cat "$FX_SSH_LOG")"
  mf_pr_add 79 q79 "$ok" docs/q79.md; mf_pr_add 80 q80 "$ok" docs/q80.md; fx_checks_pass 79 80
  : > "$FX_SSH_LOG"
  env $on HEAD_CHECKS_MEMORY_MB=4096 bash "$here/lead-merge.sh" --repo example/repo --batch 79 80 >/dev/null 2>&1
  grep -q ' memory=4096$' "$FX_SSH_LOG" && echo "ok   #568 HEAD_CHECKS_MEMORY_MB overrides the remote declaration" || echo "FAIL #568 remote override: $(cat "$FX_SSH_LOG")"
  [ "$(comments 73)$(comments 74)$(comments 75)" = 111 ] && [ "$(state 73 74 75)" = "MERGED MERGED MERGED " ] \
    && echo "ok   #564 the receipt is posted on each PR and the group merges" || echo "FAIL #564 comments/states: $(state 73 74 75)"

  # Wrong commit or wrong train list in the receipt: refused, nothing posted, nothing merged.
  for mode in wrongsha wrongheads; do
    mf_pr_add 76 q76 "$ok" docs/q76.md; mf_pr_add 77 q77 "$ok" docs/q77.md; fx_checks_pass 76 77
    out=$(env $on FX_REMOTE=$mode bash "$here/lead-merge.sh" --repo example/repo --batch 76 77 2>&1); code=$?
    [ "$code" -ne 0 ] && [ "$(state 76 77)" = "OPEN OPEN " ] && [ "$(comments 76)$(comments 77)" = 00 ] && grep -qi 'receipt.*differs\|different commit\|does not match' <<<"$out" \
      && echo "ok   #564 $mode receipt is refused" || echo "FAIL #564 $mode: exit $code states $(state 76 77): $out"
  done
  # ssh failure and an empty remote answer fail closed with a plain error.
  for mode in sshfail noreceipt; do
    out=$(env $on FX_REMOTE=$mode bash "$here/lead-merge.sh" --repo example/repo --batch 76 77 2>&1); code=$?
    [ "$code" -ne 0 ] && [ "$(state 76 77)" = "OPEN OPEN " ] && [ "$(comments 76)$(comments 77)" = 00 ] && grep -qi 'remote head-checks' <<<"$out" \
      && echo "ok   #564 $mode fails closed" || echo "FAIL #564 $mode: exit $code: $out"
  done
  # A red train still bisects and prints the failing step; the green PR merges.
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-77.json")
  : > "$FX_SSH_LOG"
  out=$(env $on FX_FAIL_HEAD="$h" bash "$here/lead-merge.sh" --repo example/repo --batch 76 77 2>&1); code=$?
  [ "$(state 76 77)" = "MERGED OPEN " ] && [ "$(grep -c . "$FX_SSH_LOG")" -ge 3 ] && grep -q 'Result: exit 1' <<<"$out" && grep -q 'batch failing PR #77' <<<"$out" \
    && echo "ok   #564 a red remote train bisects and prints the failing step" || echo "FAIL #564 red: exit $code states $(state 76 77) ssh=$(grep -c . "$FX_SSH_LOG"): $out"

  # Single path: no receipt at the head, setting on. Green posts the receipt and merges.
  : > "$FX_SSH_LOG"
  out=$(env $on bash "$here/lead-merge.sh" --repo example/repo --pr 78 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-78.json")" 2>&1); code=$?
  [ "$code" -eq 0 ] && [ "$(state 78)" = "MERGED " ] && [ "$(grep -c . "$FX_SSH_LOG")" -eq 0 ] \
    && echo "ok   #564 single path with a receipt at the head runs nothing remote" || echo "FAIL #564 single with receipt: $out"
  for n in 81 82 83; do mf_pr_add "$n" "q$n" "$ok" "docs/q$n.md"; done
  : > "$FX_SSH_LOG"
  out=$(env $on bash "$here/lead-merge.sh" --repo example/repo --pr 81 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-81.json")" 2>&1); code=$?
  [ "$code" -eq 0 ] && [ "$(state 81)" = "MERGED " ] && [ "$(grep -c . "$FX_SSH_LOG")" -eq 1 ] && jq -e '.comments | map(.body) | any(startswith("Checks: PASS head="))' "$MF_GH_DIR/pr-81.json" >/dev/null \
    && echo "ok   #564 single path runs the head check on the host, posts the receipt and merges" || echo "FAIL #564 single green: exit $code: $out"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-82.json")
  out=$(env $on FX_FAIL_HEAD="$h" bash "$here/lead-merge.sh" --repo example/repo --pr 82 --head "$h" 2>&1); code=$?
  [ "$code" -ne 0 ] && [ "$(state 82)" = "OPEN " ] && grep -q 'Result: exit 1' <<<"$out" \
    && echo "ok   #564 single path red prints the failing step and does not merge" || echo "FAIL #564 single red: exit $code: $out"
  out=$(env $on FX_REMOTE=wrongsha bash "$here/lead-merge.sh" --repo example/repo --pr 83 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-83.json")" 2>&1); code=$?
  [ "$code" -ne 0 ] && [ "$(state 83)" = "OPEN " ] && echo "ok   #564 single path refuses a receipt for another commit" || echo "FAIL #564 single wrongsha: $out"
  out=$(env $on FX_REMOTE=sshfail bash "$here/lead-merge.sh" --repo example/repo --pr 83 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-83.json")" 2>&1); code=$?
  [ "$code" -ne 0 ] && [ "$(state 83)" = "OPEN " ] && echo "ok   #564 single path fails closed on ssh failure" || echo "FAIL #564 single sshfail: $out"

  # The host comes from the untracked local overlay, and the committed example names none.
  [ "$(jq -r '.head_checks_remote.host // ""' "$here/lead-merge.config.example.json")" = "" ] && echo "ok   #564 the committed config names no host" || echo "FAIL #564 committed host"
  cp -R "$here" "$MF_DIR/script-copy"
  printf '{"head_checks_remote":{"host":"overlay-host","repo_dir":"/srv/repo","dir":"/srv/work"}}\n' > "$MF_DIR/script-copy/lead-merge.local.json"
  mf_pr_add 84 q84 "$ok" docs/q84.md; mf_pr_add 85 q85 "$ok" docs/q85.md; fx_checks_pass 84 85
  : > "$FX_SSH_LOG"
  out=$(bash "$MF_DIR/script-copy/lead-merge.sh" --repo example/repo --batch 84 85 2>&1); code=$?
  [ "$code" -eq 0 ] && grep -q 'host=overlay-host' "$FX_SSH_LOG" && echo "ok   #564 the host comes from lead-merge.local.json" || echo "FAIL #564 overlay: exit $code: $out"

  # A host set for one repo must not take another repo's checks.
  printf '{"head_checks_remote":{"repo":"other/repo","host":"overlay-host","repo_dir":"/srv/repo","dir":"/srv/work"}}\n' > "$MF_DIR/script-copy/lead-merge.local.json"
  mf_pr_add 86 q86 "$ok" docs/q86.md; mf_pr_add 87 q87 "$ok" docs/q87.md; fx_checks_pass 86 87
  : > "$FX_SSH_LOG"
  out=$(bash "$MF_DIR/script-copy/lead-merge.sh" --repo example/repo --batch 86 87 2>&1); code=$?
  ! grep -q 'host=overlay-host' "$FX_SSH_LOG" && echo "ok   the overlay host skips a repo it does not name" || echo "FAIL overlay repo filter: exit $code: $out"
  printf '{"head_checks_remote":{"repo":"example/repo","host":"overlay-host","repo_dir":"/srv/repo","dir":"/srv/work"}}\n' > "$MF_DIR/script-copy/lead-merge.local.json"
  mf_pr_add 88 q88 "$ok" docs/q88.md; mf_pr_add 89 q89 "$ok" docs/q89.md; fx_checks_pass 88 89
  : > "$FX_SSH_LOG"
  out=$(bash "$MF_DIR/script-copy/lead-merge.sh" --repo example/repo --batch 88 89 2>&1); code=$?
  grep -q 'host=overlay-host' "$FX_SSH_LOG" && echo "ok   the overlay host serves the repo it names" || echo "FAIL overlay named repo: exit $code: $out"
}

fx_out=$( (fx_suite) 2>&1; (fx_receipts) 2>&1; (fx_lock) 2>&1; (fx_verdict) 2>&1; (fx_dispatches) 2>&1; (fx_gate) 2>&1; (fx_log) 2>&1; (fx_remote) 2>&1 )
printf '%s\n' "$fx_out"
pass=$((pass+$(grep -c '^ok ' <<<"$fx_out"))); fail=$((fail+$(grep -c '^FAIL' <<<"$fx_out")))
echo "passed $pass, failed $fail"
test "$fail" -eq 0
