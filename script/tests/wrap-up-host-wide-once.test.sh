#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# WRAP_UP_SKIP_HOST_WIDE: a later repo in a scheduled round skips the host-wide sweeps; without it they all run.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
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
printf '#!/usr/bin/env bash\ntouch "%s/pane-ran"\n' "$tmp" > "$tmp/pane.sh"
chmod +x "$tmp/bin/"* "$tmp/pane.sh"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home" ORCA_LOG="$tmp/orca.log" WORKER_PANE_CLOSE="$tmp/pane.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/scratch" WRAP_UP_LOOSE_ROOT="$tmp/loose" WRAP_UP_CLONE_ROOT="$tmp/clones"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
clone="$tmp/clones/com.google.Chrome.code_sign_clone/code_sign_clone.stale"
loose="$tmp/loose/playwright-artifacts-old"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
plant() { rm -rf "$tmp/pane-ran" "$ORCA_LOG"; mkdir -p "$clone" "$loose"; touch -t 202001010000 "$loose"; : > "$ORCA_LOG"; }
cd "$tmp/repo"

plant
WRAP_UP_SKIP_HOST_WIDE=1 bash "$root/script/wrap-up.sh" --apply > "$tmp/out" 2>&1 || true
check 'skip: no environment or dispatch read' test "$(grep -c '^environment list\|^orchestration worker-show' "$ORCA_LOG")" -eq 0
check 'skip: Chrome clone stays' test -d "$clone"
check 'skip: loose temp item stays' test -d "$loose"
check 'skip: worker panes are not closed' test ! -e "$tmp/pane-ran"
check 'skip: no host-wide summary lines' test "$(grep -c '^Close ended worker panes' "$tmp/out")" -eq 0

plant
bash "$root/script/wrap-up.sh" --apply > "$tmp/out" 2>&1 || true
check 'default: environments are read once' test "$(grep -c '^environment list' "$ORCA_LOG")" -ge 1
check 'default: Chrome clone goes' test ! -e "$clone"
check 'default: loose temp item goes' test ! -e "$loose"
check 'default: worker panes are closed' test -e "$tmp/pane-ran"
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
