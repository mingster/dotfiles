#!/usr/bin/env bash
# wrap-up.sh --scheduled: lock, CLI lookup, Orca check, load check, per repo run, log, issue. Fake wrap-up, orca and gh only.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
script="$root/script/wrap-up.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/nobin" "$tmp/app" "$tmp/home/.local/bin" "$tmp/home/.orca/cli/bin" "$tmp/state"
# jq alone: its real directory may hold a real orca, and the no CLI cases must not find one.
mkdir -p "$tmp/tools"; ln -s "$(command -v jq)" "$tmp/tools/jq"
# Fake orca: FAKE_ORCA picks ready (default), starting, fail or hang. FAKE_REPOS picks the repo list: ok (default), fail or refused.
cat > "$tmp/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'status --json')
    case "${FAKE_ORCA:-ready}" in
      ready) echo '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true}}}' ;;
      starting) echo '{"ok":true,"result":{"runtime":{"state":"starting","reachable":false}}}' ;;
      hang) exec sleep 30 ;;
      *) exit 1 ;;
    esac ;;
  'repo list --json')
    case "${FAKE_REPOS:-ok}" in
      ok) cat "$FAKE_REPO_LIST" ;;
      refused) echo '{"ok":false,"error":{"code":"nope"}}' ;;
      *) exit 1 ;;
    esac ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$tmp/orca"
cp "$tmp/orca" "$tmp/bin/orca"
# Fake gh: open issues live in a file, so a second round sees the first round's issue.
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  'issue list') [ -z "${FAKE_GH_LIST_FAIL:-}" ] || exit 1; cat "$FAKE_GH_OPEN" 2>/dev/null || echo '[]' ;;
  'repo view') [ "${FAKE_GH_PUBLIC:-}" = 1 ] && echo false || echo true ;;
  'issue create')
    while [ $# -gt 0 ]; do [ "$1" = --title ] && title=$2; shift; done
    jq -cn --arg t "$title" '[{title:$t}]' > "$FAKE_GH_OPEN" ;;
  *) exit 2 ;;
esac
FAKE
cp "$tmp/bin/gh" "$tmp/nobin/gh"
# Fake wrap-up: records its arguments, the env vars it must see and the orca it finds; FAKE_BLOCK waits for a release file.
cat > "$tmp/wrap-up.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'child=%s args=%s fleet_config=%s orca_cmd=%s budget=%s orca=%s\n' "${WRAP_UP_SCHEDULED_CHILD-<unset>}" "$*" "${WRAP_UP_FLEET_CONFIG-<unset>}" "${ORCA_CLI_COMMAND-<unset>}" "${WRAP_UP_TOTAL_TIMEOUT-<unset>}" "$(command -v orca)" >> "$FAKE_CALLS"
echo "Kept worktree $*-wt (unpushed commits)"
if [ -n "${FAKE_BLOCK:-}" ]; then
  : > "$FAKE_BLOCK.started"
  i=0; while [ ! -e "$FAKE_BLOCK.release" ] && [ "$i" -lt 2000000 ]; do i=$((i+1)); done
fi
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
case "$*" in *"--repo $FAKE_FAIL_REPO"*) exit 3 ;; esac
exit 0
FAKE
chmod +x "$tmp/bin/orca" "$tmp/nobin/gh" "$tmp/bin/gh" "$tmp/wrap-up.sh"
jq -n --arg a "$tmp/home/repo-a" --arg b "$tmp/repo-b" --arg c "$tmp/repo-other" --arg f "$tmp/folder" \
  '{ok:true,result:{repos:[{path:$a,kind:"git"},{path:$b,kind:"git"},{path:$c,kind:"git"},{path:$f,kind:"folder"}]}}' > "$tmp/repos.json"
mkdir -p "$tmp/home/repo-a/.agents" "$tmp/repo-b/.agents" "$tmp/repo-other"
: > "$tmp/home/repo-a/.agents/head-checks.conf"; : > "$tmp/repo-b/.agents/head-checks.conf"
repo_a="$tmp/home/repo-a"; repo_b="$tmp/repo-b"
calls="$tmp/calls"; log="$tmp/home/round.log"; detail="$tmp/home/round-detail.log"; ghlog="$tmp/gh.log"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
has() { grep -Fq -- "$1" "$2"; }
lacks() { ! grep -Fq -- "$1" "$2" 2>/dev/null; }
ncalls() { [ -f "$calls" ] && wc -l < "$calls" | tr -d ' ' || echo 0; }
lines() { [ -f "$log" ] && wc -l < "$log" | tr -d ' ' || echo 0; }
nissues() { if [ -f "$ghlog" ]; then grep -c "^gh issue create" "$ghlog" || true; else echo 0; fi; }
# Bare environment, as a schedule gives it. The caller's ORCA_CLI_COMMAND and WRAP_UP_FLEET_CONFIG are planted on purpose.
round() {
  env -i HOME="$tmp/home" PATH="${ROUND_PATH:-$tmp/bin}:$tmp/tools:/usr/bin:/bin" \
    WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_SCHEDULED_LOG="$log" WRAP_UP_ORCA_APP_BIN="${APP_BIN:-$tmp/noapp}" WRAP_UP_EXTRA_BIN= \
    WRAP_UP_SCHEDULED_LOAD_CMD="${LOAD_CMD-echo ${LOAD:-1}}" WRAP_UP_SCHEDULED_CORES_CMD="${CORES_CMD-echo 4}" \
    WRAP_UP_SCHEDULED_WRAP_UP="$tmp/wrap-up.sh" WRAP_UP_ISSUE_REPO="${ISSUE_REPO-o/r}" WRAP_UP_CALL_TIMEOUT="${CALL_TIMEOUT:-20}" \
    ${ROUND_LIMIT:+WRAP_UP_SCHEDULED_REPO_LIMIT="$ROUND_LIMIT"} ${KILL_GRACE:+WRAP_UP_SCHEDULED_KILL_GRACE="$KILL_GRACE"} \
    ${PRECHECK_TIMEOUT:+WRAP_UP_PRECHECK_TIMEOUT="$PRECHECK_TIMEOUT"} \
    FAKE_CALLS="$calls" FAKE_FAIL_REPO="${FAIL_REPO:-none}" FAKE_ORCA="${FAKE_ORCA:-ready}" FAKE_BLOCK="${FAKE_BLOCK:-}" \
    FAKE_REPOS="${FAKE_REPOS:-ok}" FAKE_REPO_LIST="$tmp/repos.json" FAKE_SLEEP="${FAKE_SLEEP:-}" \
    FAKE_GH_LOG="$ghlog" FAKE_GH_OPEN="$tmp/gh-open.json" FAKE_GH_LIST_FAIL="${FAKE_GH_LIST_FAIL:-}" FAKE_GH_PUBLIC="${FAKE_GH_PUBLIC:-}" \
    ORCA_CLI_COMMAND=/nonexistent/orca WRAP_UP_FLEET_CONFIG=/caller/fleet.json \
    bash "$script" --scheduled
}
# Bounded wait on a file the other side creates (no sleeps: it ends the moment the file exists, or after ~20 s of polling).
waitfor() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 200000 ]; do i=$((i+1)); done; [ -e "$1" ]; }
reset() {
  rm -rf "$calls" "$log" "$detail" "$ghlog" "$tmp/gh-open.json" "$tmp/state"/* "$tmp/app"/* "$tmp/home/.local/bin"/* "$tmp/home/.orca/cli/bin"/*
  FAKE_BLOCK=; FAKE_ORCA=ready; FAKE_REPOS=ok; FAKE_SLEEP=; LOAD=1; FAIL_REPO=none; ROUND_PATH=; APP_BIN=; ROUND_LIMIT=; CALL_TIMEOUT=; FAKE_GH_LIST_FAIL=; KILL_GRACE=; FAKE_GH_PUBLIC=; PRECHECK_TIMEOUT=; unset ISSUE_REPO
  unset LOAD_CMD CORES_CMD
}

reset
round; status=$?
check 'normal round exits 0' test "$status" -eq 0
check 'normal round runs the git repos Orca lists, and no folder' test "$(ncalls)" -eq 2
check 'a repo runs without --fleet and with the caller config cleared' has "args=--apply --repo $repo_b fleet_config=<unset>" "$calls"
check 'wrap-up runs with ORCA_CLI_COMMAND unset' test "$(grep -c 'orca_cmd=<unset>' "$calls")" -eq 2
check 'a round writes exactly one line' test "$(lines)" -eq 1
check 'the line is a summary' has 'round ok: repos=2' "$log"
check 'kept items with their reasons go to the detail log' has 'unpushed commits' "$detail"
check 'the summary log stays free of per item output' lacks 'unpushed commits' "$log"
check 'lock released after the round' test ! -e "$tmp/state/wrap-up-scheduled.lock"

reset
FAKE_BLOCK="$tmp/block" round & holder=$!
waitfor "$tmp/block.started"
round; status=$?
check 'overlapping round exits 0' test "$status" -eq 0
check 'overlapping round does no work' test "$(ncalls)" -eq 1
check 'overlapping round logs the live holder' has 'already running' "$log"
: > "$tmp/block.release"
wait "$holder"
check 'first round finished after release' test "$(ncalls)" -eq 2
check 'lock released after overlap' test ! -e "$tmp/state/wrap-up-scheduled.lock"

reset
( exit 0 ) & dead=$!; wait "$dead"
mkdir -p "$tmp/state/wrap-up-scheduled.lock"; echo "$dead" > "$tmp/state/wrap-up-scheduled.lock/pid"
round; status=$?
check 'stale lock round exits 0' test "$status" -eq 0
check 'stale lock is taken over and work runs' test "$(ncalls)" -eq 2
check 'stale lock takeover logged' has 'stale lock' "$log"
reset
sleep 30 & other=$!
mkdir -p "$tmp/state/wrap-up-scheduled.lock"; echo "$other" > "$tmp/state/wrap-up-scheduled.lock/pid"
round
check 'live pid of another program does not hold the lock' test "$(ncalls)" -eq 2
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

# A lock with no pid (a legacy directory, or an empty file) counts as live until it is old enough to be stale.
lockpath="$tmp/state/wrap-up-scheduled.lock"
reset
mkdir -p "$lockpath"
round; status=$?
check 'pid-less lock directory is treated as live' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'pid-less lock directory logs the skip' has 'already running' "$log"
check 'pid-less lock directory is left alone' test -d "$lockpath"
reset
: > "$lockpath"
round
check 'pid-less lock file is treated as live' test "$(ncalls)" -eq 0
check 'pid-less lock file is left alone' test -e "$lockpath"
touch -t 202001010000 "$lockpath"
round
check 'an old pid-less lock file is taken over' test "$(ncalls)" -eq 2
check 'old pid-less takeover logged' has 'stale lock' "$log"
reset
mkdir -p "$lockpath"; touch -t 202001010000 "$lockpath"
round
check 'an old pid-less lock directory is taken over' test "$(ncalls)" -eq 2

# The lock never shows without its pid: a round that is held mid-run exposes a lock holding that round's pid.
reset
rm -f "$tmp/block.started" "$tmp/block.release"
FAKE_BLOCK="$tmp/block" round & holder=$!
waitfor "$tmp/block.started"
check 'the live lock holds a pid' test -s "$lockpath"
: > "$tmp/block.release"
wait "$holder"
rm -f "$tmp/block.started" "$tmp/block.release"

# Two rounds that both judge the lock stale leave exactly one owner.
race_ok=1
for i in 1 2 3 4 5 6 7 8 9 10; do
  reset
  rm -f "$tmp/block.started" "$tmp/block.release"
  ( exit 0 ) & dead=$!; wait "$dead"
  echo "$dead" > "$lockpath"
  FAKE_BLOCK="$tmp/block" round & r1=$!
  FAKE_BLOCK="$tmp/block" round & r2=$!
  FAKE_BLOCK="$tmp/block" round & r3=$!
  FAKE_BLOCK="$tmp/block" round & r4=$!
  waitfor "$tmp/block.started"
  j=0; while ! [ "$(grep -c 'skip' "$log" 2>/dev/null)" -ge 3 ] 2>/dev/null && [ "$j" -lt 200000 ]; do j=$((j+1)); done
  n=$(ncalls)
  : > "$tmp/block.release"
  wait "$r1" "$r2" "$r3" "$r4"
  [ "$n" -eq 1 ] && [ "$(ncalls)" -eq 2 ] || race_ok=0
done
check 'two racing takeovers of a stale lock leave one owner' test "$race_ok" -eq 1
check 'lock released after the race' test ! -e "$lockpath"

reset
FAKE_ORCA=fail round; status=$?
check 'orca unavailable exits 0' test "$status" -eq 0
check 'orca unavailable runs no wrap-up' test "$(ncalls)" -eq 0
check 'orca unavailable logs why' has 'Orca not ready' "$log"
reset
FAKE_ORCA=starting round; status=$?
check 'orca not ready runs no wrap-up' test "$status" -eq 0 -a "$(ncalls)" -eq 0

# A hung Orca must not hold the lock for ever.
reset
FAKE_ORCA=hang CALL_TIMEOUT=1 round; status=$?
check 'a hung orca status ends as a skip' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'a hung orca status logs why' has 'Orca not ready' "$log"

# Load limit from cores: skip at 0.7 per core or more.
reset
LOAD=20 round; status=$?
check 'load above the limit exits 0' test "$status" -eq 0
check 'load above the limit runs nothing' test "$(ncalls)" -eq 0
check 'load above the limit logs why' has 'load 20' "$log"
reset
LOAD=2.8 round
check 'load at exactly 0.7 per core is skipped' test "$(ncalls)" -eq 0
reset
LOAD=2.79 round
check 'load just under 0.7 per core runs' test "$(ncalls)" -eq 2
reset
LOAD=6 CORES_CMD='echo 10' round
check 'the limit follows the core count' test "$(ncalls)" -eq 2
reset
LOAD_CMD='echo nonsense' round; status=$?
check 'unreadable load runs nothing and exits 0' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'unreadable load is a failure line' has 'round failed: load unreadable' "$log"
reset
CORES_CMD='echo 0' round
check 'unreadable cores runs nothing' test "$(ncalls)" -eq 0
check 'unreadable cores is a failure line' has 'round failed: cores unreadable' "$log"
# The real load and core reads work in a bare environment: on macOS sysctl is outside /usr/bin:/bin.
reset
LOAD_CMD= CORES_CMD= round
check 'the real load and cores read in a bare environment' lacks 'unreadable' "$log"

# Repos come from orca repo list.
reset
FAKE_REPOS=fail round; status=$?
check 'unreadable repo list runs nothing and exits 0' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'unreadable repo list is a failure line' has 'round failed: cannot read orca repo list' "$log"
reset
FAKE_REPOS=refused round
check 'a refused repo list is a failure line' has 'round failed: cannot read orca repo list' "$log"

# Lookup of the CLI. fake_cli <dir>: an orca in that directory. The wrap-up child must see the one the lookup chose first on PATH.
fake_cli() { cp "$tmp/orca" "$1/orca"; }
stale="$tmp/home/.orca/cli/bin"
reset
fake_cli "$tmp/app"; fake_cli "$stale"
APP_BIN="$tmp/app" ROUND_PATH="$stale:$tmp/nobin" round
check 'the app CLI wins, even over a stale CLI first on PATH' has "orca=$tmp/app/orca" "$calls"
reset
fake_cli "$stale"
round
check 'orca on PATH wins over the stale CLI' has "orca=$tmp/bin/orca" "$calls"
reset
fake_cli "$tmp/home/.local/bin"; fake_cli "$stale"
ROUND_PATH="$tmp/nobin" round
check '~/.local/bin wins over the stale CLI' has "orca=$tmp/home/.local/bin/orca" "$calls"
reset
fake_cli "$stale"
ROUND_PATH="$tmp/nobin" round
check '~/.orca/cli/bin is used when nothing else exists' has "orca=$stale/orca" "$calls"
reset
ROUND_PATH="$tmp/nobin" round; status=$?
check 'no CLI runs nothing and exits 0' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'no CLI is a failure line, not a skip' has 'round failed: no orca CLI' "$log"
check 'no CLI writes no skip line' lacks 'skip:' "$log"

reset
FAIL_REPO="$repo_a" round; status=$?
check 'failing repo does not stop the next' test "$(ncalls)" -eq 2
check 'failing repo is a failure line with its exit code' has "round failed: repo $repo_a exit 3" "$log"
check 'a failed round writes one line' test "$(lines)" -eq 1
check 'round with a failing repo exits 0' test "$status" -eq 0

# Two failures in a row open one issue, and only one.
reset
FAIL_REPO="$repo_a" round
check 'one failed round opens no issue' test "$(nissues)" -eq 0
FAIL_REPO="$repo_a" round
check 'two failed rounds in a row open an issue' test "$(nissues)" -eq 1
check 'the issue goes to the issue repo' has 'issue create --repo o/r' "$ghlog"
check 'the issue body names the failure' has "repo ~/repo-a exit 3" "$ghlog"
check 'the issue body hides the home path' lacks "$tmp/home" "$ghlog"
FAIL_REPO="$repo_a" round
check 'a third failed round opens no duplicate' test "$(nissues)" -eq 1
reset
ISSUE_REPO= FAIL_REPO="$repo_a" round; ISSUE_REPO= FAIL_REPO="$repo_a" round
check 'no issue repo set opens no issue' test "$(nissues)" -eq 0
check 'no issue repo set never touches gh' lacks 'gh issue' "$ghlog"
check 'no issue repo set says so' has 'issue: WRAP_UP_ISSUE_REPO is not set' "$log"
reset
FAKE_GH_PUBLIC=1 FAIL_REPO="$repo_a" round; FAKE_GH_PUBLIC=1 FAIL_REPO="$repo_a" round
check 'a public issue repo opens no issue' test "$(nissues)" -eq 0
check 'a public issue repo says so' has 'issue: o/r is not private' "$log"
reset
FAIL_REPO="$repo_a" round; round; FAIL_REPO="$repo_a" round
check 'a good round resets the count' test "$(nissues)" -eq 0
reset
FAIL_REPO="$repo_a" round; LOAD=20 round; FAIL_REPO="$repo_a" round
check 'a skip neither counts nor resets' test "$(nissues)" -eq 1
reset
ROUND_PATH="$tmp/nobin" round; ROUND_PATH="$tmp/nobin" round
check 'no CLI counts as a failed round' test "$(nissues)" -eq 1
reset
FAIL_REPO="$repo_a" round
FAKE_GH_LIST_FAIL=1 FAIL_REPO="$repo_a" round
check 'an unreadable issue list opens nothing' test "$(nissues)" -eq 0
check 'an unreadable issue list is logged' has 'issue: cannot read open issues' "$log"
FAIL_REPO="$repo_a" round
check 'the next failed round opens the issue' test "$(nissues)" -eq 1
reset
echo '[{"title":"wrap-up: scheduled rounds failing on another-host-xx"}]' > "$tmp/gh-open.json"
FAIL_REPO="$repo_a" round; FAIL_REPO="$repo_a" round
check 'an issue with another title is no duplicate' test "$(nissues)" -eq 1

reset
round
check 'each child gets the default per-repo budget' test "$(grep -c 'budget=900 ' "$calls")" -eq 2
reset
ROUND_LIMIT=10 FAKE_SLEEP=3 round; status=$?
check 'a round with slow repos exits 0' test "$status" -eq 0
check 'a slow first repo does not block the second' test "$(ncalls)" -eq 2
reset
ROUND_LIMIT=1 KILL_GRACE=1 FAKE_SLEEP=30 round; status=$?
check 'a hung repo run is killed and exits 0' test "$status" -eq 0
check 'a hung repo run is a failure line' has 'round failed:' "$log"
check 'a hung repo run names the killed repo' has "repo $repo_a exit 124" "$log"
check 'the repo after a hung one still runs' test "$(ncalls)" -eq 2
# A hung inner call has its own process group, so stopping the outer one must reach it too.
eval "$(sed -n '/^run_limited() {/,/^}/p' "$script")"
inner=$(declare -f run_limited)
run_limited 1 bash -c "$inner; run_limited 60 sleep 4711" || true
check 'stopping a run stops its inner bounded calls' test -z "$(pgrep -f 'sleep 4711' || true)"
reset
round
check 'a repo run knows it is a scheduled child' has 'child=1 ' "$calls"
check 'a repo without team files is left alone' lacks 'repo-other' "$calls"

reset
mkdir -p "$(dirname "$log")"
head -c 5300000 /dev/zero > "$log"
round
check 'big log is rotated once' test -f "$log.1" -a "$(wc -c < "$log.1" | tr -d ' ')" -gt 5000000
check 'new log starts small' test "$(wc -c < "$log" | tr -d ' ')" -lt 100000

# Child --apply must keep worker-pane-close sweep budget lines in the scheduled detail log (not /dev/null).
reset
real_git=$(command -v git)
pane_stub="$tmp/home/pane-sweep-stub"
mini="$tmp/home/mini-repo"
origin="$tmp/home/mini-origin"
detail="$tmp/home/round-detail.log"
mkdir -p "$mini/.agents" "$(dirname "$pane_stub")"
cat > "$pane_stub" <<'EOS'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  echo 'sweep: deadline reached, 4 pane record(s) left'
fi
exit 0
EOS
chmod +x "$pane_stub"
"$real_git" init -q --bare "$origin"
"$real_git" init -q -b main "$mini"
git -C "$mini" config user.email 't@example.invalid'
git -C "$mini" config user.name T
git -C "$mini" commit -qm init --allow-empty
git -C "$mini" remote add origin "$origin"
git -C "$mini" push -q -u origin main
: > "$mini/.agents/head-checks.conf"
cat > "$tmp/bin/gh-apply" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2 $3" in
  'repo view --json') echo '{"defaultBranchRef":{"name":"main"}}' ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}' ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]' ;;
  'pr list') echo '[]' ;;
  *) exit 2 ;;
esac
FAKE
cat > "$tmp/bin/orca-apply" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"truncated":false,"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"terminals":[]}}' ;;
  'environment list --json') echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*--json*) echo '{"ok":true,"result":{"runs":[]}}' ;;
  *worker-list*--json*) echo '{"ok":true,"result":{"workers":[],"scope":{"source":"flag"}}}' ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$tmp/bin/gh-apply" "$tmp/bin/orca-apply"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"; chmod +x "$tmp/bin/lsof"
env -i HOME="$tmp/home" PATH="$tmp/bin/orca-apply:$tmp/bin/gh-apply:$tmp/tools:/usr/bin:/bin" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0 WRAP_UP_CALL_TIMEOUT=30 \
  WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" \
  WRAP_UP_CLONE_ROOT="$tmp/no-clones" ORCA_CLI_COMMAND="$tmp/bin/orca-apply" WORKER_PANE_CLOSE="$pane_stub" \
  bash "$script" --apply --repo "$mini" >>"$detail" 2>&1 || true
check 'scheduled child detail log keeps pane sweep budget line' has 'sweep: deadline reached, 4 pane record(s) left' "$detail"

# A hung worker-pane-close.sh must be cut off by run_limited using the time-left budget.
pane_hang="$tmp/home/pane-hang-stub"
cat > "$pane_hang" <<'EOS'
#!/usr/bin/env bash
sleep 30
EOS
chmod +x "$pane_hang"
: > "$detail"
p_start=$SECONDS
run_limited 5 env -i HOME="$tmp/home" PATH="$tmp/bin/orca-apply:$tmp/bin/gh-apply:$tmp/tools:/usr/bin:/bin" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0 WRAP_UP_CALL_TIMEOUT=30 \
  WRAP_UP_PANE_TIMEOUT=1 WRAP_UP_TOTAL_TIMEOUT=2 \
  WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" \
  WRAP_UP_CLONE_ROOT="$tmp/no-clones" ORCA_CLI_COMMAND="$tmp/bin/orca-apply" WORKER_PANE_CLOSE="$pane_hang" \
  bash "$script" --apply --repo "$mini" >>"$detail" 2>&1 || true
p_elapsed=$((SECONDS - p_start))
check 'hung pane close is cut off by bounded helper within budget' test "$p_elapsed" -lt 4
check 'hung pane close records timeout exit 124 in failures' has 'worker panes: worker-pane-close exited 124' "$detail"

# Multi-repo scheduled round stops starting new repos when its budget is spent and logs which repos it skipped.
reset
b_start=$SECONDS
# SECONDS ticks in whole seconds, so setup before the repo loop can eat one second of the round budget at random.
# The budget is 3s (9 - 2 * 3), so a lost second still leaves the first repo room to start; its 4s run outlasts the
# budget and ends before the kill (child limit 2 to 3s + 3s grace), so the second repo is always the one skipped.
PRECHECK_TIMEOUT=9 KILL_GRACE=3 ROUND_LIMIT=5 FAKE_SLEEP=4 round; status=$?
b_elapsed=$((SECONDS - b_start))
check 'budgeted multi-repo round exits 0' test "$status" -eq 0
check 'budgeted multi-repo round finishes within precheck timeout' test "$b_elapsed" -le 9
check 'budgeted multi-repo round stops starting new repos when budget is spent' test "$(ncalls)" -eq 1
check 'budgeted multi-repo round logs skipped repo in summary log' has "skipped=$repo_b" "$log"
check 'budgeted multi-repo round logs skipped repo in detail log' has "skip repo $repo_b" "$detail"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
