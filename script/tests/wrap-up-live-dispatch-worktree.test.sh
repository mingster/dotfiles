#!/usr/bin/env bash
# A live dispatch keeps its worktree even when Orca lists no terminal for it (real shape: worker-list row with a
# workspace, no terminal). Disposable repo and fake Orca only.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
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
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal list'*) echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *worker-show*) printf '{"ok":true,"result":{"dispatchId":"d-live","state":"ready","liveness":"live","workspace":"wt-id::%s"}}\n' "$FAKE_LIVE_CWD" ;;
  *worker-list*) printf '{"ok":true,"result":{"workers":[{"dispatchId":"d-live","state":"ready","liveness":"live","workspace":"wt-id::%s"}],"page":{"hasMore":false}}}\n' "$FAKE_LIVE_CWD" ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\necho init\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_STATE_DIR="$tmp/no-state" WRAP_UP_RECENT_MIN=0

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -q -u origin main
for n in w-live w-idle; do git worktree add -q --detach "$tmp/$n" main; done
export FAKE_LIVE_CWD="$tmp/w-live"

fail() { echo "FAIL $*"; cat "$tmp/output"; exit 1; }
bash "$here/wrap-up.sh" --worktrees-only --dry-run > "$tmp/output" 2>&1
grep -Fq "Remove worktree $tmp/w-idle" "$tmp/output" || fail 'an idle worktree is not planned for removal, so the check below proves nothing'
echo 'ok an idle worktree is planned for removal'
grep -Fq "Remove worktree $tmp/w-live" "$tmp/output" && fail 'a live dispatch worktree is planned for removal'
echo 'ok a live dispatch with no terminal listed keeps its worktree'
