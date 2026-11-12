#!/usr/bin/env bash
# wrap-up removes only worktrees whose Orca board status is completed; every other status stays.
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
    printf '{"ok":true,"result":{"worktrees":%s,"truncated":%s}}\n' "${FAKE_ORCA_WORKTREES:-[]}" "${FAKE_ORCA_TRUNCATED:-false}"
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
for status in in-progress in-review todo; do
  fixture
  export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false,\"workspaceStatus\":\"$status\"}]"
  out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --apply 2>&1) || true
  grep -Fq "Kept worktree $d/extra (Orca board status is not completed)" <<<"$out" && ok "$status worktree kept" \
    || bad "$status worktree kept" "$out"
  [ -d "$d/extra" ] && ok "$status worktree still on disk" || bad "$status worktree still on disk" 'removed'
  grep -Fq 'worktree rm' "$ORCA_LOG" && bad "$status worktree not deregistered" "$(cat "$ORCA_LOG")" || ok "$status worktree not deregistered"
done

fixture
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false,\"workspaceStatus\":\"completed\"}]"
bash "$here/wrap-up.sh" --repo "$d/wt" --apply >"$d/out" 2>"$d/err" || true
[ ! -d "$d/extra" ] && ok 'completed worktree removed' || bad 'completed worktree removed' "$(cat "$d/out")"
grep -Fq "worktree rm --worktree path:$d/extra" "$ORCA_LOG" && ok 'completed worktree deregistered' || bad 'completed worktree deregistered' "$(cat "$ORCA_LOG")"

# completed does not bypass the other checks: unpushed work is still the last copy.
fixture
git -C "$d/extra" commit -q --allow-empty -m local-only
export FAKE_ORCA_WORKTREES="[{\"path\":\"$d/extra\",\"pinned\":false,\"workspaceStatus\":\"completed\"}]"
out=$(bash "$here/wrap-up.sh" --repo "$d/wt" --apply 2>&1) || true
[ -d "$d/extra" ] && ok 'completed worktree with unpushed work kept' || bad 'completed worktree with unpushed work kept' "$out"

printf 'passed %s, failed %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
