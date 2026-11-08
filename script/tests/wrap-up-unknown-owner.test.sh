#!/usr/bin/env bash
# Issue 551: a fleet host (--worktrees-only) closes terminals too, and a terminal with no dispatch and no running
# agent is closed, so its worktree can go. Live, dirty and unclear work stays. Disposable repo and fake Orca only.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/home"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
echo '[]'
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
args=("$@")
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s}}\n' "$(cat "$FAKE_DIR/terminals")" ;;
  *'terminal close'*)
    for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && h=${args[$((i+1))]}; done
    echo "$h" >> "$FAKE_DIR/closed.log"
    jq -c --arg h "$h" 'map(select(.handle != $h))' "$FAKE_DIR/terminals" > "$FAKE_DIR/t.tmp" && mv "$FAKE_DIR/t.tmp" "$FAKE_DIR/terminals" ;;
  *worker-show*) printf '{"ok":true,"result":{"dispatch":{"status":"dispatched"},"terminal":{"cwd":"%s"}}}\n' "$FAKE_LIVE_CWD" ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  *worker-list*) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false,"nextCursor":null}}}\n' "$(cat "$FAKE_DIR/workers")" ;;
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *'worktree rm'*) exit 0 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
printf '#!/usr/bin/env bash\necho init\n' > "$tmp/bin/ps"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export ORCA_CLI_COMMAND="$tmp/bin/orca" FAKE_DIR="$tmp/fake" ORCA_TERMINAL_HANDLE=t-own
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_WT_ARCHIVE_ROOT="$tmp/wt-archive" WRAP_UP_RECENT_MIN=0
export WRAP_UP_STATE_DIR="$tmp/no-state" WRAP_UP_RECENT_MIN=0

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
git commit -qm initial --allow-empty
git remote add origin "$tmp/origin"
git push -q -u origin main
for n in w-shell w-agent w-live w-dirty w-recent lead-x w-own; do git worktree add -q --detach "$tmp/$n" main; done
echo dirty > "$tmp/w-dirty/untracked"
now_ms=$(( $(date +%s) * 1000 ))
t() { # <handle> <worktree dir or path> <agentIdentity json> <lastOutputAt>
  printf '{"handle":"%s","title":"x","worktreePath":"%s","connected":true,"writable":true,"agentIdentity":%s,"lastOutputAt":%s}' "$1" "$2" "${3:-null}" "${4:-1}"
}
echo "[$(t t-own "$tmp/w-own"),$(t t-shell "$tmp/w-shell"),$(t t-agent "$tmp/w-agent" '"agent"'),$(t t-live "$tmp/w-live"),$(t t-dirty "$tmp/w-dirty"),$(t t-recent "$tmp/w-recent" null "$now_ms"),$(t t-lead "$tmp/lead-x"),$(t t-main "$tmp/repo")]" > "$FAKE_DIR/terminals"
printf '[{"agentTerminalHandle":"t-live","dispatchId":"d-live","dispatchStatus":"dispatched","projection":{"workspace":{"id":"r::%s"}}}]\n' "$tmp/w-live" > "$FAKE_DIR/workers"
export FAKE_LIVE_CWD="$tmp/w-live"

fail() { echo "FAIL $*"; cat "$tmp/output"; exit 1; }
bash "$here/wrap-up.sh" --worktrees-only --dry-run > "$tmp/output" 2> "$tmp/stderr"
[ ! -e "$FAKE_DIR/closed.log" ] || fail 'dry run closed a terminal'
grep -Fq 'Close terminal t-shell' "$tmp/output" || fail 'dry run does not plan to close the unowned shell'
echo 'ok fleet host dry run plans the unowned shell and closes nothing'

bash "$here/wrap-up.sh" --worktrees-only --apply > "$tmp/output" 2> "$tmp/stderr"
sort "$FAKE_DIR/closed.log" | cmp - <(printf '%s\n' t-dirty t-shell) || fail "wrong terminals closed: $(tr '\n' ' ' < "$FAKE_DIR/closed.log")"
[ ! -d "$tmp/w-shell" ] || fail 'worktree with only an unowned shell survived'
echo 'ok fleet host closes a terminal with no dispatch and no agent, then removes its worktree'

for keep in w-agent w-live w-recent lead-x w-own; do
  [ -d "$tmp/$keep" ] || fail "$keep was removed"
done
[ ! -d "$tmp/w-dirty" ] || fail 'dirty published worktree survived apply'
grep -Fq "Archive worktree $tmp/w-dirty" "$tmp/output" || fail 'dirty worktree archive missing'
for pair in 't-agent:running agent' 't-live:live dispatch' 't-recent:recent output' 't-lead:lead worktree' 't-own:own terminal' 't-main:main checkout'; do
  grep -Fq "Kept terminal ${pair%%:*} (local, ${pair#*:})" "$tmp/output" || fail "no kept reason for ${pair%%:*}"
done
grep -Fq "Kept worktree $tmp/w-agent (active or unknown Orca terminal)" "$tmp/output" || fail 'agent worktree reason missing'
echo 'ok running agent, live dispatch, recent output, lead, own, main checkout kept; dirty scratch archived off a published head'
