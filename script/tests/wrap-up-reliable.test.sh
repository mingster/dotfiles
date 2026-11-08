#!/usr/bin/env bash
# wrap-up must finish every item it can, name every item it cannot with a reason, bound every call, and never
# delete the last copy of unmerged work. Disposable repos and fake gh, orca and git only; nothing real is touched.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d); tmp=$(cd "$tmp" && pwd -P)
trap '[ -n "${KEEP:-}" ] || rm -rf "$tmp"' EXIT
real_git=$(command -v git)
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
if [ -n "${ORCA_HANG_ON:-}" ] && [[ "$*" =~ $ORCA_HANG_ON ]]; then sleep 300; fi
case "$*" in
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  'worktree rm --worktree path:'*) exit 0 ;;
  'terminal close --terminal '*) [ "${3:-}" != "--terminal" ] || :; [ "${4:-}" != "${ORCA_CLOSE_FAIL:-none}" ] || exit 1; exit 0 ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/git" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${FAIL_GIT:-}" ] && [[ "$*" =~ $FAIL_GIT ]]; then
  [ -z "${HANG_GIT:-}" ] || sleep 300
  echo "fake git failure" >&2; exit 1
fi
exec "$REAL_GIT" "$@"
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/git" "$tmp/bin/lsof"
export REAL_GIT="$real_git" PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_STATE_DIR="$tmp/no-state"
passed=0; failed=0
check() { local d=$1; shift; if "$@"; then printf 'ok %s\n' "$d"; passed=$((passed+1)); else printf 'FAIL %s\n' "$d"; failed=$((failed+1)); fi; }

n=0
# fixture: origin, repo with merged branches m1 m2 m3 (m1 and m2 have worktrees) and two terminals wrap-up may close.
fixture() {
  n=$((n+1)); d="$tmp/f$n"; mkdir -p "$d"
  export ORCA_LOG="$d/orca.log"; : > "$ORCA_LOG"
  unset ORCA_HANG_ON ORCA_CLOSE_FAIL FAIL_GIT HANG_GIT WRAP_UP_CALL_TIMEOUT WRAP_UP_TOTAL_TIMEOUT
  export FAKE_PRS='[]'
  FAKE_TERMINALS='[{"handle":"t1","worktreePath":"/x/other1","connected":true,"writable":true,"lastOutputAt":1,"agentIdentity":null,"title":"zsh"},{"handle":"t2","worktreePath":"/x/other2","connected":true,"writable":true,"lastOutputAt":1,"agentIdentity":null,"title":"zsh"}]'
  export FAKE_TERMINALS
  "$real_git" init -q --bare "$d/origin"
  "$real_git" init -q -b main "$d/repo"
  cd "$d/repo" || exit 1
  git config user.email t@example.invalid; git config user.name T
  git commit -qm initial --allow-empty
  git remote add origin "$d/origin"; git push -q -u origin main
  for b in m1 m2 m3; do git branch "$b"; git push -q origin "$b"; done
  git worktree add -q "$d/wt-m1" m1; git worktree add -q "$d/wt-m2" m2
}
run() { bash "$root/script/wrap-up.sh" --repo "$d/repo" --apply "$@" > "$d/out" 2> "$d/err"; echo $? > "$d/rc"; }
rc() { cat "$d/rc"; }
has_local() { git -C "$d/repo" show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { "$real_git" -C "$d/repo" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }
closed() { grep -Fq "terminal close --terminal $1" "$ORCA_LOG"; }

# 1. Everything that is finished goes, and a clean run exits 0 with no failure list.
fixture; run
check 'worktrees removed' bash -c "[ ! -d '$d/wt-m1' ] && [ ! -d '$d/wt-m2' ]"
check 'local branches deleted' bash -c "$(declare -f has_local); d='$d'; ! has_local m1 && ! has_local m2 && ! has_local m3"
check 'remote branches deleted' bash -c "$(declare -f has_remote); real_git='$real_git'; d='$d'; ! has_remote m1 && ! has_remote m2 && ! has_remote m3"
check 'terminals closed' bash -c "$(declare -f closed); ORCA_LOG='$ORCA_LOG'; closed t1 && closed t2"
check 'clean run exits 0' test "$(rc)" = 0
check 'clean run prints no failure list' bash -c "! grep -q '^Failures' '$d/out'"

# 2. One worktree that will not go does not stop the other items; the run lists it and exits non-zero.
fixture
FAIL_GIT='worktree remove .*wt-m1' run
check 'failing worktree: the other worktree is removed' test ! -d "$d/wt-m2"
check 'failing worktree: its branch stays with it' bash -c "$(declare -f has_local); d='$d'; has_local m1"
check 'failing worktree: other branches still deleted' bash -c "$(declare -f has_local); d='$d'; ! has_local m2 && ! has_local m3"
check 'failing worktree: terminals still closed' bash -c "$(declare -f closed); ORCA_LOG='$ORCA_LOG'; closed t1 && closed t2"
check 'failing worktree: exit is non-zero' test "$(rc)" != 0
check 'failing worktree: listed with its reason' grep -Eq "^Failures \(1\)|^  worktree .*wt-m1: remove failed" "$d/out"
check 'failing worktree: the failure line names item and reason' grep -Eq '^  worktree .*wt-m1.*: remove failed' "$d/out"

# 3. One remote branch that will not delete does not stop the others.
fixture
FAIL_GIT='push .*--delete .*m2' run
check 'failing remote: m1 and m3 gone' bash -c "$(declare -f has_remote); real_git='$real_git'; d='$d'; ! has_remote m1 && ! has_remote m3"
check 'failing remote: m2 stays on origin' bash -c "$(declare -f has_remote); real_git='$real_git'; d='$d'; has_remote m2"
check 'failing remote: exit is non-zero' test "$(rc)" != 0
check 'failing remote: listed with its reason' grep -Eq '^  remote m2: delete failed' "$d/out"

# 4. One terminal that will not close does not stop the other.
fixture
ORCA_CLOSE_FAIL=t1 run
check 'failing terminal: t2 closed' bash -c "$(declare -f closed); ORCA_LOG='$ORCA_LOG'; closed t2"
check 'failing terminal: branches still cleaned' bash -c "$(declare -f has_local); d='$d'; ! has_local m3"
check 'failing terminal: exit is non-zero' test "$(rc)" != 0
check 'failing terminal: listed with its reason' grep -Eq '^  terminal t1.*: close failed' "$d/out"

# 5. A hung orca call times out, is reported, and the items that need no orca still go.
fixture
start=$SECONDS
ORCA_HANG_ON='terminal list' WRAP_UP_CALL_TIMEOUT=2 WRAP_UP_TOTAL_TIMEOUT=60 run
check 'hung orca: the run ends well inside the limit' test $((SECONDS-start)) -lt 40
check 'hung orca: the branch with no worktree is still deleted' bash -c "$(declare -f has_local); d='$d'; ! has_local m3"
check 'hung orca: worktrees stay (activity unknown)' test -d "$d/wt-m1"
check 'hung orca: exit is non-zero' test "$(rc)" != 0
check 'hung orca: the timeout is reported' grep -Eq '^  .*orca.*timed out after 2s' "$d/out"

# 6. A hung git push times out; the other remote deletes still happen one by one.
fixture
HANG_GIT=1 FAIL_GIT='push .*--delete .*m2' WRAP_UP_CALL_TIMEOUT=2 WRAP_UP_TOTAL_TIMEOUT=60 run
check 'hung push: m1 and m3 gone from origin' bash -c "$(declare -f has_remote); real_git='$real_git'; d='$d'; ! has_remote m1 && ! has_remote m3"
check 'hung push: m2 stays and is reported as timed out' grep -Eq 'timed out after 2s' "$d/out"
check 'hung push: exit is non-zero' test "$(rc)" != 0

# 7. The overall limit ends the run even when every call hangs.
fixture
start=$SECONDS
ORCA_HANG_ON='.' WRAP_UP_CALL_TIMEOUT=2 WRAP_UP_TOTAL_TIMEOUT=3 run
check 'overall limit: the run ends inside it, with slack' test $((SECONDS-start)) -lt 30
check 'overall limit: reported' grep -Eq 'overall time limit' "$d/out"
check 'overall limit: exit is non-zero' test "$(rc)" != 0

# 8. The last copy of unmerged work stays, local or remote.
fixture
git checkout -q -b lc-remote main; echo a > a; git add a; git commit -qm 'only on origin'; git push -q origin lc-remote
git checkout -q -b lc-local main; echo b > b; git add b; git commit -qm 'only here'
git checkout -q main; git branch -q -D lc-remote
sha_remote=$(git rev-parse origin/lc-remote); sha_local=$(git rev-parse lc-local)
FAKE_PRS=$(printf '[{"headRefName":"lc-remote","headRefOid":"%s","state":"CLOSED"},{"headRefName":"lc-local","headRefOid":"%s","state":"CLOSED"}]' "$sha_remote" "$sha_local")
export FAKE_PRS
run
check 'last copy: unmerged branch only on origin stays' bash -c "$(declare -f has_remote); real_git='$real_git'; d='$d'; has_remote lc-remote"
check 'last copy: unmerged branch only local stays' bash -c "$(declare -f has_local); d='$d'; has_local lc-local"
check 'last copy: merged branches were still cleaned' bash -c "$(declare -f has_local); d='$d'; ! has_local m3"
check 'last copy: keeping is not a failure' test "$(rc)" = 0
check 'last copy: named in the output' grep -Eq 'Kept remote lc-remote \(last copy' "$d/out"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
