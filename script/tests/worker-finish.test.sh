#!/usr/bin/env bash
# Tests for worker-finish.sh: head-checks gate, native worker-release receipts, worktree retention.
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# shellcheck source=lib/merge-fixture.sh
. "$here/lib/merge-fixture.sh"
mf_setup
trap mf_teardown EXIT
tmp=$MF_DIR
G() { "$MF_REAL_GIT" -C "$MF_REPO" "$@"; }
export HEAD_CHECKS_LOG="$tmp/checks.log" PANE_LOG="$tmp/pane.log" WORKER_PANE_CLOSE="$tmp/pane-close"
export RELEASE_FIXTURE_DIR="$tmp/release-fixtures" WORKER_FINISH_ARCHIVE_DIR="$tmp/archive"
mkdir -p "$RELEASE_FIXTURE_DIR" "$WORKER_FINISH_ARCHIVE_DIR" "$tmp/bin452"
cat > "$tmp/bin452/git" <<EOS
#!/usr/bin/env bash
if [ -n "\${WORKER_FINISH_TEST_MERGE_BASE_RC:-}" ] && [ "\$1" = -C ] && [ "\$3" = merge-base ] && [ "\$4" = --is-ancestor ]; then
  exit "\${WORKER_FINISH_TEST_MERGE_BASE_RC}"
fi
if [ -n "\${WORKER_FINISH_TEST_LS_FILES_RC:-}" ] && [ "\$1" = -C ] && [ "\$3" = ls-files ] && [ "\${4:-}" = -u ]; then
  exit "\${WORKER_FINISH_TEST_LS_FILES_RC}"
fi
if [ -n "\${WORKER_FINISH_TEST_DIFF_U_RC:-}" ] && [ "\$1" = -C ] && [ "\$3" = diff ] && [[ "\$*" = *"--diff-filter=U"* ]]; then
  exit "\${WORKER_FINISH_TEST_DIFF_U_RC}"
fi
exec "$MF_BIN/git" "\$@"
EOS
chmod +x "$tmp/bin452/git"
export PATH="$tmp/bin452:$PATH"

cat > "$tmp/checks-pass" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$HEAD_CHECKS_LOG"; echo "head-checks: PASS"; exit 0
EOS
cat > "$tmp/checks-fail" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$HEAD_CHECKS_LOG"; echo "head-checks: FAIL"; exit 1
EOS
cat > "$tmp/pane-close" <<'EOS'
#!/usr/bin/env bash
echo "pane-close $*" >> "$PANE_LOG"
[ "$#" -gt 0 ] || { while :; do sleep 1; done; }
EOS
chmod +x "$tmp/checks-pass" "$tmp/checks-fail" "$tmp/pane-close"

# Wrap the merge-fixture fake orca with JSON worker-show/release fixtures.
cat > "$tmp/orca-wrap" <<'EOS'
#!/usr/bin/env bash
echo "orca $*" >> "$MF_ORCA_LOG"
args=("$@")
[ "${args[0]}" = orca ] && args=("${args[@]:1}")
case "${args[0]} ${args[1]:-}" in
  "orchestration worker-show")
    id=""; i=2; while [ "$i" -lt "${#args[@]}" ]; do
      [ "${args[$i]}" = --dispatch ] && id=${args[$((i+1))]}
      i=$((i + 1))
    done
    f="$WORKER_SHOW_FIXTURE_DIR/show-$id.json"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    printf '{"ok":true,"result":{"dispatch":{"status":"completed","taskId":"task_expected"}}}\n'
    ;;
  "orchestration worker-release")
    id=""; i=2; while [ "$i" -lt "${#args[@]}" ]; do
      [ "${args[$i]}" = --dispatch ] && id=${args[$((i+1))]}
      i=$((i + 1))
    done
    f="$RELEASE_FIXTURE_DIR/$id.json"
    if [ -f "$f" ]; then
      jq -r '.body' "$f"
      exit "$(jq -r '.cliExit // 0' "$f")"
    fi
    exec "$MF_BIN/orca" "$@"
    ;;
  *) exec "$MF_BIN/orca" "${args[@]}" ;;
esac
EOS
chmod +x "$tmp/orca-wrap"
export WORKER_SHOW_FIXTURE_DIR="$tmp/show-fixtures"
mkdir -p "$WORKER_SHOW_FIXTURE_DIR"
export ORCA_CLI_COMMAND="$tmp/orca-wrap"

release_fixture() {
  local id=$1 body=$2 cli_exit=${3:-0}
  jq -n --arg body "$body" --argjson cliExit "$cli_exit" '{body:$body, cliExit:$cliExit}' > "$RELEASE_FIXTURE_DIR/$id.json"
}

default_released() {
  release_fixture "$1" "{\"ok\":true,\"result\":{\"dispatchId\":\"$1\",\"state\":\"released\"}}" 0
}

push_wt_head_to_main() {
  local b
  b=$(git -C "$1" rev-parse --abbrev-ref HEAD)
  git -C "$1" push -q origin "${b}:main"
  G fetch -q origin
}

# A worktree with one commit that is not in origin/main, so head-checks apply.
newwt() { G worktree add -q "$tmp/$1" -b "$1" origin/main; git -C "$tmp/$1" commit -q --allow-empty -m "work $1"; }
run() { (cd "$MF_REPO" && mf_run_limited 20 "$@") >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }
reset() { : > "$MF_ORCA_LOG"; : > "$HEAD_CHECKS_LOG"; : > "$PANE_LOG"; rm -f "$RELEASE_FIXTURE_DIR"/*.json "$WORKER_SHOW_FIXTURE_DIR"/*.json; }
released_log() { grep -c "worker-release --dispatch $1" "$MF_ORCA_LOG"; }

# 1. failing checks refuse, touch nothing
newwt w1; reset; mf_orca_add_worker run1 d1 dispatched "$tmp/w1"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "failing checks exit 1"
grep -q "worker-finish: head-checks failed, refusing worker_done" "$tmp/err" && ok || bad "failing checks message"
[ -d "$tmp/w1" ] && ok || bad "failing checks keep worktree"
[ "$(released_log d1)" = 0 ] && ok || bad "failing checks leave dispatch untouched"
grep -q -- "--repo .*w1 --ref HEAD --base origin/main" "$HEAD_CHECKS_LOG" && ok || bad "checks called with repo, ref, base"

# 2. passing checks proceed when release reports released and HEAD is in main
reset; default_released d1
push_wt_head_to_main "$tmp/w1"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "passing checks exit 0"
[ ! -d "$tmp/w1" ] && ok || bad "passing checks remove worktree"
[ "$(released_log d1)" = 1 ] && ok || bad "passing checks release dispatch"
grep -q "removed worktree" "$tmp/out" && ok || bad "success prints removed worktree"
! grep -q "pane-close" "$PANE_LOG" && ok || bad "legacy pane close helper not invoked"

# 3. skip flag needs a reason, prints it, skips the checks
newwt w2; reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip without reason exits 2"
[ -d "$tmp/w2" ] && ok || bad "skip without reason keeps worktree"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks ""
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip with empty reason exits 2"
reset; default_released d2
push_wt_head_to_main "$tmp/w2"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks "docs only" --dispatch d2
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "skip with reason exits 0"
grep -q "docs only" "$tmp/out" "$tmp/err" && ok || bad "skip prints the reason"
[ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "skip does not run checks"
[ ! -d "$tmp/w2" ] && ok || bad "skip with release removes worktree"

# 4. DRY_RUN prints, runs nothing
newwt w3; reset
DRY_RUN=1 HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w3" --dispatch d3
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "dry run exit 0"
grep -q "\[dry-run\].*checks-fail" "$tmp/out" && ok || bad "dry run prints the checks command"
[ -d "$tmp/w3" ] && [ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "dry run executes nothing"

# 5. missing head-checks script refuses, touches nothing
newwt w4; reset; mf_orca_add_worker run1 d4 dispatched "$tmp/w4"
HEAD_CHECKS="$tmp/does-not-exist" run bash "$here/../worker-finish.sh" --worktree "$tmp/w4" --dispatch d4
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "missing checks exit 1"
grep -q "worker-finish: head-checks failed, refusing worker_done" "$tmp/err" && ok || bad "missing checks message"
[ -d "$tmp/w4" ] && ok || bad "missing checks keep worktree"
[ "$(released_log d4)" = 0 ] && ok || bad "missing checks leave dispatch untouched"

# 6. post-merge: a head already in origin/main skips checks and removes after release
G worktree add -q "$tmp/w5" -b w5 origin/main
git -C "$tmp/w5" commit -q --allow-empty -m work
git -C "$tmp/w5" push -q origin w5:main
reset; default_released d5
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w5" --dispatch d5
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "merged head exits 0"
grep -q "skipping head-checks, HEAD is already in origin/main" "$tmp/out" && ok || bad "merged head prints one skip line"
[ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "merged head does not run checks"
[ ! -d "$tmp/w5" ] && ok || bad "merged head removes worktree"
mf_pr_add 6 w6
G worktree add -q "$tmp/w6" w6
reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w6" --dispatch d6
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "unmerged head with open PR still runs failing checks"
[ -s "$HEAD_CHECKS_LOG" ] && [ -d "$tmp/w6" ] && ok || bad "unmerged head runs checks and keeps worktree"
jq '.state = "MERGED"' "$MF_GH_DIR/pr-6.json" > "$MF_GH_DIR/pr-6.json.tmp" && mv "$MF_GH_DIR/pr-6.json.tmp" "$MF_GH_DIR/pr-6.json"
reset; default_released d6
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w6" --dispatch d6
[ "$(cat "$tmp/rc")" = 0 ] && [ ! -d "$tmp/w6" ] && ok || bad "merged PR removes worktree when head proven"
grep -q "skipping head-checks, its PR is already merged" "$tmp/out" && ok || bad "merged PR prints one skip line"
[ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "merged PR does not run checks"

# 7. no dispatch ids refuses cleanup (no pane sweep, no worktree removal)
newwt w7; reset
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w7"
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "no dispatch ids exit 1"
[ -d "$tmp/w7" ] && ok || bad "no dispatch ids keep worktree"
[ ! -s "$PANE_LOG" ] && ok || bad "no dispatch ids: pane close helper not called"

# 8. inventory dispatch id is released; worktree removed on released receipt
newwt w8; reset; mf_orca_add_worker run1 d8 dispatched "$tmp/w8"; default_released d8
push_wt_head_to_main "$tmp/w8"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w8"
[ "$(cat "$tmp/rc")" = 0 ] && [ "$(released_log d8)" = 1 ] && [ ! -d "$tmp/w8" ] && ok || bad "inventory dispatch released and worktree removed"

# 9. #442-shaped exit-0 retained keeps worktree and does not claim removal
newwt w442; reset
release_fixture ctx_f3d582b77bfc '{"ok":true,"result":{"dispatchId":"ctx_f3d582b77bfc","state":"retained","reason":"user_takeover","processAction":"none","archive":null}}' 0
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w442" --dispatch ctx_f3d582b77bfc
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "retained release exit 0"
[ -d "$tmp/w442" ] && ok || bad "retained keeps worktree"
grep -q "worktree kept" "$tmp/out" "$tmp/err" && ok || bad "retained reports worktree kept"
! grep -q "removed worktree" "$tmp/out" && ok || bad "retained must not claim removal"
[ -f "$WORKER_FINISH_ARCHIVE_DIR/release-ctx_f3d582b77bfc.json" ] && ok || bad "retained archives release json"

# 10. already_released is idempotent and allows worktree removal when HEAD is in main
newwt w10; reset
release_fixture d10 '{"ok":true,"result":{"dispatchId":"d10","state":"already_released"}}' 0
push_wt_head_to_main "$tmp/w10"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w10" --dispatch d10
[ "$(cat "$tmp/rc")" = 0 ] && [ ! -d "$tmp/w10" ] && ok || bad "already_released removes worktree"

# 11. malformed release response fails closed
newwt w11; reset
release_fixture d11 'not-json' 0
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w11" --dispatch d11
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w11" ] && ok || bad "malformed release keeps worktree and exits 1"

# 12. release_unknown fails closed
newwt w12; reset
release_fixture d12 '{"ok":true,"result":{"dispatchId":"d12","state":"release_unknown"}}' 1
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w12" --dispatch d12
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w12" ] && ok || bad "release_unknown keeps worktree"

# 13. unsettled dispatch refuses before release
newwt w13; reset; default_released d13
printf '{"ok":true,"result":{"dispatch":{"status":"dispatched"}}}\n' > "$WORKER_SHOW_FIXTURE_DIR/show-d13.json"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w13" --dispatch d13
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w13" ] && [ "$(released_log d13)" = 0 ] && ok || bad "unsettled dispatch refuses release"

# 14. task id mismatch refuses
newwt w14; reset; default_released d14
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w14" --dispatch d14 --task-id task_wrong
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w14" ] && ok || bad "task id mismatch refuses"

# 15. released-shaped JSON with nonzero CLI exit fails closed
newwt w15; reset
release_fixture d15 '{"ok":true,"result":{"dispatchId":"d15","state":"released"}}' 1
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w15" --dispatch d15
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w15" ] && ok || bad "nonzero exit with released state keeps worktree"

# 16. wrong dispatch id in release response fails closed
newwt w16; reset
release_fixture d16 '{"ok":true,"result":{"dispatchId":"d_other","state":"released"}}' 0
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w16" --dispatch d16
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w16" ] && ok || bad "wrong dispatch id in release keeps worktree"

# 17. ok:false with exit 0 fails closed
newwt w17; reset
release_fixture d17 '{"ok":false,"error":{"code":"dispatch_not_found"}}' 0
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w17" --dispatch d17
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w17" ] && ok || bad "ok false release keeps worktree"

# 18. dirty worktree survives successful released receipt
newwt w18; reset; default_released d18
echo dirty > "$tmp/w18/DONT_REMOVE"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w18" --dispatch d18
[ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w18" ] && ok || bad "dirty worktree kept after release"
grep -q "dirty or unmerged worktree kept" "$tmp/out" "$tmp/err" && ok || bad "dirty worktree reports kept"
! grep -q "removed worktree" "$tmp/out" && ok || bad "dirty worktree must not be removed"

# 19. archive writes release receipt when archive dir set
newwt w19; reset
release_fixture d19 '{"ok":true,"result":{"dispatchId":"d19","state":"released"}}' 0
push_wt_head_to_main "$tmp/w19"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w19" --dispatch d19
[ -f "$WORKER_FINISH_ARCHIVE_DIR/release-d19.json" ] && ok || bad "archive stores release json"

# 20. missing dispatch id in release response fails closed
newwt w20; reset
release_fixture d20 '{"ok":true,"result":{"state":"released","processAction":"closed_agent_terminal"}}' 0
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w20" --dispatch d20
[ "$(cat "$tmp/rc")" = 1 ] && [ -d "$tmp/w20" ] && ok || bad "missing dispatch id keeps worktree"

# 21. git status inspection failure keeps worktree without removal
newwt w21; reset; default_released d21
git -C "$tmp/w21" commit -q --allow-empty -m ensure-index 2>/dev/null || true
idx=$(git -C "$tmp/w21" rev-parse --git-path index)
if [ -f "$idx" ]; then
  chmod 000 "$idx"
  HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w21" --dispatch d21
  chmod 644 "$idx" 2>/dev/null || true
  [ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w21" ] && ok || bad "status inspection failure keeps worktree"
  grep -q "cannot inspect worktree status" "$tmp/out" "$tmp/err" && ok || bad "status inspection failure message"
else
  bad "status inspection failure setup missing index"
fi

# 22. unmerged index stages keep worktree after successful release
newwt w22; reset; default_released d22
b1=$(printf 'ours\n' | git -C "$tmp/w22" hash-object -w --stdin)
b2=$(printf 'theirs\n' | git -C "$tmp/w22" hash-object -w --stdin)
git -C "$tmp/w22" update-index --add --cacheinfo 2,"$b1",conflict.txt
git -C "$tmp/w22" update-index --add --cacheinfo 3,"$b2",conflict.txt
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w22" --dispatch d22
[ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w22" ] && ok || bad "unmerged index keeps worktree"
grep -q "dirty or unmerged worktree kept" "$tmp/out" "$tmp/err" && ok || bad "unmerged index reports kept"

# 23. clean unique commits (not MERGE_HEAD / index conflict) kept after release
newwt w23; reset; default_released d23
[ -z "$(git -C "$tmp/w23" status --porcelain 2>/dev/null)" ] && ok || bad "unique-commit fixture starts clean"
! git -C "$tmp/w23" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && ok || bad "unique-commit fixture has no MERGE_HEAD"
[ "$(git -C "$tmp/w23" rev-list --count origin/main..HEAD 2>/dev/null)" -gt 0 ] && ok || bad "unique-commit fixture has commits not in main"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w23" --dispatch d23
[ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w23" ] && ok || bad "clean unique commits keep worktree"
grep -q "HEAD not proven in merged main" "$tmp/out" "$tmp/err" && ok || bad "clean unique commits report ancestry block"
! grep -q "removed worktree" "$tmp/out" && ok || bad "clean unique commits must not be removed"

# 24. broken origin fetch fails closed before worktree removal
newwt w24; reset; default_released d24
push_wt_head_to_main "$tmp/w24"
orig_url=$(git -C "$tmp/w24" remote get-url origin)
git -C "$tmp/w24" remote set-url origin /nonexistent/orca-452-fetch-test
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w24" --dispatch d24
git -C "$tmp/w24" remote set-url origin "$orig_url"
[ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w24" ] && ok || bad "fetch failure keeps worktree"
grep -q "cannot verify main ancestry" "$tmp/out" "$tmp/err" && ok || bad "fetch failure reports ancestry query failure"
! grep -q "removed worktree" "$tmp/out" && ok || bad "fetch failure must not remove worktree"

# 25. merge-base query error must not fall through to merged-PR worktree removal
mf_pr_add 25 w25
G worktree add -q "$tmp/w25" w25
reset; default_released d25
jq '.state = "MERGED"' "$MF_GH_DIR/pr-25.json" > "$MF_GH_DIR/pr-25.json.tmp" && mv "$MF_GH_DIR/pr-25.json.tmp" "$MF_GH_DIR/pr-25.json"
WORKER_FINISH_TEST_MERGE_BASE_RC=128 HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w25" --dispatch d25
unset WORKER_FINISH_TEST_MERGE_BASE_RC
[ "$(cat "$tmp/rc")" = 0 ] && [ -d "$tmp/w25" ] && ok || bad "merge-base query error keeps worktree"
grep -q "cannot verify main ancestry" "$tmp/out" "$tmp/err" && ok || bad "merge-base query error reports unknown ancestry"
! grep -q "removed worktree" "$tmp/out" && ok || bad "merge-base query error must not remove worktree"

echo "worker-finish tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
