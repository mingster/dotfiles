#!/usr/bin/env bash
# Issue 855: scheduled wrap-up removed almost nothing. Thousands of releases of workers Orca had already released or retained
# spent the whole time limit, so terminal lists, the branch protection lookup and the environment worktree lists were all
# skipped. Fake orca, fake gh, disposable repos only; never the real HOME or Orca.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin" "$tmp/state"
export PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp"
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_ORCA_APP_BIN="$tmp/no-app" WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_RECENT_MIN=0
export ORCA_TERMINAL_HANDLE=t-own WORKER_PANE_CLOSE="$tmp/no-pane-script"
# The real pages API answers 404 for a repo without Pages: that means no Pages branch, not a failed lookup.
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[{"name":"main"}]'; exit 0 ;;
esac
echo '[]'
STUB
# Each worker-release takes a second, like a remote call does, and answers what the fixture says.
cat > "$tmp/bin/orca" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
case "$*" in
  'environment list --json') echo '{"ok":true,"result":{"environments":[{"id":"env-a"}]}}' ;;
  'terminal list --json'|'terminal list --environment env-a --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'orchestration run-list '*) echo '{"ok":true,"result":{"runs":[{"id":"run-1"}]}}' ;;
  'orchestration worker-list --run run-1 '*) cat "$FAKE_DIR/workers-local" ;;
  'orchestration worker-list '*) echo '{"ok":true,"result":{"workers":[]}}' ;;
  'orchestration worker-release --dispatch '*)
    sleep "${FAKE_RELEASE_SLEEP:-0}"
    cat "$FAKE_DIR/receipt"; exit "${FAKE_RELEASE_RC:-0}" ;;
  'worktree list --environment env-a --json') echo '{"ok":true,"result":{"worktrees":[{"repoId":"r1","hostId":"env-a","path":"/remote/wt","branch":"b"}]}}' ;;
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
echo '{"ok":true,"result":{"state":"released"}}' > "$tmp/receipt"

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
g() { git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid "$@"; }
g commit -qm c1 --allow-empty
g remote add origin "$tmp/origin"
g push -qu origin main

row() { # id terminalState terminal
  jq -n --arg id "$1" --arg ts "$2" --arg t "$3" \
    '{dispatchId:$id,state:"succeeded",liveness:"exited",workspace:"repo::/fixture/x"}
     + (if $ts == "" then {} else {terminalState:$ts} end) + (if $t == "" then {} else {terminal:$t} end)'
}
wrap() { jq -s '{ok:true,result:{workers:.}}'; }
fresh_worktree() { rm -rf "$tmp/wt-done"; g worktree prune; g worktree add -q --detach "$tmp/wt-done" main; }
run() { : > "$tmp/calls"; fresh_worktree; bash "$root/script/wrap-up.sh" --repo "$tmp/repo" "$@" > "$tmp/output" 2> "$tmp/errors" || echo "rc=$?" >> "$tmp/errors"; }
releases() { grep -c '^orchestration worker-release' "$tmp/calls" || true; }
fail() { echo "FAIL $1"; cat "$tmp/output" "$tmp/errors"; exit 1; }
clean_round() {
  ! grep -Fq 'terminal inventory incomplete' "$tmp/errors" || fail 'terminal inventory skipped'
  ! grep -Fq 'worktree list unavailable' "$tmp/errors" || fail 'environment worktree list skipped'
  ! grep -Fq 'branch protection lookup unavailable' "$tmp/output" || fail 'branch protection lookup skipped'
  ! grep -Fq 'time limit' "$tmp/output" "$tmp/errors" || fail 'time limit reached'
  grep -Fq 'Remove worktree' "$tmp/output" || fail 'merged worktree not removed'
}
export WRAP_UP_TOTAL_TIMEOUT=8 FAKE_RELEASE_SLEEP=1

# Items 1 to 3: rows the concise list shows with no terminal and no terminal state are already released. Asking for each
# again spent the time limit, so every later Orca and gh call was skipped and the merged worktree stayed.
{ for i in $(seq 1 12); do row "d-gone-$i" '' ''; done; row d-reclaim reclaimable t-1; } | wrap > "$tmp/workers-local"
run --apply
[ "$(releases)" = 1 ] || fail "released $(releases) workers, want only d-reclaim"
clean_round
echo 'ok 1 already released workers are not released again, so terminals, protection and worktrees are all read'
echo 'ok 2 a 404 from the pages API is no Pages branch, and the protection lookup runs'
echo 'ok 3 environment worktree lists are read in a scheduled sized time limit'

# Items 1 to 3, the guard: many real releases stop at half the time limit so the cleanup after them still runs.
{ for i in $(seq 1 12); do row "d-slow-$i" reclaimable "t-$i"; done; } | wrap > "$tmp/workers-local"
run --apply
[ "$(releases)" -lt 12 ] || fail 'releases did not stop at half the time limit'
grep -Fq 'releases used half the time limit' "$tmp/errors" || fail 'no warning for the stopped releases'
! grep -Fq 'terminal inventory incomplete' "$tmp/errors" || fail 'terminal inventory skipped after releases'
grep -Fq 'Remove worktree' "$tmp/output" || fail 'merged worktree not removed after releases'
echo 'ok 1 releases stop at half the time limit; the terminal and worktree steps still run'

# Item 4: a retained worker is Orca's final answer, so it is not asked again; an ok:true receipt counts as released.
export FAKE_RELEASE_SLEEP=0 FAKE_RELEASE_RC=1
{ row d-retained retained t-2; row d-ext reclaimable t-3; } | wrap > "$tmp/workers-local"
echo '{"ok":true,"result":{"state":"retained","reason":"external_terminal"}}' > "$tmp/receipt"
run --apply
! grep -Fq 'worker-release --dispatch d-retained' "$tmp/calls" || fail 'asked to release a retained worker again'
grep -Fq 'worker-release --dispatch d-ext' "$tmp/calls" || fail 'reclaimable worker not released'
! grep -Fq 'releasing d-ext' "$tmp/errors" || fail 'ok:true receipt counted as a failed release'
grep -Fxq 'workers released=1' "$tmp/output" || fail 'ok:true receipt not counted as released'
echo '{"ok":false,"result":{"state":"release_unknown"}}' > "$tmp/receipt"
run --apply
grep -Fq 'releasing d-ext on local failed' "$tmp/errors" || fail 'ok:false receipt not counted as failed'
echo 'ok 4 retained workers are left alone and an ok:true receipt counts as released'

# A dispatch homed on a host that is offline now cannot be shown. That keeps the path its row names, not every worktree.
cat > "$tmp/bin/orca" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'environment list --json') echo '{"ok":true,"result":{"environments":[]}}' ;;
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'orchestration run-list '*) echo '{"ok":true,"result":{"runs":[]}}' ;;
  'orchestration worker-show --dispatch d-away '*) echo '{"ok":false,"error":{"code":"remote_runtime_unavailable","message":"Could not connect to the remote Orca runtime."}}'; exit 5 ;;
  'orchestration worker-list '*) printf '{"ok":true,"result":{"workers":[{"dispatchId":"d-away","state":"ready","liveness":"live","workspace":"wt::%s"}]}}\n' "$FAKE_DIR/wt-away" ;;
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  *) exit 1 ;;
esac
STUB
g worktree add -q --detach "$tmp/wt-away" main
run --dry-run
grep -Fq 'worker-show failed for dispatch d-away on an unpaired host; skipped.' "$tmp/errors" || fail 'offline host dispatch not skipped'
grep -q '^Remove worktree .*wt-done' "$tmp/output" || fail 'an offline host kept every worktree'
! grep -q '^Remove worktree .*wt-away' "$tmp/output" || fail 'the offline dispatch lost the worktree its row names'
echo 'ok 1 a dispatch on an offline host keeps only its own worktree'
