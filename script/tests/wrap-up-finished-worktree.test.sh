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
  *'worktree rm'*) echo "orca-worktree-rm \$*" >> "$tmp/orca-rm.log"; exit 0 ;;
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

printf '%s passed, %s failed\n' "$pass" "$fail"
test "$fail" -eq 0
