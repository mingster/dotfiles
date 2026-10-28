#!/usr/bin/env bash
# Agent temp file cleanup: fake scratch tree, fake lsof, disposable repo only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo '[]'
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
# Fake lsof: reports a holder only for paths whose name contains "held".
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
for last; do :; done
case "$last" in *held*) echo 4242 ;; esac
exit 0
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/lsof"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main

scratch="$tmp/scratch"; loose="$tmp/loose"; state="$tmp/state"
export WRAP_UP_CLONE_ROOT="$tmp/none" WRAP_UP_SCRATCH_ROOT="$scratch" WRAP_UP_LOOSE_ROOT="$loose" WRAP_UP_STATE_DIR="$state"
export CLAUDE_CODE_SESSION_ID=mine
mkdir -p "$loose" "$state"
old='202001010000'
live_slug=$(printf '%s' "$tmp/repo" | sed 's/[^A-Za-z0-9]/-/g')
gone_slug=$(printf '%s' "$tmp/removed-worktree" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$scratch/$gone_slug/stale" "$scratch/$gone_slug/held-1" "$scratch/$gone_slug/mine" \
  "$scratch/$live_slug/fresh" "$scratch/$live_slug/aged" "$scratch/qa-old" "$scratch/qa-fresh" "$scratch/other-dir"
head -c 4096 /dev/zero > "$scratch/$gone_slug/stale/blob"
echo x > "$scratch/$gone_slug/held-1/blob"
echo x > "$scratch/$live_slug/aged/blob"
echo x > "$scratch/qa-old/blob"
touch -t "$old" "$scratch/$live_slug/aged/blob" "$scratch/$live_slug/aged" "$scratch/qa-old/blob" "$scratch/qa-old" "$scratch/other-dir"
echo x > "$loose/1234-old.log"; echo x > "$loose/5678-fresh.log"; echo x > "$loose/9012-old.sh"; echo x > "$loose/notes.txt"
echo x > "$loose/elon-wait.sh"; echo x > "$loose/elon-waiter.json"; echo x > "$state/elon-wait.sh"
touch -t "$old" "$loose/1234-old.log" "$loose/9012-old.sh" "$loose/notes.txt" "$loose/elon-wait.sh" "$loose/elon-waiter.json" "$state/elon-wait.sh"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
has() { grep -Fq -- "$1" "$tmp/output"; }
gone() { [ ! -e "$1" ]; }
cd "$tmp/repo"
refused=0
env -u WRAP_UP_SCRATCH_ROOT bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1 || refused=$?
check 'test mode refuses --apply without the temp root overrides' test "$refused" -eq 2
bash "$root/script/wrap-up.sh" --dry-run > "$tmp/output"
check 'dry run lists stale scratch dir with size' has "Remove temp $scratch/$gone_slug/stale ("
check 'dry run deletes nothing' test -d "$scratch/$gone_slug/stale" -a -f "$loose/1234-old.log" -a -d "$scratch/qa-old"
check 'dry run reports total bytes' has 'bytes='
bash "$root/script/wrap-up.sh" --apply > "$tmp/output"
check 'stale scratch dir of removed worktree deleted' gone "$scratch/$gone_slug/stale"
check 'old untouched dir of live worktree deleted' gone "$scratch/$live_slug/aged"
check 'held open dir kept' test -d "$scratch/$gone_slug/held-1"
check 'fresh dir of live worktree kept' test -d "$scratch/$live_slug/fresh"
check 'current session dir kept' test -d "$scratch/$gone_slug/mine"
check 'old qa dir deleted' gone "$scratch/qa-old"
check 'fresh qa dir kept' test -d "$scratch/qa-fresh"
check 'dir outside the inventory kept' test -d "$scratch/other-dir"
check 'old numbered log deleted' gone "$loose/1234-old.log"
check 'old numbered script deleted' gone "$loose/9012-old.sh"
check 'fresh numbered log kept' test -f "$loose/5678-fresh.log"
check 'unrelated old file kept' test -f "$loose/notes.txt"
check 'old waiter files in the loose root kept' test -f "$loose/elon-wait.sh" -a -f "$loose/elon-waiter.json"
check 'waiter in the state dir kept' test -f "$state/elon-wait.sh"
check 'counts report temp items' has 'temp removed=5 kept='
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
