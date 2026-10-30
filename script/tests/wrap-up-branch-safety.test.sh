#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Branch safety at the CLI boundary, using only disposable repositories and remotes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef')
    [ "${FAKE_DEFAULT_FAIL:-0}" = 0 ] || exit 1
    echo '{"defaultBranchRef":{"name":"trunk"}}' ;;
  'api repos/{owner}/{repo}/pages')
    [ "${FAKE_PAGES_FAIL:-0}" = 0 ] || { echo 'HTTP 403' >&2; exit 1; }
    echo '{"source":{"branch":"site-source"}}' ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100')
    [ "${FAKE_PROTECTION_FAIL:-0}" = 0 ] || exit 1
    printf '[{"name":"release","protected":true}]\n[{"name":"archive","protected":true}]\n' ;;
  'pr list '*)
    if [ -n "${FAKE_MOVE_OID:-}" ]; then
      git --git-dir="$FAKE_ORIGIN" update-ref refs/heads/moving "$FAKE_MOVE_OID"
      git --git-dir="$FAKE_ORIGIN" update-ref -d refs/heads/vanishing
    fi
    echo '[]' ;;
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
for name in trunk gh-pages site-source release archive disposable; do
  git branch "$name"
  git push -q origin "$name"
done
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
git worktree add -q "$tmp/site-wt" site-source
passed=0; failed=0
check() {
  local description=$1; shift
  if "$@"; then echo "ok $description"; passed=$((passed+1))
  else echo "FAIL $description"; failed=$((failed+1)); fi
}
has_local() { git show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { git --git-dir="$tmp/origin" show-ref --verify --quiet "refs/heads/$1"; }
no_local() { ! has_local "$1"; }
no_remote() { ! has_remote "$1"; }
not_planned() { ! grep -Fq "$1" "$tmp/output"; }
kept_reason() { grep -Eq "^Kept $1 $2 .*($3)" "$tmp/output"; }
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output" 2>&1
for name in trunk gh-pages site-source release archive; do
  check "plan keeps local $name with reason" kept_reason local "$name" 'default|Pages|protected'
  check "plan keeps remote $name with reason" kept_reason remote "$name" 'default|Pages|protected'
done
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply --stale > "$tmp/output" 2>&1
for name in trunk gh-pages site-source release archive; do
  check "apply keeps local $name" has_local "$name"
  check "apply keeps remote $name" has_remote "$name"
done
check 'Pages source worktree retained' test -d "$tmp/site-wt"
check 'ordinary merged branch removed locally' no_local disposable
check 'ordinary merged branch removed remotely' no_remote disposable
# A stale tracking ref must disappear before either mode builds a plan.
git push -q origin main:refs/heads/stale-tracking
git --git-dir="$tmp/origin" update-ref -d refs/heads/stale-tracking
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output" 2>&1
check 'dry run prunes stale remote tracking ref' bash -c '! git show-ref --verify --quiet refs/remotes/origin/stale-tracking'
check 'dry run does not plan a vanished remote' not_planned 'Delete remote stale-tracking'
git push -q origin main:refs/heads/stale-tracking
git --git-dir="$tmp/origin" update-ref -d refs/heads/stale-tracking
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'apply prunes stale remote tracking ref' bash -c '! git show-ref --verify --quiet refs/remotes/origin/stale-tracking'
# The API response arrives after fetch; simulate remote activity during that interval.
git push -q origin main:refs/heads/moving main:refs/heads/vanishing
moved=$(echo changed | git commit-tree 'HEAD^{tree}' -p HEAD)
git --git-dir="$tmp/origin" fetch -q "$tmp/repo" "$moved"
export FAKE_ORIGIN="$tmp/origin" FAKE_MOVE_OID="$moved"
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'branch moved after fetch survives apply' has_remote moving
check 'moved branch reports keep reason' kept_reason remote moving 'changed|moved'
check 'vanished branch reports keep reason' kept_reason remote vanishing 'gone|vanished'
check 'only successful remote deletes counted' grep -Fq 'deleted remote=0' "$tmp/output"
unset FAKE_MOVE_OID
# A write after ls-remote must also be rejected by the push lease.
git --git-dir="$tmp/origin" update-ref -d refs/heads/moving
git push -q origin main:refs/heads/a-race main:refs/heads/b-safe
mkdir -p "$tmp/gitshim"
REAL_GIT=$(command -v git)
export REAL_GIT FAKE_RACE_OID="$moved" FAKE_RACE_MARKER="$tmp/raced"
cat > "$tmp/gitshim/git" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'push origin --delete '*)
    if [ ! -e "$FAKE_RACE_MARKER" ]; then
      touch "$FAKE_RACE_MARKER"
      "$REAL_GIT" --git-dir="$FAKE_ORIGIN" update-ref refs/heads/a-race "$FAKE_RACE_OID"
    fi ;;
esac
exec "$REAL_GIT" "$@"
FAKE
chmod +x "$tmp/gitshim/git"
PATH="$tmp/gitshim:$PATH" bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'branch changed after live query survives push' has_remote a-race
check 'unchanged peer in failed batch is deleted on retry' no_remote b-safe
check 'retry counts only the successful deletion' grep -Fq 'deleted remote=1' "$tmp/output"
# The default branch fallback is independent of GitHub availability.
FAKE_DEFAULT_FAIL=1 bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output" 2>&1
check 'symbolic origin HEAD protects the default branch' kept_reason local trunk default
# Unknown protection or Pages metadata must retain otherwise eligible branches.
git branch metadata-unknown
git push -q origin metadata-unknown
FAKE_PROTECTION_FAIL=1 bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'failed protection discovery retains local branch' has_local metadata-unknown
check 'failed protection discovery retains remote branch' has_remote metadata-unknown
check 'failed protection discovery reports reason' kept_reason remote metadata-unknown unavailable
FAKE_PAGES_FAIL=1 bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'failed Pages discovery retains local branch' has_local metadata-unknown
check 'failed Pages discovery retains remote branch' has_remote metadata-unknown
# Protected branches must also be excluded from the unmerged --stale deletion path.
git checkout -q archive
echo archive > archive.txt
git add archive.txt
GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git commit -qm archived
git push -q origin archive
git checkout -q main
bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply --stale > "$tmp/output" 2>&1
check 'stale protected branch survives locally' has_local archive
check 'stale protected branch survives remotely' has_remote archive
check 'stale protected branch is not offered for deletion' not_planned 'Delete stale archive'
# Omit lsof from a hermetic tool path, even on hosts that install it in /usr/sbin.
mkdir -p "$tmp/no-lsof"
for tool in /bin/* /usr/bin/*; do
  case "${tool##*/}" in lsof|fuser) continue ;; esac
  [ ! -x "$tool" ] || ln -sf "$tool" "$tmp/no-lsof/${tool##*/}"
done
for tool in jq gh orca; do ln -sf "$(command -v "$tool")" "$tmp/no-lsof/$tool"; done
git branch idle-wt
git worktree add -q "$tmp/idle-wt" idle-wt
export WRAP_UP_CLONE_ROOT="$tmp/clones"
clone="$tmp/clones/com.google.Chrome.code_sign_clone/code_sign_clone.idle"
mkdir -p "$clone"
OSTYPE=linux-gnu WRAP_UP_TEST_PROC_ROOT="$tmp/no-proc" PATH="$tmp/no-lsof" /bin/bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'missing lsof keeps eligible worktree' test -d "$tmp/idle-wt"
check 'missing lsof keeps Chrome clone' test -d "$clone"
check 'missing lsof emits one counted summary line' grep -Fxq 'lsof unavailable: kept all worktrees=3 and Chrome clones=1' "$tmp/output"
check 'missing lsof summary appears exactly once' test "$(grep -c '^lsof unavailable:' "$tmp/output")" = 1
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
