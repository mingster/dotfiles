#!/usr/bin/env bash
# Exercise dry-run decisions through the CLI, with disposable Git repositories.
set -euo pipefail
# Fixture worktrees are all new; 0 turns the recent-activity guard off.
export WRAP_UP_RECENT_MIN=0
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
test -z "${FAKE_GH_FAIL:-}" || exit 1
test "$*" = 'pr list --state all --limit 1000 --json headRefName,headRefOid,state' || exit 1
printf '%s\n' "$FAKE_PRS"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  'orchestration run-list'*) echo '{"ok":true,"result":{"runs":[{"id":"r1","coordinator_handle":"coord"}],"page":{"hasMore":false}}}' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s,"truncated":false}}\n' "$FAKE_TERMINALS" ;;
  *'worker-list'*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *'worker-show'*) echo '{"ok":true,"result":{"state":"released","liveness":"exited"}}' ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca"
# Ignore the caller's global config without changing its HOME.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export FAKE_PRS='[]' FAKE_TERMINALS='[]'
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_STATE_DIR="$tmp/no-state"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
cd "$tmp/repo"
for name in merged dirty unpushed active-root 'active nested' closed merged-pr unpublished-pr unrelated reopened newer-head active-root-sibling; do
  git worktree add -q --detach "$tmp/$name" main
done
echo dirty > "$tmp/dirty/untracked"
for name in unpushed closed merged-pr unpublished-pr unrelated reopened; do
  git -C "$tmp/$name" commit -qm "$name" --allow-empty
done
git push -q origin "$(git -C "$tmp/closed" rev-parse HEAD):refs/heads/closed"
git push -q origin "$(git -C "$tmp/merged-pr" rev-parse HEAD):refs/heads/merged-pr"
git push -q origin "$(git -C "$tmp/unrelated" rev-parse HEAD):refs/heads/unrelated"
git push -q origin "$(git -C "$tmp/reopened" rev-parse HEAD):refs/heads/reopened"
git -C "$tmp/newer-head" checkout -q --detach "$(git -C "$tmp/closed" rev-parse HEAD)"
git -C "$tmp/newer-head" commit -qm newer --allow-empty
git push -q origin "$(git -C "$tmp/newer-head" rev-parse HEAD):refs/heads/newer-head"
git -C "$tmp/repo" commit -qm 'open pr head' --allow-empty
git push -q origin main
git worktree add -q --detach "$tmp/open-pr-image" main
: > "$tmp/open-pr-image/review.png"
mkdir -p "$tmp/active nested/subdir"
export FAKE_TERMINALS="[{\"handle\":\"coordinator\",\"cwd\":\"$tmp/active-root\",\"worktreePath\":\"$tmp/active-root\",\"connected\":true,\"writable\":true,\"agentIdentity\":{\"agent\":\"owner\"},\"lastOutputAt\":9999999999999},{\"handle\":\"worker\",\"cwd\":\"$tmp/active nested/subdir\",\"worktreePath\":\"$tmp/active nested/subdir\",\"connected\":true,\"writable\":true,\"agentIdentity\":{\"agent\":\"worker\"},\"lastOutputAt\":9999999999999}]"
FAKE_PRS=$(printf '[{"headRefName":"closed","headRefOid":"%s","state":"CLOSED"},{"headRefName":"merged-pr","headRefOid":"%s","state":"MERGED"},{"headRefName":"unpublished-pr","headRefOid":"%s","state":"CLOSED"}]' \
  "$(git -C "$tmp/closed" rev-parse HEAD)" "$(git -C "$tmp/merged-pr" rev-parse HEAD)" "$(git -C "$tmp/unpublished-pr" rev-parse HEAD)")
export FAKE_PRS
FAKE_PRS=$(jq --arg head "$(git -C "$tmp/reopened" rev-parse HEAD)" --arg open "$(git -C "$tmp/open-pr-image" rev-parse HEAD)" '. + [{headRefName:"reopened",headRefOid:$head,state:"CLOSED"},{headRefName:"reopened",headRefOid:$head,state:"OPEN"},{headRefName:"open-pr",headRefOid:$open,state:"OPEN"}]' <<< "$FAKE_PRS")
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --worktrees-only --dry-run > "$tmp/output"
passed=0; failed=0
expect() {
  if grep -Fxq -- "$1" "$tmp/output"; then
    printf 'ok %s\n' "$2"; passed=$((passed+1))
  else
    printf 'FAIL %s: missing %s\n' "$2" "$1"; failed=$((failed+1))
  fi
}
expect "Remove worktree $tmp/merged (detached at merged commit)" 'clean merged detached removal includes reason'
grep -Fq "Archive worktree $tmp/dirty" "$tmp/output" && grep -Fq "Remove worktree $tmp/dirty (archived scratch)" "$tmp/output" && { printf 'ok %s\n' 'dirty detached archived then removed'; passed=$((passed+1)); } || { printf 'FAIL %s\n' 'dirty detached archived then removed'; failed=$((failed+1)); }
expect "Kept worktree $tmp/unpushed (commits not on any remote (last copy))" 'unpushed detached kept'
expect "Kept worktree $tmp/active-root (active or unknown Orca terminal)" 'active coordinator at worktree root kept'
expect "Kept worktree $tmp/active nested (active or unknown Orca terminal)" 'active terminal in subdirectory kept'
expect "Remove worktree $tmp/closed (detached at published commit)" 'closed PR exact head eligible'
expect "Remove worktree $tmp/merged-pr (detached at published commit)" 'merged PR exact head eligible'
expect "Kept worktree $tmp/unpublished-pr (commits not on any remote (last copy))" 'PR head with no remote branch kept'
expect "Remove worktree $tmp/unrelated (detached at published commit)" 'remote head on origin is removable'
expect "Remove worktree $tmp/reopened (detached at published commit)" 'open PR state does not keep a published detached head'
expect "Remove worktree $tmp/newer-head (detached at published commit)" 'descendant published on origin is removable'
expect "Remove worktree $tmp/open-pr-image (detached at merged commit)" 'ignorable screenshot at published head is removed'
expect "Remove worktree $tmp/active-root-sibling (detached at merged commit)" 'terminal path prefix does not protect sibling'
for name in merged dirty unpushed active-root 'active nested' closed merged-pr unpublished-pr unrelated reopened newer-head active-root-sibling open-pr-image; do
  test -d "$tmp/$name" || { echo "FAIL dry run removed $name"; exit 1; }
done
echo "ok dry run preserves all fixture worktrees"
passed=$((passed+1))
# A failed gh lookup no longer blocks removal of heads already on a remote.
FAKE_GH_FAIL=1 bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --worktrees-only --apply > "$tmp/output-gh-fail" 2>&1 || true
test ! -d "$tmp/merged" || { echo "FAIL failed gh still removes merged head on origin"; exit 1; }
test -d "$tmp/unpublished-pr" || { echo "FAIL failed gh removed last copy"; exit 1; }
echo "ok failed gh still removes published heads and keeps last copies"
passed=$((passed+1))
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --worktrees-only --apply > "$tmp/output-apply" 2>&1 || true
test ! -d "$tmp/open-pr-image" || { echo "FAIL apply kept open PR head worktree at main"; exit 1; }
test ! -d "$tmp/merged" || { echo "FAIL apply kept merged worktree"; exit 1; }
echo "ok apply removes published detached worktrees including open PR heads at main"
passed=$((passed+1))
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
