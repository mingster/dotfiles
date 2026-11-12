#!/usr/bin/env bash
# Issue 764: one test per item. Fake orca, fake gh, disposable repos only; never the real HOME or Orca.
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
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
if [ -f "$FAKE_DIR/prs" ]; then cat "$FAKE_DIR/prs"; else echo '[]'; fi
STUB
cat > "$tmp/bin/orca" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
env_of() { local prev=''; for a in "$@"; do [ "$prev" != --environment ] || { echo "$a"; return; }; prev=$a; done; }
e=$(env_of "$@")
case "$*" in
  'environment list --json') if [ -e "$FAKE_DIR/envs-truncated" ]; then echo '{"ok":true,"result":{"environments":[{"id":"env-a"}],"truncated":true}}'; exit 0; fi; echo '{"ok":true,"result":{"environments":[{"id":"env-a"}]}}' ;;
  'terminal list --json') cat "$FAKE_DIR/terminals-local" ;;
  'terminal list --environment env-a --json') cat "$FAKE_DIR/terminals-env" ;;
  'terminal close --terminal '*) echo "local ${*: -1}" >> "$FAKE_DIR/closed" ;;
  'terminal close --environment env-a --terminal '*) echo "env-a ${*: -1}" >> "$FAKE_DIR/closed" ;;
  'terminal show'*) exit 1 ;;
  'orchestration run-list --environment '*) if [ -e "$FAKE_DIR/runs-truncated" ]; then echo '{"ok":true,"result":{"runs":[{"id":"run-env"}],"truncated":true}}'; exit 0; fi; echo '{"ok":true,"result":{"runs":[{"id":"run-env"}]}}' ;;
  'orchestration run-list '*) echo '{"ok":true,"result":{"runs":[{"id":"run-local"}]}}' ;;
  'orchestration worker-list --environment env-a --run run-env '*) cat "$FAKE_DIR/workers-env" ;;
  'orchestration worker-list --run run-local '*) cat "$FAKE_DIR/workers-local" ;;
  'orchestration worker-list '*) echo '{"ok":true,"result":{"workers":[]}}' ;;
  'orchestration worker-show '*) echo '{"ok":true,"result":{"state":"ready","liveness":"live"}}' ;;
  'orchestration worker-release --dispatch '*)
    printf '%s %s\n' "${e:-local}" "$4" >> "$FAKE_DIR/released"
    echo '{"ok":true,"result":{"state":"released"}}' ;;
  'worktree list --environment env-a --json')
    if [ -e "$FAKE_DIR/env-worktrees-fail" ]; then exit 1; fi
    if [ -f "$FAKE_DIR/env-worktrees" ]; then cat "$FAKE_DIR/env-worktrees"; else echo '{"ok":true,"result":{"worktrees":[]}}'; fi ;;
  'worktree list --json') if [ -f "$FAKE_DIR/orca-worktrees" ]; then cat "$FAKE_DIR/orca-worktrees"; else echo '{"ok":true,"result":{"worktrees":[]}}'; fi ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"

git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
g() { git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid "$@"; }
g commit -qm c1 --allow-empty
g remote add origin "$tmp/origin"
g push -qu origin main
c1=$(g rev-parse HEAD)
g commit -qm c2 --allow-empty
g push -q origin main
# Item 1 fixture: local branch sits inside main, its own upstream has a different history.
g checkout -q -b side "$c1"; echo remote > "$tmp/repo/remote-only"; g add remote-only; g commit -qm remote-only; g push -q origin side:diverged; g checkout -q main; g branch -qD side; rm -f "$tmp/repo/remote-only"
g branch diverged main
g branch --set-upstream-to=origin/diverged diverged >/dev/null
# Item 3 fixture: closed PR branch holding two commits that exist on no remote.
g checkout -q -b ahead; g commit -qm a1 --allow-empty; g commit -qm a2 --allow-empty; g checkout -q main
echo '[{"headRefName":"ahead","headRefOid":"x","state":"CLOSED"}]' > "$tmp/prs"

none='{"ok":true,"result":{"terminals":[]}}'
echo "$none" > "$tmp/terminals-local"; echo "$none" > "$tmp/terminals-env"
echo '{"ok":true,"result":{"workers":[]}}' > "$tmp/workers-local"; cp "$tmp/workers-local" "$tmp/workers-env"
run() { : > "$tmp/calls"; rm -f "$tmp/closed" "$tmp/released"; bash "$root/script/wrap-up.sh" --repo "$tmp/repo" "$@" > "$tmp/output" 2> "$tmp/errors" || echo "rc=$?" >> "$tmp/errors"; }
expect() { grep -Fxq -- "$1" "$tmp/output" || { echo "FAIL missing: $1"; cat "$tmp/output" "$tmp/errors"; exit 1; }; }
absent() { ! grep -Fq -- "$1" "$tmp/output" || { echo "FAIL unexpected: $1"; cat "$tmp/output"; exit 1; }; }
row() { # id state liveness terminalState terminal path
  jq -n --arg id "$1" --arg s "$2" --arg l "$3" --arg ts "$4" --arg t "$5" --arg p "$6" \
    '{dispatchId:$id,state:$s,liveness:$l,terminalState:$ts,workspace:("repo::"+$p)} + (if $t == "" then {} else {terminal:$t} end)'
}
wrap() { jq -s '{ok:true,result:{workers:.,scope:{},warnings:[]}}'; }

# Item 1: the dry run must not plan a delete that git refuses.
run --dry-run
absent 'Delete local diverged (ancestor)'
grep -Fq 'Delete local diverged' "$tmp/output" && planned_delete=1 || planned_delete=0
run --apply
absent 'delete failed'
! grep -Fq 'delete failed' "$tmp/errors" || { echo 'FAIL apply refused a delete the plan listed'; cat "$tmp/errors"; exit 1; }
if git -C "$tmp/repo" show-ref --verify --quiet refs/heads/diverged; then now=1; else now=0; fi
[ "$planned_delete" = "$((1-now))" ] || { echo 'FAIL plan and apply disagree on diverged'; exit 1; }
echo 'ok 1 a branch counts as ancestor only when its own upstream has it too, so the plan matches apply'

# Item 2: counts come before the pane step, and --help names the worst case.
cat > "$tmp/pane-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "sweep: stub"
STUB
WORKER_PANE_CLOSE="$tmp/pane-stub.sh" run --apply
counts=$(grep -n '^Completed counts:' "$tmp/output" | cut -d: -f1)
pane=$(grep -n '^Close ended worker panes' "$tmp/output" | cut -d: -f1)
[ -n "$counts" ] && [ -n "$pane" ] && [ "$counts" -lt "$pane" ] || { echo 'FAIL counts not printed before the pane step'; cat "$tmp/output"; exit 1; }
help=$(bash "$root/script/wrap-up.sh" --help); grep -qi 'worst case' <<< "$help" || { echo 'FAIL --help names no worst case runtime'; exit 1; }
echo 'ok 2 summary counts print before the pane step and --help documents the worst case'

# Item 3: the keep reason says which kind of unpushed it is, with the count.
run --dry-run
expect 'Kept local ahead (unpushed commits: 2)'
echo 'ok 3 unpushed keep reason carries the commit count'

# Item 4: untracked machine links do not make the main checkout dirty.
ln -s /nonexistent-target "$tmp/repo/machine-link"
run --dry-run
expect 'Fast forward main checkout'
echo 'x' > "$tmp/repo/real-file"
run --dry-run
absent 'Fast forward main checkout'
expect 'Kept main update (checkout is not on main or is dirty)'
rm -f "$tmp/repo/machine-link" "$tmp/repo/real-file"
echo 'ok 4 only untracked symlinks are ignored when judging the main checkout'

# Item 5: release finished workers on every environment.
{
  row d-succ succeeded exited reclaimable '' /fixture/a
  row d-stop stopped live reclaimable '' /fixture/b
  row d-sleep in_progress sleep reclaimable '' /fixture/c
  row d-done succeeded exited released '' /fixture/d
  row d-live ready live reclaimable '' /fixture/e
  row d-prog in_progress live reclaimable '' /fixture/f
  row d-own succeeded exited retained t-own /fixture/g
} | wrap > "$tmp/workers-local"
{
  row d-fail failed exited reclaimable '' /fixture/h
  row d-envlive in_progress live reclaimable '' /fixture/i
} | wrap > "$tmp/workers-env"
run --dry-run
for want in 'local d-succ' 'local d-stop' 'local d-sleep' 'env-a d-fail'; do
  grep -Fq "Release worker ${want#* } (${want% *}" "$tmp/output" || { echo "FAIL dry run missing release: $want"; cat "$tmp/output" "$tmp/errors" "$tmp/calls"; exit 1; }
done
test ! -e "$tmp/released" || { echo 'FAIL dry run released something'; exit 1; }
sed -n 's/^Release worker \([^ ]*\) (\([^,)]*\).*/\2 \1/p' "$tmp/output" | sort > "$tmp/planned"
run --apply
sort "$tmp/released" | cmp - "$tmp/planned" || { echo 'FAIL apply released something other than the plan'; cat "$tmp/released"; exit 1; }
for never in d-done d-live d-prog d-own d-envlive; do
  ! grep -Fq "$never" "$tmp/released" || { echo "FAIL released $never"; exit 1; }
done
echo 'ok 5 releases settled workers on every environment; dry run lists exactly what apply does'
echo 'ok 5 live in-progress workers and the caller terminal are never released'

# Item 6: leftover terminals on every environment.
term() { jq -n --arg h "$1" --arg p "$2" --argjson a "${3:-null}" '{handle:$h,worktreePath:$p,connected:true,writable:true,agentIdentity:$a,lastOutputAt:1} | if $p == "" then del(.worktreePath) else . end'; }
{
  row d-live ready live retained '' /fixture/live
  row d-old succeeded exited released '' /fixture/finished
} | wrap > "$tmp/workers-env"
echo "$none" | jq . > /dev/null
g worktree add -q --detach "$tmp/wt-gone" main
wt_gone=$(cd "$tmp/wt-gone" && pwd -P)
# The environment reports its own path for the removed worktree; a terminal at the coordinator's local path is another place.
jq -n --arg l "$wt_gone" '{ok:true,result:{worktrees:[{repoId:"r1",hostId:"local",path:$l,branch:"refs/heads/gone-br"},{repoId:"r1",hostId:"env-a",path:"/remote/gone-wt",branch:"gone-br"},{repoId:"r1",hostId:"env-a",path:"/remote/sibling-wt",branch:"gone-br"},{repoId:"r1",hostId:"env-a",path:"/remote/other-wt",branch:"other-br"}]}}' > "$tmp/orca-worktrees"
# What the environment reports now: the removed checkout is absent, a second checkout on the same branch is still there.
echo '{"ok":true,"result":{"worktrees":[{"repoId":"r1","hostId":"env-a","path":"/remote/sibling-wt","branch":"gone-br"},{"repoId":"r1","hostId":"env-a","path":"/remote/other-wt","branch":"other-br"}]}}' > "$tmp/env-worktrees"
{ term e-live /fixture/live; term e-setup /fixture/finished; term e-gone /remote/gone-wt; term e-sibling /remote/sibling-wt; term e-samepath "$wt_gone"; term e-other /remote/other-wt; term e-never /fixture/never-dispatched; term e-agent /fixture/removed2 '"agent"'; term e-none ''; term t-own /fixture/own; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-env"
{ term l-gone /fixture/removed; term t-own /fixture/own; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-local"
echo '{"ok":true,"result":{"workers":[]}}' > "$tmp/workers-local"
run --dry-run
expect 'Close terminal e-setup (env-a, settled dispatch on this path)'
expect 'Remove worktree '"$wt_gone"' (detached at merged commit)'
expect 'Close terminal e-gone (env-a, worktree gone in this run)'
expect 'Kept terminal e-samepath (env-a, unknown owner, still running)'
expect 'Kept terminal e-never (env-a, unknown owner, still running)'
expect 'Close terminal l-gone (local, no dispatch, no agent)'
for keep in e-live e-sibling e-samepath e-other e-never e-agent e-none t-own; do
  ! grep -Fq "Close terminal $keep " "$tmp/output" || { echo "FAIL would close $keep"; exit 1; }
done
test ! -e "$tmp/closed"
# A terminal kept in the first pass and closed in the late one is counted once, as closed.
n_close=$(grep -c '^Close terminal ' "$tmp/output" || true); n_kept=$(grep -c '^Kept terminal ' "$tmp/output" || true)
# The Kept line for e-gone was printed before its worktree went; the summary must not count it twice.
expect "terminals closed=$n_close kept=$((n_kept-1))"
echo 'ok 6 a remote terminal in a removed worktree is matched by the path its environment reports and counted once'
# A scheduled round (WRAP_UP_SCHEDULED_CHILD) closes the plain shell of a removed worktree too, never an agent's.
{ term e-gone /remote/gone-wt; term e-gone-agent /remote/gone-wt '"agent"'; term e-sibling /remote/sibling-wt; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-env"
WRAP_UP_SCHEDULED_CHILD=1 run --dry-run
expect 'Close terminal e-gone (env-a, worktree gone in this run)'
expect 'Kept terminal e-gone-agent (env-a, owner session)'
! grep -Fq 'Close terminal e-sibling ' "$tmp/output" || { echo 'FAIL scheduled round closed a shell in a checkout the environment still reports'; exit 1; }
echo 'ok 6 a scheduled round closes plain shells of a removed worktree, not agents'
# An unreadable environment listing matches no removed worktree.
touch "$tmp/env-worktrees-fail"
run --dry-run
! grep -Fq 'worktree gone in this run' "$tmp/output" || { echo 'FAIL closed on an unreadable environment worktree list'; exit 1; }
rm -f "$tmp/env-worktrees-fail"
echo 'ok 6 an unreadable environment worktree list closes nothing as gone'
# An empty environment listing is not a fresh one: it must not turn every same-branch remote path into a gone one.
echo '{"ok":true,"result":{"worktrees":[]}}' > "$tmp/env-worktrees"
run --dry-run
! grep -Fq 'worktree gone in this run' "$tmp/output" || { echo 'FAIL closed on an empty environment worktree list'; exit 1; }
# A truncated environment listing is not a fresh one: the live sibling checkout it left out must not count as gone.
echo '{"ok":true,"result":{"worktrees":[{"repoId":"r1","hostId":"env-a","path":"/remote/other-wt","branch":"other-br"}],"truncated":true}}' > "$tmp/env-worktrees"
run --dry-run
! grep -Fq 'worktree gone in this run' "$tmp/output" || { echo 'FAIL closed on a truncated environment worktree list'; cat "$tmp/output"; exit 1; }
echo 'ok 6 a truncated environment worktree list closes nothing as gone'
echo '{"ok":true,"result":{"worktrees":[{"repoId":"r1","hostId":"env-a","path":"/remote/sibling-wt","branch":"gone-br"},{"repoId":"r1","hostId":"env-a","path":"/remote/other-wt","branch":"other-br"}]}}' > "$tmp/env-worktrees"
echo 'ok 6 an empty environment worktree list closes nothing as gone'
{ term e-live /fixture/live; term e-setup /fixture/finished; term e-gone /remote/gone-wt; term e-sibling /remote/sibling-wt; term e-samepath "$wt_gone"; term e-other /remote/other-wt; term e-never /fixture/never-dispatched; term e-agent /fixture/removed2 '"agent"'; term e-none ''; term t-own /fixture/own; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-env"
run --dry-run
grep -o '^Close terminal [^ ]* ([^,]*' "$tmp/output" | sed 's/^Close terminal \([^ ]*\) (\(.*\)/\2 \1/; s/^local/local/' | sort > "$tmp/planned"
run --apply
sort "$tmp/closed" | cmp - "$tmp/planned" || { echo 'FAIL apply closed other than the plan'; cat "$tmp/closed"; exit 1; }
echo 'ok 6 leftover terminals close on every environment; live, agent, never dispatched, no-worktree and own terminals stay'
# A truncated run list or worker page cannot prove which dispatches are live, so no terminal closes.
touch "$tmp/runs-truncated"
run --dry-run
rm -f "$tmp/runs-truncated"
! grep -q '^Close terminal ' "$tmp/output" || { echo 'FAIL closed a terminal on a truncated run list'; cat "$tmp/output"; exit 1; }
grep -Fq 'closing no terminals' "$tmp/errors" || { echo 'FAIL no warning for a truncated run list'; cat "$tmp/errors"; exit 1; }
echo 'ok 6 a truncated run list closes no terminals'
cp "$tmp/workers-env" "$tmp/workers-env.bak"
jq '.result.truncated = true' "$tmp/workers-env.bak" > "$tmp/workers-env"
run --dry-run
cp "$tmp/workers-env.bak" "$tmp/workers-env"
! grep -q '^Close terminal ' "$tmp/output" || { echo 'FAIL closed a terminal on a truncated worker list'; cat "$tmp/output"; exit 1; }
grep -Fq 'closing no terminals' "$tmp/errors" || { echo 'FAIL no warning for a truncated worker list'; cat "$tmp/errors"; exit 1; }
echo 'ok 6 a truncated worker list closes no terminals'
# A truncated environment list may hide an environment that holds a live dispatch, so no terminal closes.
touch "$tmp/envs-truncated"
run --dry-run
rm -f "$tmp/envs-truncated"
! grep -q '^Close terminal ' "$tmp/output" || { echo 'FAIL closed a terminal on a truncated environment list'; cat "$tmp/output"; exit 1; }
grep -Fq 'environment list unavailable' "$tmp/errors" || { echo 'FAIL no warning for a truncated environment list'; cat "$tmp/errors"; exit 1; }
echo 'ok 6 a truncated environment list closes no terminals'

# Item 8: sleep is settled for the terminal close too, so one run releases the worker and closes its terminals.
{
  row d-nap in_progress sleep reclaimable '' /fixture/nap
  row d-awake in_progress live reclaimable '' /fixture/awake
} | wrap > "$tmp/workers-local"
cp "$tmp/workers-local" "$tmp/workers-env"
{ term l-nap /fixture/nap; term l-awake /fixture/awake; term t-own /fixture/own; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-local"
{ term e-nap /fixture/nap; term e-awake /fixture/awake; } | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals-env"
rm -f "$tmp/orca-worktrees"
run --apply
expect 'Release worker d-nap (local, liveness sleep)'
expect 'Close terminal l-nap (local, settled dispatch on this path)'
expect 'Close terminal e-nap (env-a, settled dispatch on this path)'
expect 'Kept terminal l-awake (local, live dispatch)'
expect 'Kept terminal e-awake (env-a, live dispatch)'
grep -Fxq 'local l-nap' "$tmp/closed" && grep -Fxq 'env-a e-nap' "$tmp/closed" || { echo 'FAIL apply did not close the sleeping dispatch terminals'; cat "$tmp/closed"; exit 1; }
echo 'ok 8 a sleeping dispatch is released and its terminals closed in the same run'

# Item 7: one apply at a time, and every pane close call has its own short timeout.
bash -c 'sleep 60; :' wrap-up.sh &
holder=$!
echo "$holder" > "$tmp/state/wrap-up-apply.lock"
run --apply
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
grep -q 'rc=75' "$tmp/errors" || { echo 'FAIL second apply was not refused'; cat "$tmp/errors"; exit 1; }
grep -Fq "$holder" "$tmp/errors" "$tmp/output" || { echo 'FAIL refusal does not name the holder'; exit 1; }
test ! -s "$tmp/calls" || { echo 'FAIL refused run still called orca'; exit 1; }
rm -f "$tmp/state/wrap-up-apply.lock"
echo 99999999 > "$tmp/state/wrap-up-apply.lock"
run --apply
! grep -q 'rc=75' "$tmp/errors" || { echo 'FAIL a dead holder blocked the run'; exit 1; }
test ! -e "$tmp/state/wrap-up-apply.lock" || { echo 'FAIL lock left behind'; exit 1; }
run --dry-run
# The lock goes on every exit path: an argument error before the lock, an error after it, and SIGTERM.
rm -f "$tmp/state/wrap-up-apply.lock"
bash "$root/script/wrap-up.sh" --apply --repo "$tmp/does-not-exist" >/dev/null 2>&1 || true
test ! -e "$tmp/state/wrap-up-apply.lock" || { echo 'FAIL lock left after early error'; exit 1; }
cat > "$tmp/bin/slow-orca" <<'STUB'
#!/usr/bin/env bash
: > "$FAKE_DIR/slow-started"
sleep 30
STUB
chmod +x "$tmp/bin/slow-orca"
rm -f "$tmp/slow-started"
ORCA_CLI_COMMAND="$tmp/bin/slow-orca" bash "$root/script/wrap-up.sh" --apply --repo "$tmp/repo" >/dev/null 2>&1 &
slow=$!
for _ in $(seq 1 100); do [ -e "$tmp/slow-started" ] && break; sleep 0.1; done
test -e "$tmp/state/wrap-up-apply.lock" || { echo 'FAIL lock not held while running'; kill "$slow" 2>/dev/null; exit 1; }
kill -TERM "$slow"; wait "$slow" 2>/dev/null || true
test ! -e "$tmp/state/wrap-up-apply.lock" || { echo 'FAIL lock left after SIGTERM'; exit 1; }
echo 'ok 7 a second apply refuses with the holder; a dead holder does not block; the lock is released'
cat > "$tmp/pane-env.sh" <<'STUB'
#!/usr/bin/env bash
echo "$ORCA_PANE_CALL_TIMEOUT" > "$FAKE_DIR/pane-timeout"
STUB
WRAP_UP_PANE_CALL_TIMEOUT=7 WORKER_PANE_CLOSE="$tmp/pane-env.sh" run --apply
[ "$(cat "$tmp/pane-timeout")" = 7 ] || { echo 'FAIL wrap-up did not pass the per call timeout'; exit 1; }
cat > "$tmp/bin/hang-orca" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
chmod +x "$tmp/bin/hang-orca"
start=$SECONDS
ORCA_CLI_COMMAND="$tmp/bin/hang-orca" ORCA_PANE_CALL_TIMEOUT=1 ORCA_PANE_STATE_DIR="$tmp/pane-state" \
  timeout 60 bash "$root/.agents/skills/orca-team/worker-pane-close.sh" >/dev/null 2>&1 || true
[ $((SECONDS-start)) -lt 15 ] || { echo "FAIL a hung pane close call took $((SECONDS-start))s"; exit 1; }
echo 'ok 7 each pane close call has its own short timeout'
