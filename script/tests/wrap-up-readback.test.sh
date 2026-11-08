#!/usr/bin/env bash
# Verify wrap-up.sh reads state back after git worktree remove, git branch -d/-D,
# orca terminal close, and browser kill, recording fail_item and exiting non-zero
# whenever the target still exists after a zero exit code.
# shellcheck source=lib/asdf-pin.sh
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

real_git=$(command -v git)
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/cwd"

cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
  *'pr view --json state'*) echo 'MERGED'; exit 0 ;;
esac
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE

cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  'worktree rm --worktree path:'*) exit 1 ;;
  'terminal close'*)
    exit 0
    ;;
  'terminal show'*)
    if [ "${FAKE_TERM_STILL_OPEN:-0}" = 1 ]; then
      h=""
      for a in "$@"; do h=$prev; prev=$a; [ "$h" = --terminal ] && { h=$a; break; }; done
      printf '{"ok":true,"result":{"terminal":{"handle":"%s","connected":true,"writable":true,"state":"open"}}}\n' "$h"
      exit 0
    fi
    echo '{"ok":false,"error":{"code":"terminal_handle_stale"}}'
    exit 1
    ;;
  'terminal list'*)
    printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}"
    ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*)
    printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false}}}\n' "${FAKE_WORKERS:-[]}"
    ;;
  *worker-show*)
    printf '%s\n' "${FAKE_WORKER_SHOW:-{\"ok\":true,\"result\":{\"dispatchId\":\"d1\",\"state\":\"succeeded\",\"stage\":\"released\",\"liveness\":\"exited\"}}}"
    ;;
  *worker-release*)
    echo '{"ok":true,"result":{"dispatchId":"d1","state":"released"}}'
    ;;
  *) exit 1 ;;
esac
FAKE

cat > "$tmp/bin/git" <<'FAKE'
#!/usr/bin/env bash
if [ "${FAKE_GIT_NOOP_WT_REMOVE:-0}" = 1 ] && [[ "$*" == *"worktree remove"* ]]; then
  exit 0
fi
if [ "${FAKE_GIT_STALE_WT_LIST:-0}" = 1 ]; then
  if [[ "$*" == *"worktree remove"* ]]; then
    for a in "$@"; do last=$a; done
    rm -rf "$last"
    exit 0
  fi
  if [[ "$*" == *"worktree prune"* ]]; then
    exit 0
  fi
fi
if [ "${FAKE_GIT_NOOP_BRANCH_DELETE:-0}" = 1 ] && [[ "$*" == *"branch -d"* || "$*" == *"branch -D"* ]]; then
  exit 0
fi
exec "$REAL_GIT" "$@"
FAKE

printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\necho init\n' > "$tmp/bin/ps"
cat > "$tmp/ps-seam" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list) cat "$FAKE_PS" ;;
  show) awk -F'\t' -v p="$2" '$1 == p' "$FAKE_PS" ;;
  cwd) [ -f "$FAKE_CWDS/$2" ] || exit 1; cat "$FAKE_CWDS/$2" ;;
esac
FAKE
cat > "$tmp/kill-seam" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_KILLS"
exit 0
FAKE
cat > "$tmp/alive-seam" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ALIVE_CHECKS"
if [ -n "${FAKE_ALIVE_POLLS:-}" ]; then
  n=$(wc -l < "$FAKE_ALIVE_CHECKS" | tr -d ' ')
  [ "$n" -le "$FAKE_ALIVE_POLLS" ] && exit 0
  exit 1
fi
[ "${FAKE_KILL_STILL_ALIVE:-0}" = 1 ] && exit 0
exit 1
FAKE

chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/git" "$tmp/bin/lsof" "$tmp/bin/ps" "$tmp/ps-seam" "$tmp/kill-seam" "$tmp/alive-seam"

export REAL_GIT="$real_git" PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_STATE_DIR="$tmp/no-state"
export FAKE_PS="$tmp/ps-table" FAKE_CWDS="$tmp/cwd" FAKE_KILLS="$tmp/kills" FAKE_ALIVE_CHECKS="$tmp/alive-checks"

passed=0
failed=0
check() {
  local desc=$1
  shift
  if "$@"; then
    printf 'ok %s\n' "$desc"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$desc"
    failed=$((failed + 1))
  fi
}

n=0
fixture() {
  n=$((n + 1))
  d="$tmp/f$n"
  mkdir -p "$d"
  export ORCA_LOG="$d/orca.log"
  : > "$ORCA_LOG"
  : > "$FAKE_PS"
  : > "$FAKE_KILLS"
  : > "$FAKE_ALIVE_CHECKS"
  rm -f "${FAKE_CWDS:?}"/*
  unset FAKE_GIT_NOOP_WT_REMOVE FAKE_GIT_STALE_WT_LIST FAKE_GIT_NOOP_BRANCH_DELETE
  unset FAKE_TERM_STILL_OPEN FAKE_KILL_STILL_ALIVE FAKE_ALIVE_POLLS FAKE_WORKERS FAKE_WORKER_SHOW
  export FAKE_PRS='[]'
  export FAKE_TERMINALS='[]'
  "$real_git" init -q --bare "$d/origin"
  "$real_git" init -q -b main "$d/repo"
  cd "$d/repo" || exit 1
  "$real_git" config user.email t@example.invalid
  "$real_git" config user.name T
  "$real_git" commit -qm initial --allow-empty
  "$real_git" remote add origin "$d/origin"
  "$real_git" push -q -u origin main
}

run_apply() {
  bash "$root/script/wrap-up.sh" --repo "$d/repo" --apply > "$d/out" 2> "$d/err"
  echo $? > "$d/rc"
}

# 1a. Worktree remove exits 0 but directory remains on disk in guarded_worktree_remove.
fixture
"$real_git" branch wt-branch
"$real_git" push -q origin wt-branch
"$real_git" worktree add -q "$d/wt-dir" wt-branch
FAKE_GIT_NOOP_WT_REMOVE=1 run_apply
check 'worktree dir still present: wrap-up exits non-zero' test "$(cat "$d/rc")" -ne 0
check 'worktree dir still present: records fail_item' grep -Fq "worktree still present after remove: $d/wt-dir" "$d/out"
check 'worktree dir still present: not counted as removed' grep -Fq 'removed worktrees=0' "$d/out"
check 'worktree dir still present: its branch is kept as kept worktree' grep -Fq 'Kept local wt-branch (checked out in kept worktree)' "$d/out"

# 1b. Worktree remove deletes directory and exits 0, but path remains in git worktree list --porcelain.
fixture
"$real_git" branch wt-listed
"$real_git" push -q origin wt-listed
"$real_git" worktree add -q "$d/wt-listed-dir" wt-listed
FAKE_GIT_STALE_WT_LIST=1 run_apply
check 'worktree entry still in porcelain list: wrap-up exits non-zero' test "$(cat "$d/rc")" -ne 0
check 'worktree entry still in porcelain list: records fail_item' grep -Fq "worktree still present after remove: $d/wt-listed-dir" "$d/out"
check 'worktree entry still in porcelain list: not counted as removed' grep -Fq 'removed worktrees=0' "$d/out"

# 1c. --branch mode worktree remove exits 0 but directory remains.
fixture
"$real_git" branch br-wt
"$real_git" push -q origin br-wt
"$real_git" worktree add -q "$d/wt-br" br-wt
wt_br_real=$(cd -P "$d/wt-br" && pwd)
export WRAP_UP_ORCA_APP_BIN="$tmp/bin"
export FAKE_WORKERS="[{\"runId\":\"run-1\",\"dispatchId\":\"d1\",\"dispatchStatus\":\"released\",\"state\":\"succeeded\",\"stage\":\"released\",\"liveness\":\"exited\",\"worktree\":\"$wt_br_real\",\"worktreeId\":\"repo::$wt_br_real\",\"workspace\":\"repo::$wt_br_real\"}]"
FAKE_GIT_NOOP_WT_REMOVE=1 bash "$root/script/wrap-up.sh" --branch br-wt --head-sha "$("$real_git" -C "$d/repo" rev-parse main)" > "$d/out" 2> "$d/err"
echo $? > "$d/rc"
check '--branch worktree still present: exits non-zero' test "$(cat "$d/rc")" -ne 0
check '--branch worktree still present: records fail_item' grep -Fq "worktree still present after remove: $wt_br_real" "$d/out" "$d/err"

# 1d. --finish-worker mode worktree remove exits 0 but directory remains.
fixture
"$real_git" worktree add -q -b fw-wt "$d/wt-fw" main
FAKE_GIT_NOOP_WT_REMOVE=1 bash "$root/script/wrap-up.sh" --finish-worker --worktree "$d/wt-fw" --dispatch d1 --skip-head-checks "test" > "$d/out" 2> "$d/err"
echo $? > "$d/rc"
check '--finish-worker worktree still present: exits non-zero' test "$(cat "$d/rc")" -ne 0
check '--finish-worker worktree still present: records fail_item' grep -Fq "worktree still present after remove: $d/wt-fw" "$d/out" "$d/err"
check '--finish-worker worktree still present: does not claim removed' bash -c "! grep -Fq 'removed worktree' '$d/out'"

# 2a. Local branch delete (-d and -D) exits 0 but refs/heads/$branch still exists in guarded_local_branch_delete.
fixture
"$real_git" branch br-anc
"$real_git" push -q origin br-anc
"$real_git" checkout -q -b br-closed main
"$real_git" commit -qm closed-tip --allow-empty
"$real_git" push -q origin br-closed
"$real_git" branch br-closed-copy br-closed
"$real_git" push -q origin br-closed-copy
"$real_git" checkout -q main
closed_sha=$("$real_git" rev-parse br-closed)
export FAKE_PRS="[{\"headRefName\":\"br-closed\",\"headRefOid\":\"$closed_sha\",\"state\":\"CLOSED\"}]"
FAKE_GIT_NOOP_BRANCH_DELETE=1 run_apply
check 'branch ref still exists after -d/-D: wrap-up exits non-zero' test "$(cat "$d/rc")" -ne 0
check 'branch ref still exists after -d: records fail_item' grep -Fq 'branch ref still exists after delete: br-anc' "$d/out"
check 'branch ref still exists after -D: records fail_item' grep -Fq 'branch ref still exists after delete: br-closed' "$d/out"
check 'branch ref still exists: deleted local count is 0' grep -Fq 'deleted local=0' "$d/out"

# 2b. --branch mode local branch delete exits 0 but refs/heads/$branch still exists.
fixture
"$real_git" branch br-merge
"$real_git" push -q origin br-merge
FAKE_GIT_NOOP_BRANCH_DELETE=1 bash "$root/script/wrap-up.sh" --branch br-merge --head-sha "$("$real_git" -C "$d/repo" rev-parse main)" > "$d/out" 2> "$d/err"
echo $? > "$d/rc"
check '--branch local delete ref still exists: exits non-zero' test "$(cat "$d/rc")" -ne 0
check '--branch local delete ref still exists: records fail_item' grep -Fq 'branch ref still exists after delete: br-merge' "$d/out" "$d/err"

# 3. Orca terminal close exits 0 but terminal remains open on read-back.
fixture
export FAKE_TERMINALS='[{"handle":"t-open","worktreePath":"/x/settled","connected":true,"writable":true,"lastOutputAt":1,"agentIdentity":null,"title":"zsh"}]'
FAKE_TERM_STILL_OPEN=1 run_apply
check 'terminal still open after close: wrap-up exits non-zero' test "$(cat "$d/rc")" -ne 0
check 'terminal still open after close: records fail_item' grep -Eq 'terminal t-open.*still open after close' "$d/out"
check 'terminal still open after close: terminals closed count is 0' grep -Fq 'terminals closed=0' "$d/out"

# 4a. Browser exits after a few alive polls within the 5s window: wrap-up succeeds and counts it closed.
fixture
dev='/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev'
printf '900\t1\t90000\tstart-900\t%s --user-data-dir=/tmp/pw-prof-900\n' "$dev" > "$FAKE_PS"
printf '/tmp\n' > "$FAKE_CWDS/900"
FAKE_ALIVE_POLLS=3 WRAP_UP_PS_CMD="$tmp/ps-seam" WRAP_UP_KILL_CMD="$tmp/kill-seam" WRAP_UP_ALIVE_CMD="$tmp/alive-seam" run_apply
check 'browser pid exits after 3 polls: wrap-up exits zero' test "$(cat "$d/rc")" -eq 0
check 'browser pid exits after 3 polls: browsers closed count is 1' grep -Fq 'browsers closed=1 kept=0' "$d/out"

# 4b. Browser kill -TERM exits 0 but alive seam reports the browser PID is still alive past the 5s window.
fixture
printf '901\t1\t90000\tstart-901\t%s --user-data-dir=/tmp/pw-prof-901\n' "$dev" > "$FAKE_PS"
printf '/tmp\n' > "$FAKE_CWDS/901"
FAKE_KILL_STILL_ALIVE=1 WRAP_UP_PS_CMD="$tmp/ps-seam" WRAP_UP_KILL_CMD="$tmp/kill-seam" WRAP_UP_ALIVE_CMD="$tmp/alive-seam" run_apply
check 'browser pid still alive after kill: wrap-up exits non-zero' test "$(cat "$d/rc")" -ne 0
check 'browser pid still alive after kill: records fail_item' grep -Fq 'browser pid 901 still alive after kill' "$d/out"
check 'browser pid still alive after kill: browsers closed count is 0' grep -Fq 'browsers closed=0 kept=1' "$d/out"
check 'browser pid still alive after kill: polled 25 times before final check' test "$(wc -l < "$FAKE_ALIVE_CHECKS" | tr -d ' ')" -eq 26

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
