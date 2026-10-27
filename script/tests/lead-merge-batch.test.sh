#!/usr/bin/env bash
# Batch train tests for lead-merge.sh; forge and network-facing git calls are fake.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
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
  {"11":{state:"OPEN",baseRefName:"main",headRefName:"feature-11",headRefOid:$h1,mergeable:"MERGEABLE",url:"https://example.invalid/pull/11",changedFiles:1,body:"## Verification\n- Passed.",comments:[],baseRefOid:$base},
   "12":{state:"OPEN",baseRefName:"main",headRefName:"feature-12",headRefOid:$h2,mergeable:"MERGEABLE",url:"https://example.invalid/pull/12",changedFiles:1,body:"## Verification\n- Passed.",comments:[],baseRefOid:$base},
   "13":{state:"OPEN",baseRefName:"main",headRefName:"feature-13",headRefOid:$h3,mergeable:"MERGEABLE",url:"https://example.invalid/pull/13",changedFiles:1,body:"## Verification\n- Passed.",comments:[],baseRefOid:$base}}')
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
printf 'Checks: %s head=%s train-heads=%s\n' "$([ -n "${FAIL_HEAD:-}" ] && [[ ",$heads," == *",$FAIL_HEAD,"* ]] && echo FAIL || echo PASS)" "$head" "$heads"
if [ -n "${FAIL_HEAD:-}" ] && [[ ",$heads," == *",$FAIL_HEAD,"* ]]; then exit 1; fi
if [ -n "${FAIL_EXACT_HEADS:-}" ] && [ "$heads" = "$FAIL_EXACT_HEADS" ]; then
  exit 1
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
reported() { grep -A3 "dropped PR #$1" <<<"$out" | grep -q "$2"; } # PR number, text in its refusal list
check() {
  name=$1; shift
  if "$@"; then echo "ok   $name"; pass=$((pass+1)); else echo "FAIL $name"; fail=$((fail+1)); fi
}

: > "$EVENT_LOG"
rm -f "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
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

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
FAIL_HEAD=${heads[1]}; export FAIL_HEAD
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "red train still merges passing PRs" test "$code" -eq 0
check "red train names the failing PR" grep -q 'failing PR #12' <<<"$out"
check "red train does not merge the failing PR" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "red train merges both passing PRs" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2

# T33: cleanup runs once, after the last merge, and a failing cleanup never fails the batch.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; unset FAIL_HEAD
CLEANUP_EXIT=1; export CLEANUP_EXIT
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
unset CLEANUP_EXIT
check "batch exits 0 though cleanup fails" test "$code" -eq 0
check "batch merges all three" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 3
check "batch runs cleanup once" test "$(grep -c '^cleanup ' "$EVENT_LOG")" -eq 1
check "cleanup starts after the last merge" test "$(grep -n '^cleanup ' "$EVENT_LOG" | cut -d: -f1)" -gt "$(grep -n '^merge 13$' "$EVENT_LOG" | cut -d: -f1)"
check "the one cleanup names all three merged heads" test "$(grep '^cleanup ' "$EVENT_LOG" | grep -o -- '--head-sha' | wc -l | tr -d ' ')" -eq 3
check "every MERGED prints before the cleanup line" test "$(grep -n '^MERGED' <<<"$out" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^cleanup: starting' <<<"$out" | cut -d: -f1)"
check "a failing cleanup is reported" grep -q 'cleanup: incomplete' <<<"$out"

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"; unset FAIL_HEAD
FAIL_EXACT_HEADS=$(IFS=,; echo "${heads[*]}"); export FAIL_EXACT_HEADS
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "interaction-red train returns cleanly" test "$code" -eq 0
check "interaction-red train is reported" grep -q 'red interaction could not isolate one PR' <<<"$out"
check "interaction-red train merges nothing" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 0
unset FAIL_EXACT_HEADS

# A refused PR is dropped and reported; the rest of the batch merges.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
BATCH_FILE='.codex/rules'; BATCH_FILE_PR=12; export BATCH_FILE BATCH_FILE_PR
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "batch drops a PR with a protected path" test "$code" -eq 0
check "dropped protected PR is reported" reported 12 'codex'
check "dropped protected PR does not merge" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "the rest of the batch merges" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
unset BATCH_FILE BATCH_FILE_PR

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
BATCH_DIFF=$'+test.skip("case", () => {})\n'; BATCH_DIFF_PR=12; export BATCH_DIFF BATCH_DIFF_PR
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "batch drops an uncountersigned PR" test "$code" -eq 0
check "dropped uncountersigned PR is reported" reported 12 'Countersign'
check "uncountersigned PR does not merge" test "$(grep -c '^merge 12$' "$EVENT_LOG")" -eq 0
check "the rest of the batch merges past an uncountersigned PR" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 2
unset BATCH_DIFF BATCH_DIFF_PR

# Main changing to an untested tree after the first merge stops the batch before PR 12.
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
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
: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
export UNKNOWN_PR=12 UNKNOWN_READS=2
out=$(bash "$here/lead-merge.sh" --repo example/repo --batch 11 12 13 2>&1); code=$?
check "UNKNOWN mergeability is retried" test "$code" -eq 0
check "UNKNOWN retry waits briefly" test "$(grep -c '^sleep ' "$EVENT_LOG")" -eq 2
check "batch merges after UNKNOWN clears" test "$(grep -c '^merge ' "$EVENT_LOG")" -eq 3
unset UNKNOWN_PR UNKNOWN_READS

: > "$EVENT_LOG"; rm -f "$COMMENT_DIR"/* "$MERGED_DIR"/* "$MAIN_TREE_FILE" "$UNKNOWN_COUNT_FILE"
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
  for n in 14 15 16; do mf_pr_add "$n" "f$n" "$ok" "docs/a$n.md"; done
  out=$(FX_BREAK_PR=14 bash "$here/lead-merge.sh" --repo example/repo --batch 14 15 16 2>&1); code=$?
  states=$(for n in 14 15 16; do jq -r .state "$MF_GH_DIR/pr-$n.json"; done | tr '\n' ' ')
  [ "$states" = "OPEN OPEN OPEN " ] && echo "ok   T27 nothing merges after the first train PR is dropped" || echo "FAIL T27 states $states: $out"
  grep -q 'PR #15: .*untested without PR #14' <<<"$out" && echo "ok   T27 later train-mates are reported" || echo "FAIL T27 report: $out"
  for n in 17 18 19; do mf_pr_add "$n" "f$n" "$ok" "docs/a$n.md"; done
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
  for n in $(seq 21 33); do mf_pr_add "$n" "r$n" "$body" "docs/r$n.md"; prs+=("$n"); done
  out=$(bash "$here/lead-merge.sh" --repo example/repo --dry-run --batch "${prs[@]}" 2>&1)
  grep -n 'receipt' <<<"$out" | head -1 | grep -q 'receipt .*65536' && echo "ok   T24 dry run prints the receipt size" || echo "FAIL T24 dry run receipt line: $out"
  [ "$(grep -n 'receipt' <<<"$out" | head -1 | cut -d: -f1)" -lt "$(grep -n 'head-checks' <<<"$out" | head -1 | cut -d: -f1)" ] && echo "ok   T24 receipt size comes before the head-checks line" || echo "FAIL T24 order"
  out=$(mf_run_limited 280 bash "$here/lead-merge.sh" --repo example/repo --batch "${prs[@]}" 2>&1); code=$?
  [ "$code" -eq 0 ] && echo "ok   T24 13 PR batch with a large log exits 0" || echo "FAIL T24 exit $code: $(tail -5 <<<"$out")"
  for n in "${prs[@]}"; do [ "$(jq -r .state "$MF_GH_DIR/pr-$n.json")" != MERGED ] || merged=$((merged+1)); done
  [ "$merged" -eq 13 ] && echo "ok   T24 every PR merges" || echo "FAIL T24 merged $merged of 13: $(grep -B3 "gate dropped PR #21" <<<"$out" | head -12)"
  local size; size=$(jq -r '.comments[0].body | length' "$MF_GH_DIR/pr-21.json" 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] && [ "$size" -le 65536 ] && echo "ok   T24 receipt is posted under the limit ($size)" || echo "FAIL T24 receipt size $size"
  jq -r '.comments[0].body' "$MF_GH_DIR/pr-21.json" | grep -q "Full log: $HEAD_CHECKS_LOG_DIR/" && echo "ok   T24 receipt names the full log" || echo "FAIL T24 no log name"
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
  for n in 11 12 13 14; do mf_pr_add "$n" "k$n" "$ok" "docs/k$n.md"; done

  # T13: a batch blocked in head-checks holds the lock; a single merge waits, then refuses naming the holder.
  FX_BLOCK=1 mf_run_limited 60 bash "$here/lead-merge.sh" --repo o/r --batch 11 12 > "$MF_DIR/batch.out" 2>&1 &
  local bp=$!
  mf_barrier_wait_until_blocked hc 20 && echo "ok   T13 batch reaches head-checks" || echo "FAIL T13 batch never reached head-checks"
  holder=$(cat "$lock/pid" 2>/dev/null)
  [ -n "$holder" ] && echo "ok   T13 batch holds a lock dir with its pid" || echo "FAIL T13 no lock dir with a pid"
  out=$(LEAD_MERGE_LOCK_WAIT_SECONDS=2 bash "$here/lead-merge.sh" --repo o/r --pr 13 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")" 2>&1); code=$?
  [ "$code" -ne 0 ] && echo "ok   T13 single merge refuses while the batch holds the lock" || echo "FAIL T13 single exit $code"
  grep -q "holder.*$holder\|pid $holder" <<<"$out" && echo "ok   T13 refusal names the holder pid" || echo "FAIL T13 holder not named: $out"
  mf_barrier_release hc
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
  out=$(LEAD_MERGE_LOCK_WAIT_SECONDS=2 bash "$here/lead-merge.sh" --repo o/r --pr 13 --head "$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")" 2>&1)
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
  for n in 51 52 53; do mf_pr_add "$n" "v$n" "$ok" "script/v$n.sh"; done
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
  mf_orca_add_run run_1; mf_orca_add_worker run_1 ctx_verify dispatched "$MF_DIR/wt"
  cd "$MF_REPO" || return 1
  local ok=$'## Verification\n- Passed.' n h out code runs merged=0
  for n in 41 42 43; do
    mf_pr_add "$n" "v$n" "$ok" "src/v$n.sh"
    h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
    jq --arg b "Verdict: PASS head=$h verifier=ctx_verify author=unknown" '.comments += [{body:$b, author:"fixture", edited:false, minimized:false}]' \
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
    jq --arg b "Verdict: PASS head=$h verifier=$who author=unknown" --arg c "Checks: PASS head=$h" '.comments += [{body:$c, author:"fixture", edited:false, minimized:false},{body:$b, author:"fixture", edited:false, minimized:false}]' \
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


fx_out=$( (fx_suite) 2>&1; (fx_receipts) 2>&1; (fx_lock) 2>&1; (fx_verdict) 2>&1; (fx_dispatches) 2>&1 )
printf '%s\n' "$fx_out"
pass=$((pass+$(grep -c '^ok ' <<<"$fx_out"))); fail=$((fail+$(grep -c '^FAIL' <<<"$fx_out")))
echo "passed $pass, failed $fail"
test "$fail" -eq 0
