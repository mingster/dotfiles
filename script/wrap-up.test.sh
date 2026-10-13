#!/usr/bin/env bash
# Exercise the public CLI in disposable repositories only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'orchestration worker-show'*) printf '%s\n' "$FAKE_SHOW" ;;
  *) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false}}}\n' "${FAKE_WORKERS:-[]}" ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
echo initial > file
git add file
git commit -qm initial
git remote add origin "$tmp/origin"
git push -q -u origin main
git branch merged
git push -q origin merged
bash "$here/wrap-up.sh" --apply > "$tmp/output"
if git show-ref --verify --quiet refs/heads/merged; then exit 1; fi
if git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/merged; then exit 1; fi
echo 'ok merged branch removed locally and remotely'
git checkout -qb unmerged
echo change >> file
git commit -qam unmerged
git push -q origin unmerged
git checkout -q main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
git show-ref --verify --quiet refs/heads/unmerged
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/unmerged
echo 'ok unmerged branch kept locally and remotely'
for branch in master staging production web2/topic feature/staging feature/production; do
  git branch "$branch"
  git push -q origin "$branch"
done
bash "$here/wrap-up.sh" --apply > "$tmp/output"
for branch in main master staging production web2/topic feature/staging feature/production; do
  git show-ref --verify --quiet "refs/heads/$branch"
  git --git-dir="$tmp/origin" show-ref --verify --quiet "refs/heads/$branch"
done
echo 'ok all protected branch patterns kept'
git worktree add -qb dirty "$tmp/dirty worktree"
git push -q origin dirty
echo dirty > "$tmp/dirty worktree/untracked"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -f "$tmp/dirty worktree/untracked"
git show-ref --verify --quiet refs/heads/dirty
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/dirty
echo 'ok dirty worktree and both branches kept'
git worktree add -qb finished "$tmp/finished worktree"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/finished worktree"
if git show-ref --verify --quiet refs/heads/finished; then exit 1; fi
echo 'ok clean merged worktree removed'
git worktree add -qb active "$tmp/active"
export FAKE_TERMINALS="[{\"worktreePath\":\"$tmp/active\"}]"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/active"
git show-ref --verify --quiet refs/heads/active
echo 'ok active Orca worktree kept'
git branch closed unmerged
git branch reopened unmerged
git push -q origin closed reopened
export FAKE_PRS='[{"headRefName":"closed","state":"CLOSED"},{"headRefName":"reopened","state":"CLOSED"},{"headRefName":"reopened","state":"OPEN"}]'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
if git show-ref --verify --quiet refs/heads/closed; then exit 1; fi
if git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/closed; then exit 1; fi
echo 'ok closed PR allows deleting unmerged local and remote branches'
git show-ref --verify --quiet refs/heads/reopened
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/reopened
echo 'ok open PR overrides historical closed PR'
mkdir -p "$HOME/.claude/skills/orca-team"
cat > "$HOME/.claude/skills/orca-team/worker-pane-close.sh" <<'FAKE'
#!/usr/bin/env bash
test "$#" -eq 0
touch "$HOME/panes-closed"
FAKE
git branch preview
git push -q origin preview
git worktree add -qb preview-wt "$tmp/preview"
git show-ref > "$tmp/refs-before"
git --git-dir="$tmp/origin" show-ref > "$tmp/origin-before"
git worktree list --porcelain > "$tmp/trees-before"
bash "$here/wrap-up.sh" > "$tmp/output"
git show-ref > "$tmp/refs-after"
git --git-dir="$tmp/origin" show-ref > "$tmp/origin-after"
git worktree list --porcelain > "$tmp/trees-after"
cmp "$tmp/refs-before" "$tmp/refs-after"
cmp "$tmp/origin-before" "$tmp/origin-after"
cmp "$tmp/trees-before" "$tmp/trees-after"
test ! -f "$HOME/panes-closed"
echo 'ok default dry run preserves branches worktrees and panes'
bash "$here/wrap-up.sh" --dry-run > "$tmp/output"
test ! -f "$HOME/panes-closed"
echo 'ok explicit dry run preserves panes'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -f "$HOME/panes-closed"
echo 'ok apply invokes pane cleanup without arguments'
git clone -q --branch main "$tmp/origin" "$tmp/updater"
git -C "$tmp/updater" config user.email test@example.invalid
git -C "$tmp/updater" config user.name Test
echo next >> "$tmp/updater/file"
git -C "$tmp/updater" commit -qam next
git -C "$tmp/updater" push -q origin main
before=$(git rev-parse HEAD)
echo dirty-main > dirty-main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test "$(git rev-parse HEAD)" = "$before"
echo 'ok dirty main checkout does not pull'
rm dirty-main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test "$(git rev-parse HEAD)" = "$(git --git-dir="$tmp/origin" rev-parse main)"
echo 'ok clean main fast forwards'
git worktree add -qb settled "$tmp/settled"
export FAKE_TERMINALS="[{\"handle\":\"ended\",\"worktreePath\":\"$tmp/settled\"}]"
export FAKE_WORKERS='[{"agentTerminalHandle":"ended","dispatchId":"ctx_done","dispatchStatus":"completed"}]'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/settled"
echo 'ok settled dispatch terminal does not block cleanup'
git worktree add -qb live "$tmp/live"
export FAKE_TERMINALS='[]'
export FAKE_WORKERS='[{"dispatchId":"ctx_live","dispatchStatus":"dispatched"}]'
export FAKE_SHOW="{\"result\":{\"dispatch\":{\"status\":\"dispatched\"},\"terminal\":{\"cwd\":\"$tmp/live\"}}}"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/live"
echo 'ok active worker-show cwd blocks cleanup'
echo '15 tests passed'  
