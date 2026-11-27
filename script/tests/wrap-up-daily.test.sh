#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# #1533: the daily disk cleanup (wrap-up.sh --daily). A dry run lists what it would delete; --apply keeps every worktree with
# uncommitted work, an open PR, a live terminal or a change in the last 3 hours, removes the rest, and clears build caches, old
# logs and package caches. #1853: the daily prune keeps only main, production, staging and active work, logs every delete for
# restore first, and only the coordinator host deletes origin branches. Disposable repos and a fake remote, fake orca, gh, brew
# and bun; never the real HOME.
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
  'pr list --state open '*) [ -z "${FAKE_GH_PR_FAIL:-}" ] || exit 1; jq '[.[] | select(.state == "OPEN")]' "$FAKE_DIR/prs.json" ;;
  'pr list '*) [ -z "${FAKE_GH_PR_FAIL:-}" ] || exit 1; cat "$FAKE_DIR/prs.json" ;;
  *) exit 1 ;;
esac
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') cat "$FAKE_DIR/terminals.json" ;;
  'status --json') echo '{"ok":true,"result":{"runtime":{"state":"ready"}}}' ;;
  'repo list --json') jq -n --arg p "$ROUND_REPO" --arg q "${ROUND_REPO_EXTRA:-}" '{ok:true,result:{repos:([$p, $q] | map(select(. != "") | {path:., kind:"git"}))}}' ;;
  'environment list --json') cat "$FAKE_DIR/envs.json" ;;
  'worktree list --environment peer --json') cat "$FAKE_DIR/peer-worktrees.json" ;;
  'orchestration worker-list --json') [ -z "${FAKE_ORCA_WORKERS_FAIL:-}" ] || exit 1; echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"worktrees":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
for tool in brew bun; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_DIR/tools.log"\nexit "${FAKE_%s_RC:-0}"\n' "$tool" "$(echo "$tool" | tr a-z A-Z)" > "$tmp/bin/$tool"
done
# Fake lsof: logs every call. A recursive +D scan walks node_modules and takes 10 s or more per worktree on a real host (#1533,
# niteking), so the daily round must not use it; one whole listing (-Fn) answers every worktree instead.
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/lsof.log"
for a in "$@"; do
  case "$a" in
    +D) exit 1 ;;
    -Fn) printf 'p4242\nn/dev/null\n'; [ ! -f "$FAKE_DIR/open-files" ] || sed 's/^/n/' "$FAKE_DIR/open-files"; exit 0 ;;
  esac
done
exit 1
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/ps"
# Fake git: FAKE_GIT_SLOW=1 makes every branch delete take a second, so a round can run out of time (#1923).
printf '#!/usr/bin/env bash\n[ -z "${FAKE_GIT_SLOW:-}" ] || [ "${1:-}" != branch ] || sleep 1\nexec %q "$@"\n' "$(command -v git)" > "$tmp/bin/git"
chmod +x "$tmp/bin/"*
export FAKE_DIR="$tmp" ROUND_REPO="$tmp/repo"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" ORCA_CLI_COMMAND="$tmp/bin/orca"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_EXTRA_BIN= WRAP_UP_ORCA_APP_BIN="$tmp/no-app" ORCA_TERMINAL_HANDLE=t-own
export WRAP_UP_DAILY_LOG="$tmp/round.log" WRAP_UP_WORKSPACES_ROOT="$tmp/workspaces" AGENT_STATE_DIR="$tmp/agent-state"
export WRAP_UP_SCHEDULED_LOAD_CMD='echo 0.1' WRAP_UP_SCHEDULED_CORES_CMD='echo 4' WRAP_UP_DAILY_BIG_LOG_KB=1
# #1923: a branch is deleted only when its tip is older than WRAP_UP_PRUNE_MIN_AGE (default 1 day). The older tests run with new
# branches, so they switch the rule off; the age tests at the end turn it back on.
export WRAP_UP_PRUNE_MIN_AGE=0
echo '[]' > "$tmp/prs.json"
echo '{"ok":true,"result":{"environments":[]}}' > "$tmp/envs.json"
echo '{"ok":true,"result":{"terminals":[]}}' > "$tmp/terminals.json"
# #1853: the prune runs only in the repos the private coordinator.conf lists as prune-repo.
prune_repos() { printf 'prune-repo %s\nprune-repo %s\n' "$tmp/repo" "$tmp/p"; }

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
g worktree add -q -b b-held "$tmp/wt-held" main
printf '%s\n' "$tmp/wt-held" > "$tmp/open-files" # a process whose cwd is the worktree
g worktree add -q -b b-unpushed "$tmp/wt-unpushed" main
git -C "$tmp/wt-unpushed" -c user.name=Test -c user.email=test@example.invalid commit -qm 'only here' --allow-empty
unpushed_sha=$(git -C "$tmp/wt-unpushed" rev-parse HEAD)
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
for n in merged dirty live held unpushed openpr squash moved; do
  wt="$tmp/wt-$n"; gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  find "$wt" "$gd" -exec touch -t "$old" {} +
  git -C "$wt" status --porcelain >/dev/null
  touch -t "$old" "$gd/HEAD" "$gd/index"
done

# An idle automation "Run now" leftover with no terminal left (#1946).
g worktree add -q -b t/auto-job-run-1-1 "$tmp/auto-job-run-1-1" main
auto_sha=$(git -C "$tmp/auto-job-run-1-1" rev-parse HEAD)
touch -t "$old" "$(git -C "$tmp/auto-job-run-1-1" rev-parse --absolute-git-dir)/HEAD"

# Logs: old and new in each place the job cleans, plus ones it must leave.
mkdir -p "$tmp/workspaces/proj" "$tmp/agent-state"
git -C "$tmp/agent-state" init -q
prune_repos > "$tmp/agent-state/coordinator.conf"
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

# Apply. A fake df answers one value before the round and another after it.
fake_df() { # <KB before> <KB after>
  rm -f "$tmp/df.seen"
  cat > "$tmp/bin/df" <<FAKE
#!/usr/bin/env bash
kb=$1; [ ! -e "$tmp/df.seen" ] || kb=$2; : > "$tmp/df.seen"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 %s 1%% /\n' "\$kb"
FAKE
  chmod +x "$tmp/bin/df"
}
fake_df 268120883 279235789
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'a round reports ok with free space before and after' grep -Eq 'wrap-up-daily \[[0-9]+\] round ok: repos=1 .* freed 10\.6G \(disk free 255\.7G -> 266\.3G\)' "$tmp/round.log"
check 'removes the merged worktree' gone "$tmp/wt-merged"
check 'removes the idle automation run worktree' gone "$tmp/auto-job-run-1-1"
check 'logs it as a cleaned automation run' detail_has "Cleaned automation run $tmp/auto-job-run-1-1"
check 'writes its branch to the restore log' grep -Fq "$(printf 'local\tt/auto-job-run-1-1\t%s' "$auto_sha")" "$tmp/agent-state/branch-prune/$(date +%F).log"
check 'removes the squash merged worktree (PR head not on any remote branch)' gone "$tmp/wt-squash"
check 'keeps a worktree with uncommitted work' present "$tmp/wt-dirty"
# #1853 replaced these two keeps: the prune removes work that is not active, and the restore log holds its sha.
check 'removes a worktree with unpushed commits (not active work, #1853)' gone "$tmp/wt-unpushed"
check 'logs the unpushed branch with its sha before the delete' grep -Fq "$(printf 'local\tb-unpushed\t%s' "$unpushed_sha")" "$tmp/agent-state/branch-prune/$(date +%F).log"
check 'keeps a worktree with an open PR' present "$tmp/wt-openpr"
check 'keeps a worktree with a live terminal' present "$tmp/wt-live"
check 'keeps a worktree a process holds a file open in' present "$tmp/wt-held"
check 'says a process holds it' grep -Fq "Kept worktree $tmp/wt-held (held open by a running process)" "$tmp/round-detail.log"
check 'never runs the slow recursive lsof +D scan' bash -c '! grep -Fq -- "+D" "$1"' _ "$tmp/lsof.log"
check 'asks lsof for the whole listing' grep -Fq -- '-Fn' "$tmp/lsof.log"
check 'keeps a worktree changed in the last 3 hours' present "$tmp/wt-fresh"
check 'removes a merged PR branch that moved on after the merge (not active work, #1853)' gone "$tmp/wt-moved"
check 'says why for each kept one' bash -c 'for r in "uncommitted changes" "open PR" "active or unknown Orca terminal" "changed in the last 180 minutes"; do grep -Fq -- "$r" "$1" || exit 1; done' _ "$tmp/round-detail.log"
check 'drops build caches in a kept worktree, top level and one level down' bash -c '! test -e "$1/node_modules/.cache" && ! test -e "$1/web/.next" && ! test -e "$1/web/node_modules/.cache"' _ "$tmp/wt-dirty"
check 'keeps node_modules itself' present "$tmp/wt-dirty/node_modules"
cp "$tmp/round.log" "$tmp/round-first.log"
fake_df 279235789 268120883
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'a round that freed nothing says freed 0.0G' bash -c 'tail -n 1 "$1" | grep -Fq "freed 0.0G (disk free 266.3G -> 255.7G)"' _ "$tmp/round.log"
rm -f "$tmp/bin/df"
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

# The 10 minute round is gone (#1533), so the coordinator's daily round also moves finished board cards to Done and cleans old ones.
board_conf="$tmp/coordinator.conf"; { printf 'coordinator %s\n' "$(hostname -s)"; prune_repos; } > "$board_conf"
for step in done clean; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_DIR/board-%s-calls"\nexit 0\n' "$step" > "$tmp/board-$step-stub"
done
chmod +x "$tmp/board-done-stub" "$tmp/board-clean-stub"
export BOARD_DONE_COORDINATOR_CONF="$board_conf" WRAP_UP_BOARD_DONE="$tmp/board-done-stub" WRAP_UP_BOARD_CLEAN="$tmp/board-clean-stub"
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'coordinator daily round runs board-done across the fleet' grep -Fq -- '--fleet --apply' "$tmp/board-done-calls"
check 'coordinator daily round cleans Done cards across the fleet' grep -Fq -- '--fleet --apply' "$tmp/board-clean-calls"
rm -f "$tmp/board-done-calls" "$tmp/board-clean-calls"
bash "$root/script/wrap-up.sh" --daily --dry-run > "$tmp/output" 2>&1
check 'coordinator daily dry run asks board-done not to set cards' grep -Fq -- '--fleet --dry-run' "$tmp/board-done-calls"
rm -f "$tmp/board-done-calls" "$tmp/board-clean-calls"
{ printf 'coordinator someone-else\n'; prune_repos; } > "$board_conf"
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'a non-coordinator daily round leaves the board alone' bash -c '! test -e "$1" && ! test -e "$2"' _ "$tmp/board-done-calls" "$tmp/board-clean-calls"
unset BOARD_DONE_COORDINATOR_CONF WRAP_UP_BOARD_DONE WRAP_UP_BOARD_CLEAN

# A second lock-free run is harmless and the daily lock is its own file.
check 'the daily round does not use the scheduled lock or log' bash -c '! test -e "$1/wrap-up-scheduled.lock" && ! test -e "$1/wrap-up-scheduled.failures"' _ "$tmp/state"

# A failing cleaner fails the round and counts toward the failure streak (it must not be reset first). With only 130 s of round
# budget left, a quick brew must not eat bun's share: the budget is elapsed time, not the cap.
rm -f "$tmp/tools.log"
rc=0; FAKE_BREW_RC=3 WRAP_UP_SCHEDULED_ROUND_LIMIT=130 bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
check 'a failed round ends non-zero, so the automation end phase shows it (#1726)' test "$rc" -ne 0
check 'a failing cleaner fails the round' grep -Fq 'round failed: brew cleanup -s exit 3' "$tmp/round.log"
check 'the failure streak survives it' test "$(cat "$tmp/state/wrap-up-daily.failures" 2>/dev/null)" = 1
check 'bun still runs after a quick brew with little budget left' tool_called 'bun pm cache rm'
FAKE_BREW_RC=3 bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'a second failing round makes the streak two' test "$(cat "$tmp/state/wrap-up-daily.failures" 2>/dev/null)" = 2

# A cache cleaner that only runs out of time (exit 124) is not a failed round: the cache stays and the next day's run retries it (#1533).
rm -f "$tmp/state/wrap-up-daily.failures"
FAKE_BUN_RC=124 bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1
check 'a cleaner timeout does not fail the round' bash -c 'tail -n1 "$1" | grep -Fq "round ok"' _ "$tmp/round.log"
check 'a cleaner timeout leaves no failure streak' test ! -s "$tmp/state/wrap-up-daily.failures"
check 'a cleaner timeout is named in the round line' bash -c 'tail -n1 "$1" | grep -Fq "bun pm cache rm timed out"' _ "$tmp/round.log"

# #1726: board-clean timing out is reported in the round line, never silent, and does not fail the repo round. The board steps
# keep their share of the round: the repos get the round limit less the reserve.
rm -f "$tmp/state/wrap-up-daily.failures"
{ printf 'coordinator %s\n' "$(hostname -s)"; prune_repos; } > "$board_conf"
printf '#!/usr/bin/env bash\nexit 124\n' > "$tmp/board-clean-slow"; chmod +x "$tmp/board-clean-slow"
printf '#!/usr/bin/env bash\necho "$WRAP_UP_TOTAL_TIMEOUT" >> "$FAKE_DIR/child-limits"\nexit 0\n' > "$tmp/child-limit-probe"; chmod +x "$tmp/child-limit-probe"
rc=0
BOARD_DONE_COORDINATOR_CONF="$board_conf" WRAP_UP_BOARD_DONE="$tmp/board-done-stub" WRAP_UP_BOARD_CLEAN="$tmp/board-clean-slow" \
  WRAP_UP_SCHEDULED_WRAP_UP="$tmp/child-limit-probe" WRAP_UP_SCHEDULED_ROUND_LIMIT=300 WRAP_UP_SCHEDULED_BOARD_RESERVE=120 \
  bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
check 'a board-clean timeout does not fail the round' test "$rc" -eq 0
check 'a board-clean timeout is logged' grep -Fq 'board-clean exit 124' "$tmp/round.log"
check 'a board-clean timeout is named in the round line' bash -c 'tail -n1 "$1" | grep -Fq "round ok" && tail -n1 "$1" | grep -Fq "board-clean timed out"' _ "$tmp/round.log"
check 'a board-clean timeout leaves no failure streak' test ! -s "$tmp/state/wrap-up-daily.failures"
check 'the repo child leaves the board reserve out of its limit' test "$(head -n1 "$tmp/child-limits")" -le 180

# #1853: the prune, in a repo of its own with a fake remote. Keep set: main, production, staging, an open PR head, a live
# worker's worktree, a dirty worktree, and (origin only) a branch checked out on a paired host. Everything else goes.
export ROUND_REPO="$tmp/p" BOARD_DONE_COORDINATOR_CONF="$board_conf" WRAP_UP_BOARD_DONE="$tmp/board-done-stub" WRAP_UP_BOARD_CLEAN="$tmp/board-clean-stub"
{ printf 'coordinator %s\n' "$(hostname -s)"; prune_repos; } > "$board_conf"
plog="$tmp/agent-state/branch-prune/$(date +%F).log"
rm -f "$plog"
git init -q --bare -b main "$tmp/p-origin"
git init -q -b main "$tmp/p"
pg() { git -C "$tmp/p" -c user.name=Test -c user.email=test@example.invalid "$@"; }
pg commit -qm p1 --allow-empty
pg remote add origin "$tmp/p-origin"
mkdir -p "$tmp/p/.agents"; : > "$tmp/p/.agents/head-checks.conf"
mkbr() { # <name> [push]: a branch with one commit of its own
  pg branch "$1" main; pg checkout -q "$1"; pg commit -qm "work on $1" --allow-empty; pg checkout -q main
  [ -z "${2:-}" ] || pg push -q origin "$1"
}
for b in staging production; do pg branch "$b" main; done
pg push -q origin main staging production
mkbr gone-local; mkbr gone-pushed push; mkbr master push; mkbr open-pr push; mkbr on-peer push
pg worktree add -q -b p-live "$tmp/p-wt-live" main
pg worktree add -q -b p-dirty "$tmp/p-wt-dirty" main; echo wip > "$tmp/p-wt-dirty/wip.txt"
pg worktree add -q -b p-old "$tmp/p-wt-old" main
gd=$(git -C "$tmp/p-wt-old" rev-parse --absolute-git-dir); find "$tmp/p-wt-old" "$gd" -exec touch -t "$old" {} +
git -C "$tmp/p-wt-old" status --porcelain >/dev/null; touch -t "$old" "$gd/HEAD" "$gd/index"
gone_local_sha=$(pg rev-parse gone-local)
jq -n --arg o "$(pg rev-parse open-pr)" '[{headRefName:"open-pr",headRefOid:$o,state:"OPEN"}]' > "$tmp/prs.json"
jq -n --arg p "$tmp/p-wt-live" '{ok:true,result:{terminals:[{handle:"t-live",cwd:$p}]}}' > "$tmp/terminals.json"
echo '{"ok":true,"result":{"environments":[{"id":"peer","name":"peer"}]}}' > "$tmp/envs.json"
echo '{"ok":true,"result":{"worktrees":[{"branch":"refs/heads/on-peer","path":"/elsewhere/on-peer"}],"hostScope":{"omittedHostIds":[]}}}' > "$tmp/peer-worktrees.json"
local_has() { git -C "$tmp/p" show-ref --verify --quiet "refs/heads/$1"; }
local_gone() { ! local_has "$1"; }
origin_has() { git -C "$tmp/p-origin" show-ref --verify --quiet "refs/heads/$1"; }
origin_gone() { ! origin_has "$1"; }
both_have() { local_has "$1" && origin_has "$1"; }

bash "$root/script/wrap-up.sh" --daily --dry-run > "$tmp/output" 2>&1 || true
check 'prune dry run lists a local branch with no PR' detail_has 'Delete local gone-local (not active work)'
check 'prune dry run lists an origin branch with no PR' detail_has 'Delete remote gone-pushed (not active work)'
check 'prune dry run deletes no branch' both_have gone-pushed
check 'prune dry run removes no worktree' present "$tmp/p-wt-old"
check 'prune dry run writes no restore log' gone "$plog"

rc=0; bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
check 'a prune with nothing failing exits 0' test "$rc" -eq 0
for b in main staging production open-pr; do check "keeps $b, local and origin" both_have "$b"; done
check 'keeps a live worker worktree' present "$tmp/p-wt-live"
check 'keeps the live worker branch' local_has p-live
check 'keeps a dirty worktree' present "$tmp/p-wt-dirty/wip.txt"
check 'keeps the dirty worktree branch' local_has p-dirty
check 'lists the dirty worktree it kept' detail_has "Kept worktree $tmp/p-wt-dirty (uncommitted changes)"
check 'keeps an origin branch checked out on a paired host' origin_has on-peer
check 'removes an idle clean worktree' gone "$tmp/p-wt-old"
check 'deletes a local branch with no PR, even unpushed' local_gone gone-local
check 'deletes an origin branch with no PR' origin_gone gone-pushed
check 'deletes master: not in the keep set' origin_gone master
check 'logs the local delete with its sha' grep -Fq "$(printf '\t%s\tlocal\tgone-local\t%s' "$tmp/p" "$gone_local_sha")" "$plog"
check 'logs the origin delete' grep -Fq "$(printf '\tremote\tgone-pushed\t')" "$plog"
check 'logs the removed worktree with its HEAD' grep -Fq "$(printf '\tworktree\t%s\t' "$tmp/p-wt-old")" "$plog"
check 'a logged branch restores from its sha' pg branch gone-local "$gone_local_sha"

# A delete that fails is listed and the run goes on: the other branches still go, and the round ends non-zero (#1726).
pg branch -D -q gone-local; mkbr stuck push; mkbr after-stuck push
printf '#!/usr/bin/env bash\nwhile read -r o n r; do [ "$r" != refs/heads/stuck ] || { echo no; exit 1; }; done\n' > "$tmp/p-origin/hooks/pre-receive"
chmod +x "$tmp/p-origin/hooks/pre-receive"
rc=0; bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
check 'a failed origin delete keeps that branch' origin_has stuck
check 'the run goes on past a failed delete' origin_gone after-stuck
check 'the failed delete is listed in the summary' detail_has 'remote stuck: delete failed'
check 'a failed delete ends the round non-zero' test "$rc" -ne 0
rm -f "$tmp/p-origin/hooks/pre-receive"; pg push -q origin --delete stuck; pg branch -D -q stuck 2>/dev/null || true

# Fail closed: a lookup it cannot read deletes nothing in the repo.
fail_closed() { # <branch> <label> [env assignment]
  mkbr "$1" push
  env ${3:+"$3"} bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
  check "$2: deletes nothing" both_have "$1"
  check "$2: says the prune stopped" detail_has 'prune stopped in this repo'
}
fail_closed fc-pr 'a failed PR lookup' FAKE_GH_PR_FAIL=1
fail_closed fc-workers 'a failed worker inventory' FAKE_ORCA_WORKERS_FAIL=1
mkdir -p "$(dirname "$plog")"; chmod 500 "$(dirname "$plog")"
fail_closed fc-log 'an unwritable restore log'
chmod 700 "$(dirname "$plog")"

# A paired host the coordinator cannot read stops origin deletes, not local ones.
echo '{"ok":false}' > "$tmp/peer-worktrees.json"
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'an unreadable paired host keeps every origin branch' origin_has fc-pr
check 'an unreadable paired host still prunes local branches' local_gone fc-pr

# A paired host reports hosts paired with it, not with the coordinator, as omitted (seen on the coordinator). The coordinator
# reads each of its own environments directly, so a remote's foreign omitted hosts do not stop origin deletes.
echo '{"ok":true,"result":{"worktrees":[],"hostScope":{"omittedHostIds":["runtime:foreign-a","runtime:foreign-b"]}}}' > "$tmp/peer-worktrees.json"
mkbr remote-foreign push; : > "$tmp/round-detail.log"
rc=0; bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
check 'a paired host omitting its own paired hosts does not block origin deletes' origin_gone remote-foreign
check 'and the round names no fleet unreadable failure' bash -c '! grep -Fq "fleet unreadable" "$1"' _ "$tmp/round-detail.log"
check 'and exits 0' test "$rc" -eq 0
# The local list still must cover every host: an omitted id that is no environment of this host stops origin deletes.
echo '{"ok":true,"result":{"worktrees":[],"hostScope":{"omittedHostIds":[]}}}' > "$tmp/peer-worktrees.json"
cat > "$tmp/orca-local-omits" <<FAKE
#!/usr/bin/env bash
if [ "\$*" = 'worktree list --json' ]; then echo '{"ok":true,"result":{"worktrees":[],"hostScope":{"omittedHostIds":["runtime:unknown"]}}}'; exit 0; fi
"$tmp/bin/orca" "\$@"
FAKE
chmod +x "$tmp/orca-local-omits"
printf '#!/usr/bin/env bash\nORCA_CLI_COMMAND=%q exec bash %q "$@"\n' "$tmp/orca-local-omits" "$root/script/wrap-up.sh" > "$tmp/child-local-omits"
mkbr local-omits push
WRAP_UP_SCHEDULED_WRAP_UP="$tmp/child-local-omits" bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'a local list omitting an unknown host still keeps every origin branch' origin_has local-omits
check 'and names the fleet unreadable' detail_has 'fleet unreadable'

# Scope: a third repo the conf does not list keeps every worktree and branch, while the listed repo is pruned in the same round.
git init -q --bare -b main "$tmp/x-origin"
git init -q -b main "$tmp/x"
xg() { git -C "$tmp/x" -c user.name=Test -c user.email=test@example.invalid "$@"; }
xg commit -qm x1 --allow-empty; xg remote add origin "$tmp/x-origin"; xg push -q origin main
mkdir -p "$tmp/x/.agents"; : > "$tmp/x/.agents/head-checks.conf"
xg branch x-gone main; xg checkout -q x-gone; xg commit -qm 'x work' --allow-empty; xg checkout -q main; xg push -q origin x-gone
xg worktree add -q -b x-old "$tmp/x-wt-old" main
git -C "$tmp/x-wt-old" -c user.name=Test -c user.email=test@example.invalid commit -qm "x only here" --allow-empty
gd=$(git -C "$tmp/x-wt-old" rev-parse --absolute-git-dir); find "$tmp/x-wt-old" "$gd" -exec touch -t "$old" {} +
git -C "$tmp/x-wt-old" status --porcelain >/dev/null; touch -t "$old" "$gd/HEAD" "$gd/index"
mkbr listed-gone push
ROUND_REPO_EXTRA="$tmp/x" bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'an unlisted repo keeps its local branch' xg show-ref --verify --quiet refs/heads/x-gone
check 'an unlisted repo keeps its origin branch' git -C "$tmp/x-origin" show-ref --verify --quiet refs/heads/x-gone
check 'an unlisted repo keeps its idle worktree with unpushed work' present "$tmp/x-wt-old"
check 'an unlisted repo writes nothing to the restore log' bash -c '! grep -Fq "$1" "$2"' _ "$(printf '\t%s\t' "$tmp/x")" "$plog"
check 'says the prune is off there' detail_has "prune off in $tmp/x (not a prune-repo in coordinator.conf)"
check 'the listed repo is still pruned in the same round' origin_gone listed-gone

# A fleet host (not the coordinator) prunes local branches and leaves origin to the coordinator.
echo '{"ok":true,"result":{"worktrees":[],"hostScope":{"omittedHostIds":[]}}}' > "$tmp/peer-worktrees.json"
{ printf 'coordinator someone-else\n'; prune_repos; } > "$board_conf"
mkbr fleet-only push
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'a fleet host deletes its local branch' local_gone fleet-only
check 'a fleet host leaves the origin branch to the coordinator' origin_has fleet-only

# #1923 part 2: component deploy branches (<component>/staging, <component>/production) are kept, local and origin, like the
# plain ones. Other branches under the same prefix still go.
{ printf 'coordinator %s\n' "$(uname -n | cut -d. -f1)"; prune_repos; } > "$board_conf"
export BOARD_DONE_COORDINATOR_CONF="$board_conf" WRAP_UP_BOARD_DONE="$tmp/board-done-stub" WRAP_UP_BOARD_CLEAN="$tmp/board-clean-stub"
mkbr web2/staging push; mkbr web2/production push; mkbr api/staging; mkbr web2/feature push
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'keeps <component>/staging, local and origin' both_have web2/staging
check 'keeps <component>/production, local and origin' both_have web2/production
check 'keeps a local only <component>/staging' local_has api/staging
check 'still deletes another branch under the component prefix (local)' local_gone web2/feature
check 'still deletes another branch under the component prefix (origin)' origin_gone web2/feature

# #1923 part 3: only a branch whose tip commit is older than a day goes (default 86400 s), local and origin.
unset WRAP_UP_PRUNE_MIN_AGE
mkbr_old() { # <name> [push]: like mkbr, but the tip commit is 2 days old
  pg branch "$1" main; pg checkout -q "$1"; GIT_COMMITTER_DATE=$(( $(date +%s) - 172800 ))" +0000" pg commit -qm "old work on $1" --allow-empty; pg checkout -q main
  [ -z "${2:-}" ] || pg push -q origin "$1"
}
mkbr age-new push; mkbr_old age-old push; mkbr age-new-local; mkbr_old age-old-local
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'keeps a branch whose tip is newer than a day, local and origin' both_have age-new
check 'keeps a local only branch whose tip is newer than a day' local_has age-new-local
check 'the old local branch is gone' local_gone age-old
check 'the old origin branch is gone' origin_gone age-old
check 'the old local only branch is gone' local_gone age-old-local
check 'says why the new one stays' detail_has 'Kept local age-new (tip newer than'
check 'the age is configurable: 0 deletes the new one too' bash -c 'WRAP_UP_PRUNE_MIN_AGE=0 bash "$1" --daily >/dev/null 2>&1; ! git -C "$2" show-ref --verify --quiet refs/heads/age-new-local' _ "$root/script/wrap-up.sh" "$tmp/p"

# #1923 part 1: a round that runs out of time still deletes some branches, logs them, and the next round carries on.
export WRAP_UP_PRUNE_MIN_AGE=0
for n in 1 2 3 4 5 6 7 8; do mkbr "slow-$n"; done
slow_left() { git -C "$tmp/p" for-each-ref --format='%(refname:strip=2)' 'refs/heads/slow-*' | wc -l | tr -d ' '; }
: > "$tmp/round-detail.log"
rc=0; FAKE_GIT_SLOW=1 WRAP_UP_PRUNE_STEP=3 bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || rc=$?
left=$(slow_left)
check 'a round out of time deletes some branches' test "$left" -lt 8
check 'a round out of time leaves the rest' test "$left" -gt 0
check 'a round out of time is not a failure' test "$rc" -eq 0
check 'a round out of time says the rest waits' detail_has 'prune stopped at its time limit'
check 'every deleted branch is in the restore log' test "$(grep -c "$(printf '\tlocal\tslow-')" "$plog")" -eq "$((8-left))"
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
check 'the next round deletes the rest' test "$(slow_left)" -eq 0
check 'and the restore log holds all eight' test "$(grep -c "$(printf '\tlocal\tslow-')" "$plog")" -eq 8

# #1923: a host without the hostname command still gets named (miniu has none). The coordinator match and the restore log use it.
printf '#!/usr/bin/env bash\necho "hostname: command not found" >&2\nexit 127\n' > "$tmp/bin/hostname"; chmod +x "$tmp/bin/hostname"
rm -f "$tmp/board-done-calls" "$plog"
mkbr nohost-branch
bash "$root/script/wrap-up.sh" --daily > "$tmp/output" 2>&1 || true
here=$(uname -n | cut -d. -f1)
check 'without hostname the coordinator is still recognised' grep -Fq -- '--fleet --apply' "$tmp/board-done-calls"
check 'without hostname the restore log names the host' grep -Fq "$(printf '\t%s\t%s\tlocal\tnohost-branch\t' "$here" "$tmp/p")" "$plog"
rm -f "$tmp/bin/hostname"
unset BOARD_DONE_COORDINATOR_CONF WRAP_UP_BOARD_DONE WRAP_UP_BOARD_CLEAN

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
