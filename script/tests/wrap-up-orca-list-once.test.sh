#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# #1314: a scheduled round lists Orca terminals once and each later repo asks only for its own worktrees.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d); tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
esac
echo '[]'
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ORCA_LOG"
case "$*" in
  'terminal list --json') if [ -n "${FAKE_TERMINALS:-}" ]; then printf '%s\n' "$FAKE_TERMINALS"; else echo '{"ok":true,"result":{"terminals":[]}}'; fi ;;
  'worktree list --repo '*) [ -z "${FAKE_SCOPED_SLOW:-}" ] || sleep 3; echo '{"ok":true,"result":{"worktrees":[],"page":{"hasMore":false}}}' ;;
  'orchestration run-list '*) echo '{"ok":true,"result":{"runs":[],"page":{"hasMore":false}}}' ;;
  'environment list --json') echo '{"ok":true,"result":{"environments":[]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"worktrees":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/lsof"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home" ORCA_LOG="$tmp/orca.log"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/scratch" WRAP_UP_LOOSE_ROOT="$tmp/loose" WRAP_UP_CLONE_ROOT="$tmp/clones"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
cd "$tmp/repo"
snap="$tmp/terminals.snap"
export WRAP_UP_SCHEDULED_CHILD=1 WRAP_UP_TERMINALS_SNAPSHOT="$snap"

: > "$ORCA_LOG"
bash "$root/script/wrap-up.sh" --apply > "$tmp/out1" 2>&1 || true
check 'first repo saves the terminal listing' test -s "$snap"
check 'first repo lists terminals once' test "$(grep -c '^terminal list' "$ORCA_LOG")" -eq 1
check 'first repo lists every worktree once' test "$(grep -c '^worktree list --json' "$ORCA_LOG")" -eq 1

# A terminal the first repo plans to close never reaches the shared listing (dry run closes nothing).
rm -f "$snap"
: > "$ORCA_LOG"
FAKE_TERMINALS='{"ok":true,"result":{"terminals":[{"handle":"t-gone","liveness":"exited","connected":false,"worktreePath":"'"$tmp"'/nowhere"},{"handle":"t-live","liveness":"alive","connected":true,"writable":true,"lastOutputAt":'"$(( $(date +%s) * 1000 ))"',"worktreePath":"'"$tmp"'/other"}]}}' \
  bash "$root/script/wrap-up.sh" > "$tmp/out0" 2>&1 || true
check 'planned close is reported' grep -q 'Close terminal t-gone' "$tmp/out0"
check 'shared listing omits a terminal the first repo closes' test "$(jq -r '[.result.terminals[].handle] | join(",")' "$snap")" = t-live

: > "$ORCA_LOG"
WRAP_UP_SKIP_HOST_WIDE=1 bash "$root/script/wrap-up.sh" --apply > "$tmp/out2" 2>&1 || true
check 'later repo does not list terminals' test "$(grep -c '^terminal list' "$ORCA_LOG")" -eq 0
check 'later repo lists only its own worktrees' grep -q "^worktree list --repo path:$tmp/repo --json" "$ORCA_LOG"
check 'later repo never lists every worktree' test "$(grep -c '^worktree list --json' "$ORCA_LOG")" -eq 0

# A scoped listing that times out is not retried with the whole list.
: > "$ORCA_LOG"
FAKE_SCOPED_SLOW=1 WRAP_UP_CALL_TIMEOUT=1 WRAP_UP_SKIP_HOST_WIDE=1 bash "$root/script/wrap-up.sh" --apply > "$tmp/out3" 2>&1 || true
check 'timed out scoped listing is tried once' test "$(grep -c '^worktree list --repo' "$ORCA_LOG")" -eq 1
check 'timed out scoped listing is not retried unscoped' test "$(grep -c '^worktree list --json' "$ORCA_LOG")" -eq 0
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
