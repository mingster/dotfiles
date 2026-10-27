#!/usr/bin/env bash
# Tests for worker-finish.sh: head-checks gate before anything is released, closed or removed.
# The pane close helper is only called with dispatch ids (spec #286, T33, invariant 18).
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
export ORCA_CLI_COMMAND="$MF_BIN/orca" HEAD_CHECKS_LOG="$tmp/checks.log" PANE_LOG="$tmp/pane.log" WORKER_PANE_CLOSE="$tmp/pane-close"
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

# A worktree with one commit that is not in origin/main, so head-checks apply.
newwt() { G worktree add -q "$tmp/$1" -b "$1" origin/main; git -C "$tmp/$1" commit -q --allow-empty -m "work $1"; }
run() { (cd "$MF_REPO" && mf_run_limited 20 "$@") >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }
reset() { : > "$MF_ORCA_LOG"; : > "$HEAD_CHECKS_LOG"; : > "$PANE_LOG"; }
released() { grep -c "worker-release --dispatch $1" "$MF_ORCA_LOG"; }

# 1. failing checks refuse, touch nothing
newwt w1; reset; mf_orca_add_worker run1 d1 dispatched "$tmp/w1"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 1 ] && ok || bad "failing checks exit 1"
grep -q "worker-finish: head-checks failed, refusing worker_done" "$tmp/err" && ok || bad "failing checks message"
[ -d "$tmp/w1" ] && ok || bad "failing checks keep worktree"
[ "$(released d1)" = 0 ] && ok || bad "failing checks leave dispatch untouched"
grep -q -- "--repo .*w1 --ref HEAD --base origin/main" "$HEAD_CHECKS_LOG" && ok || bad "checks called with repo, ref, base"

# 2. passing checks proceed
reset
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w1" --dispatch d1
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "passing checks exit 0"
[ ! -d "$tmp/w1" ] && ok || bad "passing checks remove worktree"
[ "$(released d1)" = 1 ] && ok || bad "passing checks release dispatch"
grep -qx "pane-close d1" "$PANE_LOG" && ok || bad "explicit dispatch id reaches the pane close helper"

# 3. skip flag needs a reason, prints it, skips the checks
newwt w2; reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip without reason exits 2"
[ -d "$tmp/w2" ] && ok || bad "skip without reason keeps worktree"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks ""
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "skip with empty reason exits 2"
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w2" --skip-head-checks "docs only"
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "skip with reason exits 0"
grep -q "docs only" "$tmp/out" "$tmp/err" && ok || bad "skip prints the reason"
[ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "skip does not run checks"

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
[ "$(released d4)" = 0 ] && ok || bad "missing checks leave dispatch untouched"

# 6. post-merge: a head already in origin/main, or a merged PR, skips the checks without blocking
G worktree add -q "$tmp/w5" -b w5 origin/main
git -C "$tmp/w5" commit -q --allow-empty -m work
git -C "$tmp/w5" push -q origin w5:main
reset
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
reset
HEAD_CHECKS="$tmp/checks-fail" run bash "$here/../worker-finish.sh" --worktree "$tmp/w6" --dispatch d6
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "merged PR exits 0"
grep -q "skipping head-checks, its PR is already merged" "$tmp/out" && ok || bad "merged PR prints one skip line"
[ ! -s "$HEAD_CHECKS_LOG" ] && ok || bad "merged PR does not run checks"

# 7. T33: no dispatch ids means no pane close call (the helper without arguments sweeps and loops), and the run still ends
newwt w7; reset
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w7"
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "no dispatch ids: finishes (rc $(cat "$tmp/rc"))"
[ ! -s "$PANE_LOG" ] && ok || bad "no dispatch ids: pane close helper not called"
[ ! -d "$tmp/w7" ] && ok || bad "no dispatch ids: worktree removed"
# ids found from the Orca inventory are passed on
newwt w8; reset; mf_orca_add_worker run1 d8 dispatched "$tmp/w8"
HEAD_CHECKS="$tmp/checks-pass" run bash "$here/../worker-finish.sh" --worktree "$tmp/w8"
grep -qx "pane-close d8" "$PANE_LOG" && [ "$(released d8)" = 1 ] && ok || bad "inventory dispatch id released and passed to the helper"

echo "worker-finish tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
