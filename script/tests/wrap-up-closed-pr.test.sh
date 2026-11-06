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
  'pr list '*) echo '[{"headRefName":"closed-extra","state":"CLOSED"},{"headRefName":"closed-clean","state":"CLOSED"},{"headRefName":"closed-wt","state":"CLOSED"},{"headRefName":"closed-round","state":"CLOSED"}]' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'status --json') echo '{"ok":true,"result":{"runtime":{"state":"ready"}}}' ;;
  'repo list --json') jq -n --arg p "$ROUND_REPO" '{ok:true,result:{repos:[{path:$p,kind:"git"}]}}' ;;
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

# Test 5: one scheduled round keeps and lists the worktree with unpushed commits and removes a closed PR branch.
# The child gets ORCA_CLI_COMMAND back so this round cannot reach the real browsers or temp folders of the host running it.
# Its commits are all on another origin ref: a branch that is the last copy of its commits stays on origin.
git branch closed-round origin/closed-wt; git push -q origin closed-round
mkdir -p "$tmp/repo/.agents"; : > "$tmp/repo/.agents/head-checks.conf"
printf '#!/usr/bin/env bash\nORCA_CLI_COMMAND=%q exec bash %q "$@"\n' "$tmp/bin/orca" "$root/script/wrap-up.sh" > "$tmp/child"
ROUND_REPO="$tmp/repo" WRAP_UP_SCHEDULED_WRAP_UP="$tmp/child" WRAP_UP_SCHEDULED_LOG="$tmp/round.log" WRAP_UP_EXTRA_BIN= \
  WRAP_UP_ORCA_APP_BIN="$tmp/no-app" WRAP_UP_SCHEDULED_LOAD_CMD='echo 0.1' WRAP_UP_SCHEDULED_CORES_CMD='echo 4' \
  bash "$root/script/wrap-up.sh" --scheduled > "$tmp/output" 2>&1
check 'a scheduled round reports ok' grep -Fq 'round ok: repos=1' "$tmp/round.log"
check 'the round keeps the worktree with unpushed commits' test -d "$tmp/wt-closed"
check 'the round keeps its branch' has_local closed-wt
check 'the round lists it with the reason' grep -Eq "Kept .*(closed-wt|wt-closed).*\\(" "$tmp/round-detail.log"
check 'the round removes the closed PR branch' no_local closed-round
check 'the round removes it from origin' bash -c '! git -C "$1" show-ref --verify --quiet refs/heads/closed-round' _ "$tmp/origin"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
