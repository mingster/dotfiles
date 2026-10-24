#!/usr/bin/env bash
# Exercise dry-run decisions through the CLI, with disposable Git repositories.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
test "$*" = 'pr list --state all --limit 1000 --json headRefName,headRefOid,state' || exit 1
printf '%s\n' "$FAKE_PRS"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "$FAKE_TERMINALS" ;;
  'orchestration worker-list --json') echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca"
# Ignore the caller's global config without changing its HOME.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FAKE_PRS='[]' FAKE_TERMINALS='[]'
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
mkdir -p "$tmp/active nested/subdir"
export FAKE_TERMINALS="[{\"handle\":\"coordinator\",\"cwd\":\"$tmp/active-root\"},{\"handle\":\"worker\",\"cwd\":\"$tmp/active nested/subdir\"}]"
FAKE_PRS=$(printf '[{"headRefName":"closed","headRefOid":"%s","state":"CLOSED"},{"headRefName":"merged-pr","headRefOid":"%s","state":"MERGED"},{"headRefName":"unpublished-pr","headRefOid":"%s","state":"CLOSED"}]' \
  "$(git -C "$tmp/closed" rev-parse HEAD)" "$(git -C "$tmp/merged-pr" rev-parse HEAD)" "$(git -C "$tmp/unpublished-pr" rev-parse HEAD)")
export FAKE_PRS
FAKE_PRS=$(jq --arg head "$(git -C "$tmp/reopened" rev-parse HEAD)" '. + [{headRefName:"reopened",headRefOid:$head,state:"CLOSED"},{headRefName:"reopened",headRefOid:$head,state:"OPEN"}]' <<< "$FAKE_PRS")
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output"
passed=0; failed=0
expect() {
  if grep -Fxq -- "$1" "$tmp/output"; then
    printf 'ok %s\n' "$2"; passed=$((passed+1))
  else
    printf 'FAIL %s: missing %s\n' "$2" "$1"; failed=$((failed+1))
  fi
}
expect "Remove worktree $tmp/merged (detached at merged commit)" 'clean merged detached removal includes reason'
expect "Kept worktree $tmp/dirty (dirty)" 'dirty detached kept'
expect "Kept worktree $tmp/unpushed (detached with unmerged commits)" 'unpushed detached kept'
expect "Kept worktree $tmp/active-root (active or unknown Orca terminal)" 'active coordinator at worktree root kept'
expect "Kept worktree $tmp/active nested (active or unknown Orca terminal)" 'active terminal in subdirectory kept'
expect "Remove worktree $tmp/closed (detached at closed PR head)" 'closed PR exact head eligible'
expect "Remove worktree $tmp/merged-pr (detached at closed PR head)" 'merged PR exact head eligible'
expect "Kept worktree $tmp/unpublished-pr (detached with unmerged commits)" 'PR head with no remote branch kept'
expect "Kept worktree $tmp/unrelated (detached with unmerged commits)" 'remote head without finished PR kept'
expect "Kept worktree $tmp/reopened (detached with unmerged commits)" 'open PR overrides historical closed PR'
expect "Kept worktree $tmp/newer-head (detached with unmerged commits)" 'descendant of closed PR head kept'
expect "Remove worktree $tmp/active-root-sibling (detached at merged commit)" 'terminal path prefix does not protect sibling'
for name in merged dirty unpushed active-root 'active nested' closed merged-pr unpublished-pr unrelated reopened newer-head active-root-sibling; do
  test -d "$tmp/$name" || { echo "FAIL dry run removed $name"; exit 1; }
done
echo "ok dry run preserves all fixture worktrees"
passed=$((passed+1))
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
