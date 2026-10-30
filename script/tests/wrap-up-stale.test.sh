#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Exercise stale cleanup only in disposable repositories with a local bare remote.
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
  'api repos/{owner}/{repo}/pages') echo '{"source":{"branch":"gh-pages"}}' ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]' ;;
  'pr list '*) echo '[{"headRefName":"open-pr","state":"OPEN"}]' ;;
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
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *"$LIVE_WORKTREE"*) echo 'live holder'; exit 0 ;; esac
exit 1
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" ORCA_CLI_COMMAND="$tmp/bin/orca"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export LIVE_WORKTREE="$tmp/live-worktree"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.name Test
git config user.email test@example.invalid
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -qu origin main
now=$(date +%s)
for entry in young:7 stale:9 open-pr:9 live:9; do
  name=${entry%:*}; hours=${entry#*:}
  git checkout -qb "$name" main
  echo "$name" > "$name.txt"
  git add "$name.txt"
  timestamp="$((now - hours * 3600)) +0000"
  GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" git commit -qm "$name work"
  git push -qu origin "$name"
done
git checkout -q main
git worktree add -q "$LIVE_WORKTREE" live
passed=0; failed=0
check() {
  local description=$1; shift
  if "$@"; then echo "ok $description"; passed=$((passed+1))
  else echo "FAIL $description"; failed=$((failed+1)); cat "$tmp/output"; fi
}
has_local() { git show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { git --git-dir="$tmp/origin" show-ref --verify --quiet "refs/heads/$1"; }
no_local() { ! has_local "$1"; }
no_remote() { ! has_remote "$1"; }
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check '9h branch deleted locally by apply without stale flag' no_local stale
check '9h branch deleted remotely by apply without stale flag' no_remote stale
for name in young open-pr live; do
  check "$name branch kept locally" has_local "$name"
  check "$name branch kept remotely" has_remote "$name"
done
check 'live worktree kept' test -d "$LIVE_WORKTREE"
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
