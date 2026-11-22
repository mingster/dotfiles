#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# #1533: the daily disk cleanup (wrap-up.sh --daily). A dry run lists what it would delete; --apply keeps every worktree with
# uncommitted or unpushed work, an open PR, a live terminal or a change in the last 3 hours, removes a squash merged one, and
# clears build caches, old logs and package caches. Disposable repos, fake orca, gh, brew and bun; never the real HOME.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/Library/Logs" "$tmp/home/.orca/logs" "$tmp/state"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}' ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}' ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]' ;;
  'pr list '*) cat "$FAKE_DIR/prs.json" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') cat "$FAKE_DIR/terminals.json" ;;
  'status --json') echo '{"ok":true,"result":{"runtime":{"state":"ready"}}}' ;;
  'repo list --json') jq -n --arg p "$ROUND_REPO" '{ok:true,result:{repos:[{path:$p,kind:"git"}]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"worktrees":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
for tool in brew bun; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_DIR/tools.log"\n' "$tool" > "$tmp/bin/$tool"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export FAKE_DIR="$tmp" ROUND_REPO="$tmp/repo"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" ORCA_CLI_COMMAND="$tmp/bin/orca"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_EXTRA_BIN= WRAP_UP_ORCA_APP_BIN="$tmp/no-app" ORCA_TERMINAL_HANDLE=t-own
export WRAP_UP_DAILY_LOG="$tmp/round.log" WRAP_UP_WORKSPACES_ROOT="$tmp/workspaces" AGENT_STATE_DIR="$tmp/agent-state"
export WRAP_UP_SCHEDULED_LOAD_CMD='echo 0.1' WRAP_UP_SCHEDULED_CORES_CMD='echo 4' WRAP_UP_DAILY_BIG_LOG_KB=1
echo '[]' > "$tmp/prs.json"
echo '{"ok":true,"result":{"terminals":[]}}' > "$tmp/terminals.json"

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
g() { git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid "$@"; }
g commit -qm c1 --allow-empty
g remote add origin "$tmp/origin"
g push -qu origin main
mkdir -p "$tmp/repo/.agents"; : > "$tmp/repo/.agents/head-checks.conf"
# Orca runs the child with its own CLI, so a round in a test cannot reach the real host.
printf '#!/usr/bin/env bash\nORCA_CLI_COMMAND=%q exec bash %q "$@"\n' "$tmp/bin/orca" "$root/script/wrap-up.sh" > "$tmp/child"
export WRAP_UP_SCHEDULED_WRAP_UP="$tmp/child"

# Seven worktrees; each one is the only thing wrong with it.
for n in merged dirty live fresh; do g worktree add -q -b "b-$n" "$tmp/wt-$n" main; done
echo scratch > "$tmp/wt-dirty/notes.txt"
mkdir -p "$tmp/wt-dirty/node_modules/.cache" "$tmp/wt-dirty/web/.next" "$tmp/wt-dirty/web/node_modules/.cache"
echo x > "$tmp/wt-dirty/node_modules/.cache/a"; echo x > "$tmp/wt-dirty/web/.next/a"; echo x > "$tmp/wt-dirty/web/node_modules/.cache/a"
g worktree add -q -b b-unpushed "$tmp/wt-unpushed" main
git -C "$tmp/wt-unpushed" -c user.name=Test -c user.email=test@example.invalid commit -qm 'only here' --allow-empty
g worktree add -q -b b-openpr "$tmp/wt-openpr" main
git -C "$tmp/wt-openpr" -c user.name=Test -c user.email=test@example.invalid commit -qm 'in review' --allow-empty
git -C "$tmp/wt-openpr" push -q origin b-openpr
# Squash merged: the PR head was never on a remote branch now, and GitHub says MERGED at exactly this commit (the #1533 cause).
g worktree add -q -b b-squash "$tmp/wt-squash" main
git -C "$tmp/wt-squash" -c user.name=Test -c user.email=test@example.invalid commit -qm 'squashed away' --allow-empty
g worktree add -q -b b-moved "$tmp/wt-moved" main
git -C "$tmp/wt-moved" -c user.name=Test -c user.email=test@example.invalid commit -qm 'merged part' --allow-empty
moved_pr_head=$(git -C "$tmp/wt-moved" rev-parse HEAD)
git -C "$tmp/wt-moved" -c user.name=Test -c user.email=test@example.invalid commit -qm 'work after the merge' --allow-empty
jq -n --arg o "$(git -C "$tmp/wt-openpr" rev-parse HEAD)" --arg s "$(git -C "$tmp/wt-squash" rev-parse HEAD)" --arg m "$moved_pr_head" \
  '[{headRefName:"b-openpr",headRefOid:$o,state:"OPEN"},{headRefName:"b-squash",headRefOid:$s,state:"MERGED"},{headRefName:"b-moved",headRefOid:$m,state:"MERGED"}]' > "$tmp/prs.json"
jq -n --arg p "$tmp/wt-live" '{ok:true,result:{terminals:[{handle:"t-live",cwd:$p}]}}' > "$tmp/terminals.json"

# Age everything except wt-fresh past 3 hours. git status refreshes the index, so touch the git files again after it.
old=202601010000
for n in merged dirty live unpushed openpr squash moved; do
  wt="$tmp/wt-$n"; gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  find "$wt" "$gd" -exec touch -t "$old" {} +
  git -C "$wt" status --porcelain >/dev/null
  touch -t "$old" "$gd/HEAD" "$gd/index"
done

# Logs: old and new in each place the job cleans, plus ones it must leave.
mkdir -p "$tmp/workspaces/proj" "$tmp/agent-state"
git -C "$tmp/agent-state" init -q
echo l > "$tmp/home/Library/Logs/old.log"; echo l > "$tmp/home/Library/Logs/new.log"
echo l > "$tmp/home/.orca/logs/rotated.log.1"; echo l > "$tmp/home/.orca/logs/live.log"
echo l > "$tmp/agent-state/untracked.log"; echo l > "$tmp/agent-state/tracked.log"
git -C "$tmp/agent-state" add tracked.log
head -c 4096 /dev/zero > "$tmp/workspaces/proj/big-old.log"; head -c 4096 /dev/zero > "$tmp/workspaces/proj/big-fresh.log"
echo l > "$tmp/workspaces/proj/small-old.log"
touch -t "$old" "$tmp/home/Library/Logs/old.log" "$tmp/home/.orca/logs/rotated.log.1" "$tmp/home/.orca/logs/live.log" \
  "$tmp/agent-state/untracked.log" "$tmp/agent-state/tracked.log" "$tmp/workspaces/proj/big-old.log" "$tmp/workspaces/proj/small-old.log"

passed=0; failed=0
check() { if "${@:2}"; then echo "ok $1"; passed=$((passed+1)); else echo "FAIL $1"; failed=$((failed+1)); fi; }
out_has() { grep -Fq -- "$1" "$tmp/output"; }
out_lacks() { ! grep -Fq -- "$1" "$tmp/output"; }
present() { test -e "$1"; }
gone() { ! test -e "$1"; }
detail_has() { grep -Fq -- "$1" "$tmp/round-detail.log"; }
tool_called() { grep -Fq -- "$1" "$tmp/tools.log" 2>/dev/null; }

# Dry run: lists the work, deletes nothing, runs no cleaner.
bash "$root/script/wrap-up.sh" --daily --dry-run > "$tmp/output" 2>&1
check 'dry run lists the merged worktree it would remove' out_has "Remove worktree $tmp/wt-merged"
check 'dry run lists the squash merged worktree' out_has "Remove worktree $tmp/wt-squash"
check 'dry run lists the old log' out_has "Remove log $tmp/home/Library/Logs/old.log"
check 'dry run lists the cleaners' out_has '[dry-run] brew cleanup -s'
check 'dry run lists bun too' out_has '[dry-run] bun pm cache rm'
check 'dry run removes no worktree' present "$tmp/wt-merged"
check 'dry run removes no log' present "$tmp/home/Library/Logs/old.log"
check 'dry run runs no cleaner' bash -c '! test -e "$1"' _ "$tmp/tools.log"
check 'dry run lists the nested build cache' out_has "Remove build cache $tmp/wt-dirty/web/node_modules/.cache"
check 'dry run removes no build cache' present "$tmp/wt-dirty/node_modules/.cache"

# Apply.
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'a round reports ok with free space before and after' grep -Eq 'wrap-up-daily \[[0-9]+\] round ok: repos=1 .* free [0-9.]+G->[0-9.]+G' "$tmp/round.log"
check 'removes the merged worktree' gone "$tmp/wt-merged"
check 'removes the squash merged worktree (PR head not on any remote branch)' gone "$tmp/wt-squash"
check 'keeps a worktree with uncommitted work' present "$tmp/wt-dirty"
check 'keeps a worktree with unpushed commits' present "$tmp/wt-unpushed"
check 'keeps a worktree with an open PR' present "$tmp/wt-openpr"
check 'keeps a worktree with a live terminal' present "$tmp/wt-live"
check 'keeps a worktree changed in the last 3 hours' present "$tmp/wt-fresh"
check 'keeps a merged PR branch that moved on after the merge' present "$tmp/wt-moved"
check 'says why for each kept one' bash -c 'for r in "uncommitted changes" "commits not on any remote" "open PR" "active or unknown Orca terminal" "changed in the last 180 minutes"; do grep -Fq -- "$r" "$1" || exit 1; done' _ "$tmp/round-detail.log"
check 'drops build caches in a kept worktree, top level and one level down' bash -c '! test -e "$1/node_modules/.cache" && ! test -e "$1/web/.next" && ! test -e "$1/web/node_modules/.cache"' _ "$tmp/wt-dirty"
check 'keeps node_modules itself' present "$tmp/wt-dirty/node_modules"
check 'removes an old app log' gone "$tmp/home/Library/Logs/old.log"
check 'keeps a new app log' present "$tmp/home/Library/Logs/new.log"
check 'removes an old rotated Orca log' gone "$tmp/home/.orca/logs/rotated.log.1"
check 'keeps a live Orca log however old' present "$tmp/home/.orca/logs/live.log"
check 'removes an old untracked agent-state log' gone "$tmp/agent-state/untracked.log"
check 'keeps a tracked agent-state log' present "$tmp/agent-state/tracked.log"
check 'removes an old big log under the workspaces' gone "$tmp/workspaces/proj/big-old.log"
check 'keeps a big log written in the last 3 hours' present "$tmp/workspaces/proj/big-fresh.log"
check 'keeps an old log under the size limit' present "$tmp/workspaces/proj/small-old.log"
check 'runs brew cleanup -s' tool_called 'brew cleanup -s'
check 'runs bun pm cache rm' tool_called 'bun pm cache rm'

# A second lock-free run is harmless and the daily lock is its own file.
check 'the daily round does not use the scheduled lock or log' bash -c '! test -e "$1/wrap-up-scheduled.lock" && ! test -e "$1/wrap-up-scheduled.failures"' _ "$tmp/state"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
