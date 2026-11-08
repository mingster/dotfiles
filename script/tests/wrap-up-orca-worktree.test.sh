#!/usr/bin/env bash
# wrap-up must deregister Orca sidebar worktrees when it removes a git worktree, and respect pinned metadata.
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
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq "Remove orca record $d/extra" && ok 'dry-run proposes orca deregistration' \
  || bad 'dry-run proposes orca deregistration' "missing Remove orca record line"

fixture
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
[ ! -d "$d/extra" ] && ok 'apply removes git worktree' || bad 'apply removes git worktree' 'directory still exists'
grep -Fq "worktree rm --worktree path:$d/extra" "$ORCA_LOG" && ok 'apply calls orca worktree rm' \
  || bad 'apply calls orca worktree rm' "$(cat "$ORCA_LOG")"

fixture
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":true}]"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --dry-run 2>&1) || true
echo "$out" | grep -Fq 'pinned in Orca' && ok 'pinned Orca worktree kept' \
  || bad 'pinned Orca worktree kept' "$out"
[ -d "$d/extra" ] && ok 'pinned worktree not removed on dry-run preview path' || bad 'pinned kept on disk'

fixture
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false}]"
export ORCA_RM_FAIL="$d/extra"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err"; rc=$?
[ "$rc" -ne 0 ] && ok 'failed orca rm fails the run' || bad 'failed orca rm fails the run' "rc=$rc"
grep -Fq 'orca worktree rm' "$d/err" "$d/out" && ok 'failed orca rm reported' \
  || bad 'failed orca rm reported' "$(cat "$d/out" "$d/err")"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
