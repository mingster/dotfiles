#!/usr/bin/env bash
# Finished Orca workers: remove idle worktrees when HEAD is on a remote; archive dirty scratch; fail closed on inventory loss.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export WRAP_UP_RECENT_MIN=0 HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_WT_ARCHIVE_ROOT="$tmp/wt-archive"
mkdir -p "$tmp/bin" "$HOME"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
test "$*" = 'pr list --state all --limit 1000 --json headRefName,headRefOid,state' || exit 1
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/lsof"
export PATH="$tmp/bin:$PATH" FAKE_PRS='[]'

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -q -u origin main

mkorca() {
  cat > "$tmp/bin/orca" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  'orchestration run-list'*) echo '{"ok":true,"result":{"runs":[],"page":{"hasMore":false}}}' ;;
  *'terminal list'*) echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *'worker-list'*) printf '%s\n' "\$WORKER_LIST_JSON" ;;
  *'worker-show'*) printf '%s\n' "\${WORKER_SHOW_JSON:-{\"ok\":true,\"result\":{\"state\":\"released\",\"liveness\":\"exited\"}}}" ;;
  *'worktree rm'*)
    echo "orca-worktree-rm \$*" >> "$tmp/orca-rm.log"
    [ "\${FAKE_ORCA_RM_FAIL:-0}" = 1 ] && exit 1
    for a in "\$@"; do case "\$a" in path:*) rm -rf "\${a#path:}" ;; esac; done
    exit 0 ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
FAKE
  chmod +x "$tmp/bin/orca"
  export ORCA_CLI_COMMAND="$tmp/bin/orca"
}

run_wrap() {
  bash "$root/script/wrap-up.sh" --repo "$tmp/repo" "$@" >"$tmp/out" 2>&1 || true
}

pass=0 fail=0
check() { # <description> <command...>
  local d=$1; shift
  if "$@"; then printf 'ok %s\n' "$d"; pass=$((pass+1))
  else printf 'FAIL %s\n' "$d"; fail=$((fail+1)); fi
}

# (a) Finished worker shape: idle, tip on remote, untracked scratch archived and removed on apply.
mkorca
export WORKER_LIST_JSON='{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
git worktree add -q -b on-remote "$tmp/wt-remote" main
git -C "$tmp/wt-remote" commit -q --allow-empty -m tip
git push -q origin on-remote
echo scratch > "$tmp/wt-remote/scratch.txt"
run_wrap --dry-run
check 'dry-run plans remote tip worktree removal' grep -Fq "Remove worktree $tmp/wt-remote" "$tmp/out"
check 'dry-run lists archive path for scratch' grep -Fq "Archive worktree $tmp/wt-remote to $tmp/wt-archive/repo_wt-remote" "$tmp/out"
run_wrap --apply
check 'apply removed remote tip worktree' test ! -d "$tmp/wt-remote"
check 'archive dir has patch' test -f "$tmp/wt-archive/repo_wt-remote/changes.patch"
check 'archive tarball has scratch' tar -xOf "$tmp/wt-archive/repo_wt-remote/scratch.tgz" scratch.txt
check 'orca worktree rm called' grep -q 'worktree rm' "$tmp/orca-rm.log"

# (b) Tip on no remote: kept as last copy.
mkorca
export WORKER_LIST_JSON='{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
git worktree add -q --detach "$tmp/wt-local" main
git -C "$tmp/wt-local" commit -q --allow-empty -m only-here
run_wrap --dry-run
check 'last copy kept on dry-run' grep -Fq 'commits not on any remote (last copy)' "$tmp/out"
set +e; run_wrap --apply; set -e
check 'last copy survives apply' test -d "$tmp/wt-local"

# (c) Live worker: kept.
mkorca
export WORKER_LIST_JSON="$(printf '{"ok":true,"result":{"workers":[{"dispatchId":"d-live","state":"ready","liveness":"live","workspace":"id::%s"}],"page":{"hasMore":false}}}' "$tmp/wt-live")"
export WORKER_SHOW_JSON="$(printf '{"ok":true,"result":{"dispatchId":"d-live","state":"ready","liveness":"live","workspace":"id::%s"}}' "$tmp/wt-live")"
git worktree add -q --detach "$tmp/wt-live" main
git push -q origin "$(git -C "$tmp/wt-live" rev-parse HEAD):refs/heads/live-tip"
run_wrap --worktrees-only --dry-run
check 'live worker worktree kept' bash -c "! grep -Fq 'Remove worktree $tmp/wt-live' '$tmp/out'"

# (d) Worker-list read fails: nothing removed.
mkorca
export WORKER_LIST_JSON=''
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  'orchestration run-list'*) echo '{"ok":true,"result":{"runs":[],"page":{"hasMore":false}}}' ;;
  *'terminal list'*) echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *worker-list*) exit 1 ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
FAKE
chmod +x "$tmp/bin/orca"
git worktree add -q --detach "$tmp/wt-inv" main
before=$(git -C "$tmp/repo" worktree list | wc -l | tr -d ' ')
run_wrap --dry-run
after=$(git -C "$tmp/repo" worktree list | wc -l | tr -d ' ')
check 'inventory failure keeps worktree count' test "$before" = "$after"
check 'inventory failure mentions retain' grep -Fq 'retaining all worktrees' "$tmp/out"

# Clean up wt-local, wt-live, wt-inv so later cases start only with their own worktrees.
rm -rf "$tmp/wt-local" "$tmp/wt-live" "$tmp/wt-inv"
git -C "$tmp/repo" worktree prune
real_git=$(command -v git)

# (e) git diff failing on a dirty published worktree keeps it ('archive failed') and nothing is removed.
mkorca
export WORKER_LIST_JSON='{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
git worktree add -q -b diff-fail "$tmp/wt-diff-fail" main
echo base > "$tmp/wt-diff-fail/tracked.txt"
git -C "$tmp/wt-diff-fail" add tracked.txt
git -C "$tmp/wt-diff-fail" commit -qm base
git push -q origin diff-fail
echo dirty >> "$tmp/wt-diff-fail/tracked.txt"
cat > "$tmp/bin/git" <<FAKE
#!/usr/bin/env bash
case "\$*" in *' diff HEAD'*) exit 1 ;; esac
exec "$real_git" "\$@"
FAKE
chmod +x "$tmp/bin/git"
run_wrap --apply
rm -f "$tmp/bin/git"
check 'git diff failure keeps dirty published worktree as archive failed' bash -c "grep -Fq 'dirty, archive failed' '$tmp/out' && test -d '$tmp/wt-diff-fail'"
rm -rf "$tmp/wt-diff-fail"
git -C "$tmp/repo" worktree prune

# (f) Staged plus unstaged change produces a patch that git apply --check accepts on a clean copy; spaced untracked file and existing dest preserved.
mkorca
export WORKER_LIST_JSON='{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
git worktree add -q -b patch-branch "$tmp/wt-patch" main
printf 'one\ntwo\nthree\n' > "$tmp/wt-patch/base.txt"
git -C "$tmp/wt-patch" add base.txt
git -C "$tmp/wt-patch" commit -qm base
git push -q origin patch-branch
printf 'ONE\ntwo\nthree\n' > "$tmp/wt-patch/base.txt"
git -C "$tmp/wt-patch" add base.txt
printf 'ONE\ntwo\nTHREE\n' > "$tmp/wt-patch/base.txt"
run_wrap --apply
git worktree add -q --detach "$tmp/wt-patch" origin/patch-branch
echo 'spaced scratch' > "$tmp/wt-patch/file with spaces.txt"
run_wrap --apply
git worktree add -q --detach "$tmp/wt-clean-copy" origin/patch-branch
patch_dir=''
for d in "$tmp/wt-archive"/repo_wt-patch-*; do [ -d "$d" ] && patch_dir=$d; done
check 'staged plus unstaged patch applies cleanly to clean copy' bash -c "git -C '$tmp/wt-clean-copy' apply --check '$tmp/wt-archive/repo_wt-patch/changes.patch' && test -n '$patch_dir' && tar -xOf '$patch_dir/scratch.tgz' 'file with spaces.txt' | grep -Fxq 'spaced scratch'"
rm -rf "$tmp/wt-patch" "$tmp/wt-clean-copy"
git -C "$tmp/repo" worktree prune

# (g) Fake orca records worktree rm before any git worktree remove, and when fake orca rm fails the git fallback removes it.
mkorca
export WORKER_LIST_JSON='{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
cat > "$tmp/bin/git" <<FAKE
#!/usr/bin/env bash
case "\$*" in *'worktree remove'*) echo "git-worktree-remove \$*" >> "$tmp/orca-rm.log" ;; esac
exec "$real_git" "\$@"
FAKE
chmod +x "$tmp/bin/git"
: > "$tmp/orca-rm.log"
git worktree add -q -b order-ok "$tmp/wt-order-ok" main
git -C "$tmp/wt-order-ok" commit -q --allow-empty -m tip1
git push -q origin order-ok
run_wrap --apply
cp "$tmp/orca-rm.log" "$tmp/orca-rm-ok.log"
: > "$tmp/orca-rm.log"
git worktree add -q -b order-fail "$tmp/wt-order-fail" main
git -C "$tmp/wt-order-fail" commit -q --allow-empty -m tip2
git push -q origin order-fail
FAKE_ORCA_RM_FAIL=1 run_wrap --apply
rm -f "$tmp/bin/git"
check 'orca worktree rm called before any git worktree remove and git fallback removes when orca rm fails' bash -c "head -n 1 '$tmp/orca-rm-ok.log' | grep -q '^orca-worktree-rm ' && ! grep -q '^git-worktree-remove ' '$tmp/orca-rm-ok.log' && test ! -d '$tmp/wt-order-ok' && head -n 1 '$tmp/orca-rm.log' | grep -q '^orca-worktree-rm ' && sed -n 2p '$tmp/orca-rm.log' | grep -q '^git-worktree-remove ' && test ! -d '$tmp/wt-order-fail'"

printf '%s passed, %s failed\n' "$pass" "$fail"
test "$fail" -eq 0
