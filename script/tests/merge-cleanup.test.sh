#!/usr/bin/env bash
# merge-cleanup.sh acts by ownership: the merged PR head, and released, idle, merged worktrees (spec #286, T4 to T12, T23, T27 to T29, T33).
here=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -f "$MF_DIR/out" ] && sed 's/^/    /' "$MF_DIR/out"; }

# shellcheck source=lib/merge-fixture.sh
. "$here/lib/merge-fixture.sh"
mf_setup
trap mf_teardown EXIT
G() { "$MF_REAL_GIT" -C "$MF_REPO" "$@"; }
export MERGE_CLEANUP_CALL_TIMEOUT_SECONDS=5
cleanup="$here/../merge-cleanup.sh"
cd "$MF_REPO" || exit 1

# Fake pane close helper: closes the terminal of each dispatch id it is given. Logs its arguments.
cat > "$MF_DIR/pane-close" <<'EOS'
#!/usr/bin/env bash
echo "pane-close $*" >> "$MF_DIR/pane.log"
[ "$#" -gt 0 ] || { while :; do sleep 1; done; }
for id in "$@"; do
  h=$(orca orchestration worker-list --json | jq -r --arg d "$id" '.workers[] | select(.dispatchId==$d) | .agentTerminalHandle')
  [ -z "$h" ] || orca terminal close --terminal "$h"
done
EOS
cat > "$MF_DIR/pane-hang" <<'EOS'
#!/usr/bin/env bash
while :; do sleep 1; done
EOS
export WORKER_PANE_CLOSE="$MF_DIR/pane-close"

n=0
# wt <name> <branch> [commit]: worktree on a new branch pushed to origin; "commit" adds a commit not in main.
wt() {
  mkdir -p "$MF_DIR/wt"
  G worktree add -q -b "$2" "$MF_DIR/wt/$1" origin/main
  if [ "${3:-}" = commit ]; then
    echo "$2" > "$MF_DIR/wt/$1/$2.txt"
    git -C "$MF_DIR/wt/$1" add . && git -C "$MF_DIR/wt/$1" commit -q -m "$2"
  fi
  G push -q origin "$2"
}
# land <branch>: merge into main and push.
land() { G merge -q --no-ff -m "merge $1" "$1" && G push -q origin main; }
path() { (cd -P "$MF_DIR/wt/$1" && pwd); }
dispatch() { n=$((n + 1)); mf_orca_add_worker run1 "d$n" "$2" "$(path "$1")" "${3:-}"; }
run() { rm -f "$MF_DIR/out"; "$@" > "$MF_DIR/out" 2>&1; echo $? > "$MF_DIR/rc"; }
has_local() { G show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { "$MF_REAL_GIT" --git-dir="$MF_ORIGIN" show-ref --verify --quiet "refs/heads/$1"; }
rc_is() { [ "$(cat "$MF_DIR/rc")" = "$1" ]; }
says() { grep -q -- "$1" "$MF_DIR/out"; }
kept() { [ -d "$MF_DIR/wt/$1" ] && has_local "$2"; }
gone() { [ ! -d "$MF_DIR/wt/$1" ] && ! has_local "$2" && ! has_remote "$2"; }
clean_run() { run bash "$cleanup" --branch merged-head --head-sha "$headsha" "$@"; }

# The merged PR head: pushed, merged into main.
G checkout -q -b merged-head origin/main; echo h > h.txt; G add h.txt; G commit -qm head; G push -q origin merged-head
G checkout -q main; land merged-head; headsha=$(G rev-parse merged-head)

# T4: a branch name carrying a date number never selects another worktree.
wt rm-x-1027 rm-x-1027; dispatch rm-x-1027 released
G branch -q merge-process-1027 main; G push -q origin merge-process-1027
run bash "$cleanup" --branch merge-process-1027 --head-sha "$(G rev-parse main)"
rc_is 0 && kept rm-x-1027 rm-x-1027 && has_remote rm-x-1027 && ok || bad "T4 rm worktree and branch kept"
says 'kept' && ok || bad "T4 prints kept"
gone nothing merge-process-1027 && ok || bad "T4 the PR head itself is deleted"

# T6: a live terminal at the worktree root, and one in a subdirectory, keeps worktree and branch.
for where in root sub; do
  wt "live-$where" "live-$where"; dispatch "live-$where" released
  dir=$(path "live-$where"); [ "$where" = sub ] && { mkdir -p "$dir/deep"; dir="$dir/deep"; }
  mf_orca_add_terminal "term-$where" "$dir"
  clean_run
  kept "live-$where" "live-$where" && has_remote "live-$where" && ok || bad "T6 live terminal at $where keeps worktree and branch"
done

# T7: a branch checked out in an idle worktree is kept; a failing worktree removal keeps local and remote branch.
wt checked-out checked-out; run bash "$cleanup" --branch checked-out --head-sha "$(G rev-parse checked-out)"
kept checked-out checked-out && has_remote checked-out && ok || bad "T7 checked out branch kept"
wt locked locked; dispatch locked released; G worktree lock "$MF_DIR/wt/locked"
clean_run
kept locked locked && has_remote locked && ok || bad "T7 failed worktree removal keeps both branches"
says 'kept' && ok || bad "T7 prints kept"
G worktree unlock "$MF_DIR/wt/locked"

# T8, T27: an unreleased dispatch keeps the worktree, even on a branch with no commits. No release call is made.
wt busy busy commit; dispatch busy dispatched
wt fresh fresh; dispatch fresh dispatched
clean_run
kept busy busy && kept fresh fresh && has_remote fresh && ok || bad "T8/T27 unreleased dispatch keeps worktree and branch"
! grep -q worker-release "$MF_ORCA_LOG" && ok || bad "T8 no worker-release call"

# T9: a released worker named by PR number goes in one run.
wt qa-345 qa-345; dispatch qa-345 released
clean_run
gone qa-345 qa-345 && ok || bad "T9 released qa-<PR> worker removed"

# T10: a released worker's branch with a commit outside main survives and is listed.
wt lane-b lane-b commit; dispatch lane-b released
clean_run
kept lane-b lane-b && has_remote lane-b && ok || bad "T10 unmerged commit keeps worktree and branch"
says 'lane-b' && ok || bad "T10 lists the kept branch"

# T11: an ended pane is closed, then the worktree goes, in one run.
wt ended ended; dispatch ended released term-ended; mf_orca_add_terminal term-ended "$(path ended)"
clean_run
gone ended ended && ok || bad "T11 ended pane closed and worktree removed"
grep -q "pane-close d$n" "$MF_DIR/pane.log" && ok || bad "T11 pane close got the dispatch id"

# T28: the merged head branch gained a commit after the merged sha: kept. At the merged sha it goes even when not in main.
G checkout -q -b grown origin/main; echo 1 > g1.txt; G add g1.txt; G commit -qm g1; mergedsha=$(G rev-parse HEAD)
echo 2 > g2.txt; G add g2.txt; G commit -qm g2; G push -q origin grown; G checkout -q main
run bash "$cleanup" --branch grown --head-sha "$mergedsha"
has_local grown && has_remote grown && ok || bad "T28 head with a later commit kept"
says 'grown' && ok || bad "T28 lists it"
G checkout -q -b squashed origin/main; echo s > s.txt; G add s.txt; G commit -qm s; G push -q origin squashed; G checkout -q main
run bash "$cleanup" --branch squashed --head-sha "$(G rev-parse squashed)"
! has_local squashed && ! has_remote squashed && ok || bad "T28 head at the merged sha deleted though not in main"

# The remote head gained a commit after the merged sha while the local branch stayed at it: the remote branch is kept.
G checkout -q -b ahead origin/main; echo a1 > a1.txt; G add a1.txt; G commit -qm a1; aheadsha=$(G rev-parse HEAD)
echo a2 > a2.txt; G add a2.txt; G commit -qm a2; G push -q origin ahead; G reset -q --hard "$aheadsha"; G checkout -q main
run bash "$cleanup" --branch ahead --head-sha "$aheadsha"
has_remote ahead && says 'Kept remote ahead' && ok || bad "remote head with a later commit kept"

# T29 and T23: an idle rm-* or lead-* worktree with a released dispatch and all commits in main is kept.
wt rm-keep rm-keep; dispatch rm-keep released
wt lead-keep lead-keep; dispatch lead-keep released
clean_run
kept rm-keep rm-keep && kept lead-keep lead-keep && ok || bad "T29/T23 rm-* and lead-* kept"
says 'protected: kept worktree .*lead-keep' && ok || bad "T23 lead-* protected message"

# Unsaved changes in a released, merged worktree: kept and listed (open question 3).
wt wip wip; dispatch wip released; echo wip > "$MF_DIR/wt/wip/w.txt"
clean_run
kept wip wip && says 'wip has unsaved changes' && ! says 'Remove worktree .*wip' && ok || bad "dirty released worktree kept and listed"

# A worktree with no dispatch at all has no proven owner: kept.
wt unowned unowned
clean_run
kept unowned unowned && ok || bad "worktree without a dispatch kept"

# T33 (cleanup half): a pane close that never returns is cut off by the call timeout and reported as kept.
wt stuck stuck; dispatch stuck released term-stuck; mf_orca_add_terminal term-stuck "$(path stuck)"
start=$SECONDS
WORKER_PANE_CLOSE="$MF_DIR/pane-hang" MERGE_CLEANUP_CALL_TIMEOUT_SECONDS=2 mf_run_limited 15 bash -c \
  "bash '$cleanup' --branch merged-head --head-sha '$headsha' > '$MF_DIR/out' 2>&1"; echo $? > "$MF_DIR/rc"
rc_is 0 && [ $((SECONDS - start)) -lt 15 ] && ok || bad "T33 hung pane close ends within the limit"
says 'timed out' && kept stuck stuck && ok || bad "T33 timeout printed as kept"

# DRY_RUN changes nothing.
wt dry dry; dispatch dry released
refs=$(G for-each-ref; G worktree list)
DRY_RUN=1 clean_run
[ "$refs" = "$(G for-each-ref; G worktree list)" ] && kept dry dry && ok || bad "dry run changes nothing"

# Protected branches survive.
run bash "$cleanup" --branch main
has_local main && has_remote main && says 'protected: kept main' && ok || bad "main never deleted"

# Cleanup never releases a dispatch.
! grep -q worker-release "$MF_ORCA_LOG" && ok || bad "T8 no worker-release call in the whole run"

echo "merge-cleanup tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
