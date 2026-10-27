#!/usr/bin/env bash
# Self-test for lib/merge-fixture.sh (spec T35): real git, stateful fake gh and orca, fifo barrier, wall-clock limit.
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# shellcheck source=lib/merge-fixture.sh
. "$here/lib/merge-fixture.sh" || { echo "FAIL: fixture does not load"; exit 1; }
mf_setup
trap mf_teardown EXIT

# 1. gh and orca come first on PATH; only rev-parse --show-toplevel is stubbed
[ "$(command -v gh)" = "$MF_BIN/gh" ] && ok || bad "fake gh first on PATH"
[ "$(command -v orca)" = "$MF_BIN/orca" ] && ok || bad "fake orca first on PATH"
export MF_TOPLEVEL="$MF_DIR/elsewhere"
[ "$(git rev-parse --show-toplevel)" = "$MF_DIR/elsewhere" ] && ok || bad "show-toplevel stubbed"
unset MF_TOPLEVEL
[ "$(git -C "$MF_REPO" rev-parse --is-bare-repository)" = false ] && ok || bad "fixture repo is real git"
[ "$(git -C "$MF_ORIGIN" rev-parse --is-bare-repository)" = true ] && ok || bad "origin is a bare repo"

# 2. fake gh keeps one JSON file per PR with the recorded fields
mf_pr_add 1 feat-a "Body one"
[ -f "$MF_GH_DIR/pr-1.json" ] && ok || bad "one JSON file per PR"
head_a=$(git -C "$MF_REPO" rev-parse feat-a)
[ "$(gh pr view 1 --repo x/y --json state,headRefOid | jq -r '.state + " " + .headRefOid')" = "OPEN $head_a" ] && ok || bad "pr view state and head"
[ "$(jq -r '.body' "$MF_GH_DIR/pr-1.json")" = "Body one" ] && ok || bad "pr body stored"
jq -e '.files | length > 0' "$MF_GH_DIR/pr-1.json" >/dev/null && ok || bad "pr files stored"
jq -e 'has("closingIssuesReferences")' "$MF_GH_DIR/pr-1.json" >/dev/null && ok || bad "closingIssuesReferences stored"

# 3. comments carry edited and minimized flags; the 65536 limit is enforced
gh pr comment 1 --repo x/y --body "hello" >/dev/null && ok || bad "small comment accepted"
jq -e '.comments[0] | .body == "hello" and .edited == false and .minimized == false' "$MF_GH_DIR/pr-1.json" >/dev/null && ok || bad "comment flags default false"
mf_comment_flag 1 0 edited true
jq -e '.comments[0].edited == true' "$MF_GH_DIR/pr-1.json" >/dev/null && ok || bad "comment edited flag settable"
printf 'x%.0s' $(seq 1 65536) > "$MF_DIR/c65536"
printf 'x%.0s' $(seq 1 65537) > "$MF_DIR/c65537"
gh pr comment 1 --repo x/y --body-file "$MF_DIR/c65536" >/dev/null && ok || bad "65536 chars accepted"
gh pr comment 1 --repo x/y --body-file "$MF_DIR/c65537" >/dev/null 2>&1 && bad "65537 chars must be rejected" || ok
[ "$(jq '.comments | length' "$MF_GH_DIR/pr-1.json")" = 2 ] && ok || bad "rejected comment not stored"

# 4. pr merge really advances the bare origin
before=$(git -C "$MF_ORIGIN" rev-parse main)
gh pr merge 1 --repo x/y --merge --match-head-commit "$head_a" >/dev/null && ok || bad "pr merge succeeds"
after=$(git -C "$MF_ORIGIN" rev-parse main)
[ "$before" != "$after" ] && ok || bad "origin main advanced"
git -C "$MF_ORIGIN" merge-base --is-ancestor "$head_a" main && ok || bad "PR head is in origin main"
[ "$(jq -r '.state' "$MF_GH_DIR/pr-1.json")" = MERGED ] && ok || bad "pr state MERGED"
mf_pr_add 2 feat-b "Body two"
gh pr merge 2 --repo x/y --merge --match-head-commit deadbeef >/dev/null 2>&1 && bad "wrong match-head-commit must fail" || ok

# 5. gh calls reach one shared log, also from other processes
before_n=$(wc -l < "$MF_GH_LOG")
( gh pr view 2 --repo x/y --json state >/dev/null ) &
bash -c 'gh pr view 2 --repo x/y --json state >/dev/null' &
wait
[ "$(( $(wc -l < "$MF_GH_LOG") - before_n ))" = 2 ] && ok || bad "gh log shared across processes"
grep -q 'pr merge 1' "$MF_GH_LOG" && ok || bad "gh log records merges"

# 6. fake orca: runs, workers, terminals, logged calls, pane close
mf_orca_add_run r1
mf_orca_add_worker r1 d1 active "$MF_DIR/wt1"
mf_orca_add_worker r1 d2 released "$MF_DIR/wt2"
mf_orca_add_terminal t1 "$MF_DIR/wt1"
mf_orca_add_terminal t2 "$MF_DIR/wt2"
[ "$(orca orchestration run-list --json | jq -r '.runs[0].id')" = r1 ] && ok || bad "run-list"
[ "$(orca orchestration worker-list --run r1 --json | jq -r '.workers[] | select(.dispatchId=="d1") | .dispatchStatus + " " + .worktree')" = "active $MF_DIR/wt1" ] && ok || bad "worker-list dispatchStatus and worktree"
orca orchestration worker-release --dispatch d1 >/dev/null
[ "$(orca orchestration worker-list --json | jq -r '.workers[] | select(.dispatchId=="d1") | .dispatchStatus')" = released ] && ok || bad "worker-release updates state"
[ "$(orca terminal list --json | jq '.terminals | length')" = 2 ] && ok || bad "terminal list shows both"
orca terminal close --terminal t2 >/dev/null
[ "$(orca terminal list --json | jq -r '[.terminals[].handle] | join(",")')" = t1 ] && ok || bad "pane close removes terminal from next list"
[ "$(grep -c 'worker-release' "$MF_ORCA_LOG")" = 1 ] && ok || bad "orca log counts worker-release"
[ "$(grep -c 'run-list' "$MF_ORCA_LOG")" = 1 ] && ok || bad "orca log counts run-list"
bash -c 'orca orchestration run-list --json >/dev/null'
[ "$(grep -c 'run-list' "$MF_ORCA_LOG")" = 2 ] && ok || bad "orca log shared across processes"

# 7. fifo barrier blocks a fake head-checks until released
mf_barrier_make gate
( mf_barrier_wait gate; echo done > "$MF_DIR/barrier-out" ) &
waiter=$!
mf_barrier_wait_until_blocked gate 5 && ok || bad "waiter reached the barrier"
[ ! -e "$MF_DIR/barrier-out" ] && ok || bad "waiter blocked before release"
mf_run_limited 5 mf_barrier_release gate && ok || bad "release returns"
wait "$waiter"
[ -e "$MF_DIR/barrier-out" ] && ok || bad "waiter continued after release"

# 8. wall-clock limit works without coreutils timeout
mf_run_limited 5 true; [ $? = 0 ] && ok || bad "limit passes exit 0"
mf_run_limited 5 bash -c 'exit 7'; [ $? = 7 ] && ok || bad "limit passes exit code"
start=$SECONDS
mf_run_limited 1 bash -c 'sleep 30'; rc=$?
[ "$rc" = 124 ] && ok || bad "limit returns 124 on timeout (got $rc)"
[ $((SECONDS - start)) -lt 10 ] && ok || bad "limit kills a sleeping command promptly"

echo "merge-fixture: $pass passed, $fail failed"
[ "$fail" = 0 ]
