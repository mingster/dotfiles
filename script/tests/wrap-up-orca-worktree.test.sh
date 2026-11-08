#!/usr/bin/env bash
# wrap-up must deregister Orca sidebar worktrees when it removes a git worktree, clean orphan entries, and respect pinned metadata.
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
here="$root/script"
tmp=$(mktemp -d); tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
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
case "$*" in
  'worktree list --json')
    printf '{"ok":true,"result":{"worktrees":%s}}\n' "${FAKE_ORCA_WORKTREES:-[]}"
    ;;
  'worktree rm --worktree path:'*)
    path=""
    for a in "$@"; do case "$a" in path:*) path="${a#path:}" ;; esac; done
    case " ${ORCA_RM_FAIL:-} " in
      *" $path "*) echo "orca rm failed" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
passed=0; failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed+1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=$((failed+1)); }

fixture() {
  d="$tmp/repo$n"; n=$((n+1))
  mkdir -p "$d"
  export ORCA_LOG="$d/orca.log"; : > "$ORCA_LOG"
  unset ORCA_RM_FAIL
  export FAKE_PRS='[]' FAKE_TERMINALS='[]' FAKE_ORCA_WORKTREES='[]'
  "$real_git" init -q --bare "$d/origin"
  "$real_git" init -q -b main "$d/wt"
  cd "$d/wt" || exit 1
  git config user.email t@example.invalid; git config user.name T
  git commit -qm initial --allow-empty
  git remote add origin "$d/origin"; git push -q -u origin main
  git branch merged; git push -q origin merged
  git worktree add -q "$d/extra" merged
  export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false}]"
}

n=0
fixture
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
[ ! -d "$d/extra" ] && ok 'apply removes git worktree' || bad 'apply removes git worktree' 'directory still exists'
grep -Fq "worktree rm --worktree path:$d/extra" "$ORCA_LOG" && ok 'apply calls orca worktree rm' \
  || bad 'apply calls orca worktree rm' "$(cat "$ORCA_LOG")"
grep -Fq 'removed worktrees=1 orca records=1' "$d/out" && ok 'apply counts orca records' \
  || bad 'apply counts orca records' "$(cat "$d/out")"

fixture
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":true}]"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq 'pinned in Orca' && ok 'pinned Orca worktree kept' \
  || bad 'pinned Orca worktree kept' "$out"
[ -d "$d/extra" ] && ok 'pinned worktree not removed on dry-run preview path' || bad 'pinned kept on disk'

fixture
mkdir -p "$tmp/workspaces/existing"
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false},{\"repoId\":\"repo-b\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/other-orphan\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/existing\",\"pinned\":false},{\"repoId\":\"repo-a\",\"hostId\":\"remote-1\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/remote-wt\",\"pinned\":false}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
grep -Fq "Remove orca record $tmp/workspaces/orphan (git worktree already gone)" "$d/out" && ok 'orphan Orca record reported' \
  || bad 'orphan Orca record reported' "$(cat "$d/out")"
grep -Fq "worktree rm --worktree path:$tmp/workspaces/orphan" "$ORCA_LOG" && ok 'orphan Orca record removed' \
  || bad 'orphan Orca record removed' "$(cat "$ORCA_LOG")"
grep -Fq "worktree rm --worktree path:$tmp/workspaces/other-orphan" "$ORCA_LOG" \
  && bad 'record with another repoId kept' "$(cat "$ORCA_LOG")" || ok 'record with another repoId kept'
grep -Fq "worktree rm --worktree path:$tmp/workspaces/existing" "$ORCA_LOG" \
  && bad 'record with existing dir kept' "$(cat "$ORCA_LOG")" || ok 'record with existing dir kept'
grep -Fq "worktree rm --worktree path:$tmp/workspaces/remote-wt" "$ORCA_LOG" \
  && bad 'record on another host kept' "$(cat "$ORCA_LOG")" || ok 'record on another host kept'
grep -Fq "worktree rm --worktree path:$d/wt" "$ORCA_LOG" \
  && bad 'isMainWorktree record kept' "$(cat "$ORCA_LOG")" || ok 'isMainWorktree record kept'

fixture
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-other\",\"isMainWorktree\":true,\"path\":\"$tmp/other-main\",\"pinned\":false},{\"repoId\":\"repo-other\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan2\",\"pinned\":false}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
grep -Fq "worktree rm --worktree path:$tmp/workspaces/orphan2" "$ORCA_LOG" \
  && bad 'orphan sweep skipped when no main record matches' "$(cat "$ORCA_LOG")" || ok 'orphan sweep skipped when no main record matches'
grep -Fq 'Orca orphan sweep skipped' "$d/out" && ok 'orphan sweep skip prints one line' \
  || bad 'orphan sweep skip prints one line' "$(cat "$d/out")"

fixture
export FAKE_ORCA_WORKTREES="[{\"repoId\":\"repo-a\",\"isMainWorktree\":true,\"path\":\"$d/wt\",\"pinned\":false},{\"repoId\":\"repo-a\",\"isMainWorktree\":false,\"path\":\"$tmp/workspaces/orphan\",\"pinned\":false}]"
export ORCA_RM_FAIL="$tmp/workspaces/orphan"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
[ "$rc" -ne 0 ] && ok 'failed orphan orca rm fails the run' || bad 'failed orphan orca rm fails the run' "rc=$rc"
grep -Fq 'orca worktree rm' "$d/err" "$d/out" && ok 'failed orphan orca rm reported' \
  || bad 'failed orphan orca rm reported' "$(cat "$d/out" "$d/err")"

fixture
export FAKE_ORCA_WORKTREES=''
cat > "$tmp/bin/orca-fail-list" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  'worktree list --json') exit 1 ;;
  'terminal list --json') printf '{"ok":true,"result":{"terminals":[]}}\n' ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/orca-fail-list"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca-fail-list"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq "Remove worktree $d/extra" && bad 'no removal when orca worktree list fails' "$out" \
  || ok 'no removal when orca worktree list fails'
echo "$out" | grep -Fq 'Orca pin lookup failed' && ok 'kept when orca pin lookup failed' \
  || bad 'kept when orca pin lookup failed' "$out"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
