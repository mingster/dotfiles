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
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
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

: > "$ORCA_LOG"
WRAP_UP_SKIP_HOST_WIDE=1 bash "$root/script/wrap-up.sh" --apply > "$tmp/out2" 2>&1 || true
check 'later repo does not list terminals' test "$(grep -c '^terminal list' "$ORCA_LOG")" -eq 0
check 'later repo lists only its own worktrees' grep -q "^worktree list --repo path:$tmp/repo --json" "$ORCA_LOG"
check 'later repo never lists every worktree' test "$(grep -c '^worktree list --json' "$ORCA_LOG")" -eq 0
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
