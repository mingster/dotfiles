#!/usr/bin/env bash
# Exercise wrap-up --apply rules (patch-merged, screenshot dirt, stale) in disposable repos only.
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
test "$*" = 'pr list --state all --limit 1000 --json headRefName,headRefOid,state' || exit 1
printf '%s\n' "$FAKE_PRS"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'orchestration worker-list --json') echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FAKE_PRS='[]'
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -qu origin main

old='2020-01-01T00:00:00Z'
# branch NAME FILE [DATE]: a branch with one commit, pushed, no worktree.
branch() {
  git checkout -q -b "$1" main
  echo "$1" > "$2"; git add "$2"
  GIT_AUTHOR_DATE=${3:-} GIT_COMMITTER_DATE=${3:-} git commit -qm "work on $1" ${3:+--date "$3"}
  git push -q origin "$1"
  git checkout -q main
}
branch squashed s.txt
branch open-pr o.txt "$old"
branch stale-old st.txt "$old"
branch stale-shot sh.txt "$old"
branch stale-dirty sd.txt "$old"
branch fresh f.txt
# Squash merge: same patch, new sha.
git cherry-pick -x squashed >/dev/null 2>&1 || git cherry-pick squashed >/dev/null
git commit -q --amend -m 'squash squashed'
git push -q origin main
git worktree add -q "$tmp/wt-squashed" squashed
git worktree add -q "$tmp/wt-stale-shot" stale-shot
git worktree add -q "$tmp/wt-stale-dirty" stale-dirty
git worktree add -q --detach "$tmp/wt-shot-merged" main
printf x > "$tmp/wt-shot-merged/shot.png"
printf x > "$tmp/wt-stale-shot/shot.PNG"
printf x > "$tmp/wt-stale-dirty/notes.txt"
FAKE_PRS=$(printf '[{"headRefName":"open-pr","headRefOid":"%s","state":"OPEN"}]' "$(git rev-parse open-pr)")
export FAKE_PRS

passed=0; failed=0
check() { # description, command...
  local d=$1; shift
  if "$@"; then printf 'ok %s\n' "$d"; passed=$((passed+1)); else printf 'FAIL %s\n' "$d"; failed=$((failed+1)); fi
}
has_local() { git show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { git ls-remote --exit-code --heads origin "$1" >/dev/null; }
gone() { ! has_local "$1" && ! has_remote "$1"; }
kept() { has_local "$1" && has_remote "$1"; }

bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/out1" 2>&1
check 'squash-merged branch with no PR deleted local and remote' gone squashed
check 'its clean worktree removed' test ! -d "$tmp/wt-squashed"
check 'screenshot-only detached worktree at merged head removed' test ! -d "$tmp/wt-shot-merged"
check 'open PR branch kept' kept open-pr
check 'unmerged old branch kept by --apply' kept stale-old
check 'stale section printed' grep -Fxq 'Stale (needs a decision)' "$tmp/out1"
check 'stale line has branch, age and subject' grep -Eq '^  stale-old, [0-9]+h old, work on stale-old$' "$tmp/out1"
check 'open PR branch not listed as stale' bash -c "! grep -q 'open-pr, ' '$tmp/out1'"
check 'fresh unmerged branch kept and not stale' bash -c "git show-ref --verify --quiet refs/heads/fresh && ! grep -q 'fresh, ' '$tmp/out1'"
check 'dirty worktree branch kept and not stale' bash -c "git show-ref --verify --quiet refs/heads/stale-dirty && test -d '$tmp/wt-stale-dirty' && ! grep -q 'stale-dirty, ' '$tmp/out1'"
check 'stale branch with screenshot-only worktree listed' grep -Eq '^  stale-shot, ' "$tmp/out1"

bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply --stale > "$tmp/out2" 2>&1
check '--stale deletes stale branch local and remote' gone stale-old
check '--stale deletes stale branch with screenshot-only worktree' gone stale-shot
check '--stale removed that worktree' test ! -d "$tmp/wt-stale-shot"
check '--stale keeps open PR branch' kept open-pr
check '--stale keeps fresh branch' kept fresh
check '--stale keeps dirty worktree branch' kept stale-dirty

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
