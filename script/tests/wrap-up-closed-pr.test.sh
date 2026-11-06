#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# A local branch named by a closed PR is deleted only when every commit is on an origin ref. Disposable repos only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}' ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}' ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]' ;;
  'pr list '*) echo '[{"headRefName":"closed-extra","state":"CLOSED"},{"headRefName":"closed-clean","state":"CLOSED"},{"headRefName":"closed-wt","state":"CLOSED"}]' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" ORCA_CLI_COMMAND="$tmp/bin/orca"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.name Test
git config user.email test@example.invalid
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -qu origin main
for b in closed-extra closed-clean closed-wt; do
  git checkout -q -b "$b"; git commit -qm "$b work" --allow-empty; git push -q origin "$b"
done
git checkout -q closed-extra; git commit -qm 'after the PR closed' --allow-empty
git checkout -q main
# Another host pushed a commit to closed-extra after this host's extra commit: origin holds work that exists nowhere else.
other=$(git commit-tree "origin/closed-extra^{tree}" -p origin/closed-extra -m 'other host')
git push -q origin "$other:refs/heads/closed-extra"
# A clean linked worktree on a closed PR branch whose last commit was never pushed.
git worktree add -q "$tmp/wt-closed" closed-wt
git -C "$tmp/wt-closed" commit -qm 'unpushed work' --allow-empty
passed=0; failed=0
check() { if "${@:2}"; then echo "ok $1"; passed=$((passed+1)); else echo "FAIL $1"; failed=$((failed+1)); fi; }
has_local() { git show-ref --verify --quiet "refs/heads/$1"; }
no_local() { ! has_local "$1"; }
out_has() { grep -Fq -- "$1" "$tmp/output"; }

bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output" 2>&1
check 'preview keeps the closed PR branch with an extra commit, with the reason' out_has 'Kept local closed-extra (unpushed commits'
check 'preview does not plan to delete it' bash -c '! grep -Fq "Delete local closed-extra" "$1"' _ "$tmp/output"
check 'preview still plans the clean closed PR branch' out_has 'Delete local closed-clean (closed PR)'
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'apply keeps the branch with the extra commit' has_local closed-extra
check 'apply deletes the closed PR branch with nothing extra' no_local closed-clean

check 'apply keeps the worktree whose branch has an unpushed commit' test -d "$tmp/wt-closed"
check 'apply keeps that worktree branch' has_local closed-wt
check 'apply keeps the origin branch while its local branch is kept' git -C "$tmp/origin" show-ref --verify --quiet refs/heads/closed-extra
check 'apply deletes the origin branch of the clean closed PR branch' bash -c '! git -C "$1" show-ref --verify --quiet refs/heads/closed-clean' _ "$tmp/origin"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
