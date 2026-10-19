#!/usr/bin/env bash
# Exercise merge-cleanup.sh in a disposable repo with a bare remote. No network, no gh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh must not be called" >&2; exit 99
FAKE
# orca stub: worktree "$FAKE_RELEASED" belongs to a released worker.
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'orchestration worker-list'*)
    w=""; for p in $FAKE_RELEASED; do w="$w${w:+,}{\"dispatchId\":\"d\",\"dispatchStatus\":\"released\",\"worktreeId\":\"repo::$p\"}"; done
    printf '{"ok":true,"result":{"workers":[%s],"page":{"hasMore":false}}}\n' "$w" ;;
  *) printf '{"ok":true,"result":{"terminals":[]}}\n' ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca" MERGE_CLEANUP_REF_DIR="$tmp/_ref"
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2 2>/dev/null || true; exit 1; }
has_local() { git show-ref --verify --quiet "refs/heads/$1"; }
has_remote() { git --git-dir="$tmp/origin" show-ref --verify --quiet "refs/heads/$1"; }

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
echo initial > file; git add file; git commit -qm initial
git remote add origin "$tmp/origin"
git push -q -u origin main
commit_on() { # branch worktree-path file
  echo "$1" >> "$2/$3"; git -C "$2" add "$3"; git -C "$2" commit -qm "$1"
}
# PR head 38-head: merged into main, worktree clean, pushed.
git worktree add -qb mingster/38-head "$tmp/wt-head"
commit_on head "$tmp/wt-head" head.txt
git push -q origin mingster/38-head
git merge -q --no-ff mingster/38-head -m "Merge PR"
# lane A: same issue, merged into main via the head merge (ancestor), clean.
git worktree add -qb lane/38-a "$tmp/wt-a" main
git push -q origin lane/38-a
# lane B: same issue, NOT in main, worker released, clean.
git worktree add -qb lane/38-b "$tmp/wt-b" main
commit_on b "$tmp/wt-b" b.txt
git push -q origin lane/38-b
# lane C: same issue, dirty (staged + unstaged), worker released.
git worktree add -qb lane/38-c "$tmp/wt-c" main
echo staged > "$tmp/wt-c/s.txt"; git -C "$tmp/wt-c" add s.txt
echo more >> "$tmp/wt-c/file"
echo untracked-small > "$tmp/wt-c/new small.txt"
head -c 1100000 /dev/zero > "$tmp/wt-c/big.bin"
# Unrelated: 3848 must not match issue 38.
git worktree add -qb lane/3848-x "$tmp/wt-x" main
git push -q origin lane/3848-x
# Old recovery branch (8 days) and fresh one.
GIT_COMMITTER_DATE="$(date -v-8d +%s 2>/dev/null || date -d '8 days ago' +%s) +0000" \
  git -c user.name=T -c user.email=t@x commit-tree -m old "main^{tree}" -p main > "$tmp/oldsha"
git update-ref refs/heads/recovery/old "$(cat "$tmp/oldsha")"
git branch recovery/fresh
git push -q origin main
export FAKE_RELEASED="$tmp/wt-b $tmp/wt-c"

# DRY_RUN changes nothing.
refs_before=$(git for-each-ref; git --git-dir="$tmp/origin" for-each-ref)
DRY_RUN=1 bash "$here/merge-cleanup.sh" --branch mingster/38-head --issue 38 > "$tmp/dry"
[ "$refs_before" = "$(git for-each-ref; git --git-dir="$tmp/origin" for-each-ref)" ] || fail "dry run changed refs"
grep -q 'no fetch' "$tmp/dry" || fail "dry run did not say it skipped fetch"
has_local mingster/38-head && has_remote lane/38-b && [ -d "$tmp/wt-c" ] || fail "dry run deleted something"
[ ! -e "$tmp/_ref" ] || fail "dry run wrote patch"
# A remote ref added behind our back must not appear after a dry run (no fetch).
git clone -q --bare "$tmp/origin" "$tmp/other"
git --git-dir="$tmp/other" push -q origin main:refs/heads/surprise
DRY_RUN=1 bash "$here/merge-cleanup.sh" --branch mingster/38-head > /dev/null
git show-ref --verify --quiet refs/remotes/origin/surprise && fail "dry run fetched"
git --git-dir="$tmp/origin" update-ref -d refs/heads/surprise
echo 'ok dry run changes nothing'

bash "$here/merge-cleanup.sh" --branch mingster/38-head --issue 38 > "$tmp/out" 2>&1
for b in mingster/38-head lane/38-a lane/38-b lane/38-c recovery/old; do has_local "$b" && fail "local $b kept"; done
for b in mingster/38-head lane/38-a lane/38-b; do has_remote "$b" && fail "remote $b kept"; done
for d in wt-head wt-a wt-b wt-c; do [ -e "$tmp/$d" ] && fail "$d kept"; done
has_local lane/3848-x && has_remote lane/3848-x && [ -d "$tmp/wt-x" ] || fail "3848 lane touched"
has_local recovery/fresh && has_local main || fail "fresh recovery or main removed"
grep -q staged "$tmp/_ref/lane-38-c.patch" && grep -q '^+more' "$tmp/_ref/lane-38-c.patch" || fail "dirty patch missing staged or unstaged"
grep -q 'untracked-small' "$tmp/_ref/lane-38-c.patch" || fail "small untracked file not in patch"
grep -qx 'new small.txt' "$tmp/_ref/lane-38-c.untracked.txt" && grep -q 'big.bin (over 1 MB' "$tmp/_ref/lane-38-c.untracked.txt" || fail "untracked list wrong"
echo 'ok head, lanes cleaned, dirty saved to patch, 3848 and fresh recovery kept'

# A dirty PR head worktree is kept and printed.
git worktree add -qb mingster/50-head "$tmp/wt-d" main
git push -q origin mingster/50-head
echo wip > "$tmp/wt-d/w.txt"
bash "$here/merge-cleanup.sh" --branch mingster/50-head > "$tmp/out"
[ -d "$tmp/wt-d" ] && has_local mingster/50-head || fail "dirty head worktree removed"
grep -q 'Kept worktree.*wt-d' "$tmp/out" || fail "dirty head not printed"
echo 'ok dirty head worktree kept and printed'

# Protected branches and the current branch survive.
bash "$here/merge-cleanup.sh" --branch main > "$tmp/out" || true
has_local main && has_remote main || fail "main deleted"
echo 'ok main never deleted'

# If the patch cannot be saved, the dirty worktree stays.
git worktree add -qb lane/60-a "$tmp/wt-e" main
echo u > "$tmp/wt-e/u.txt"
touch "$tmp/blocker"
FAKE_RELEASED="$tmp/wt-e" MERGE_CLEANUP_REF_DIR="$tmp/blocker/sub" bash "$here/merge-cleanup.sh" --branch mingster/none --issue 60 > "$tmp/out" 2>&1
[ -d "$tmp/wt-e" ] && [ -f "$tmp/wt-e/u.txt" ] || fail "worktree removed though patch unsaved"
echo 'ok unsaved patch keeps worktree'

# Protected names match as heads, refs, origin/ refs and last path components.
GIT_COMMITTER_DATE="$(date -v-8d +%s 2>/dev/null || date -d '8 days ago' +%s) +0000" \
  git -c user.name=T -c user.email=t@x commit-tree -m old "main^{tree}" -p main > "$tmp/oldsha2"
for b in feature/main recovery/main production staging release/production; do
  git branch "$b" main; git push -q origin "$b"
done
git update-ref refs/heads/recovery/main "$(cat "$tmp/oldsha2")"
git branch wip/cur main; git branch lane/70/main main
git worktree add -q "$tmp/wt-cur" wip/cur
for h in feature/main recovery/main production origin/staging refs/heads/staging release/production; do
  bash "$here/merge-cleanup.sh" --branch "$h" > "$tmp/out" 2>&1 || fail "cleanup failed for $h"
  grep -q "protected: kept $h" "$tmp/out" || fail "no protected message for $h"
done
bash "$here/merge-cleanup.sh" --branch mingster/none --issue 70 > "$tmp/out" 2>&1 || true
grep -q 'protected: kept lane/70/main' "$tmp/out" && has_local lane/70/main || fail "ticket lane lane/70/main deleted"
for b in feature/main recovery/main production staging release/production; do
  has_local "$b" && has_remote "$b" || fail "protected $b deleted"
done
(cd "$tmp/wt-cur" && bash "$here/merge-cleanup.sh" --branch wip/cur > "$tmp/out" 2>&1) || fail "cleanup failed for current"
grep -q 'protected: kept wip/cur' "$tmp/out" && has_local wip/cur || fail "current branch deleted"
echo 'ok protected names, refs, origin/ and last components kept'

# The lead-queue worktree is never removed, even for a merged clean branch.
git worktree add -qb lane/80-lq "$tmp/lead-queue" main
git push -q origin lane/80-lq
bash "$here/merge-cleanup.sh" --branch lane/80-lq > "$tmp/out" 2>&1 || fail "cleanup failed for lead-queue"
[ -d "$tmp/lead-queue" ] && has_local lane/80-lq || fail "lead-queue worktree removed"
grep -q 'protected: kept worktree.*lead-queue' "$tmp/out" || fail "no lead-queue protected message"
echo 'ok lead-queue worktree kept'
# PR number matching: qa-<PR> lanes go, other numbers stay, whole-number only.
git worktree add -qb qa-345 "$tmp/wt-q1" main
git push -q origin qa-345
git worktree add -qb qa-346 "$tmp/wt-q2" main
git worktree add -qb qa-12345 "$tmp/wt-q3" main
git worktree add -qb qa-3450 "$tmp/wt-q4" main
git worktree add -qb qa-345-dirty "$tmp/wt-q5" main
echo wip > "$tmp/wt-q5/w.txt"
bash "$here/merge-cleanup.sh" --branch mingster/none --issue 9001 --pr 345 > "$tmp/out" 2>&1 || fail "pr cleanup failed"
has_local qa-345 || has_remote qa-345 || [ -d "$tmp/wt-q1" ] && fail "qa-345 kept"
for b in qa-346 qa-12345 qa-3450; do has_local "$b" || fail "$b wrongly removed"; done
[ -d "$tmp/wt-q2" ] && [ -d "$tmp/wt-q3" ] && [ -d "$tmp/wt-q4" ] || fail "non-matching worktree removed"
has_local qa-345-dirty && [ -d "$tmp/wt-q5" ] && fail "dirty qa-345-dirty not handled"
echo 'ok --pr matches qa-<PR> only as a whole number'
# Dirty PR lane that is released: patch saved, then removed (same as issue lanes).
export FAKE_RELEASED="$tmp/wt-q5"
bash "$here/merge-cleanup.sh" --branch mingster/none --pr 345 > "$tmp/out" 2>&1 || fail "dirty pr cleanup failed"
grep -q '^+wip' "$tmp/_ref/qa-345-dirty.patch" || fail "dirty qa-<PR> patch not saved"
echo 'ok dirty qa-<PR> saved as patch'
