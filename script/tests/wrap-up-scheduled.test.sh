#!/usr/bin/env bash
# Scheduled wrap-up round: lock, Orca check, load check, per repo run, log. Fake wrap-up and fake orca only.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
script="$root/script/wrap-up-scheduled.sh"
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/state"
jqdir=$(dirname "$(command -v jq)")
# Fake orca: FAKE_ORCA picks ready (default), starting, or fail.
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
[ "$*" = 'status --json' ] || exit 2
case "${FAKE_ORCA:-ready}" in
  ready) echo '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true}}}' ;;
  starting) echo '{"ok":true,"result":{"runtime":{"state":"starting","reachable":false}}}' ;;
  *) exit 1 ;;
esac
FAKE
# Fake wrap-up: records its arguments and the two env vars it must see; FAKE_BLOCK waits for a release file.
cat > "$tmp/wrap-up.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'args=%s fleet_config=%s orca_cmd=%s\n' "$*" "${WRAP_UP_FLEET_CONFIG-<unset>}" "${ORCA_CLI_COMMAND-<unset>}" >> "$FAKE_CALLS"
if [ -n "${FAKE_BLOCK:-}" ]; then
  : > "$FAKE_BLOCK.started"
  i=0; while [ ! -e "$FAKE_BLOCK.release" ] && [ "$i" -lt 2000000 ]; do i=$((i+1)); done
fi
case "$*" in *"--repo $FAKE_FAIL_REPO"*) exit 3 ;; esac
exit 0
FAKE
chmod +x "$tmp/bin/orca" "$tmp/wrap-up.sh"
printf '{"local_host":"alpha","host_load_ceilings":{"alpha":8,"beta":4}}\n' > "$tmp/fleet.json"
printf '{"repos":[{"path":"%s/repo-a","fleet_config":"%s/fleet-a.json"},{"path":"%s/repo-b"}]}\n' "$tmp" "$tmp" "$tmp" > "$tmp/config.json"
calls="$tmp/calls"; log="$tmp/home/round.log"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
has() { grep -Fq -- "$1" "$2"; }
lacks() { ! grep -Fq -- "$1" "$2"; }
ncalls() { [ -f "$calls" ] && wc -l < "$calls" | tr -d ' ' || echo 0; }
# Bare environment, as launchd gives it. The caller's ORCA_CLI_COMMAND and WRAP_UP_FLEET_CONFIG are planted on purpose.
round() {
  env -i HOME="$tmp/home" PATH="$tmp/bin:$jqdir:/usr/bin:/bin" \
    WRAP_UP_STATE_DIR="$tmp/state" WRAP_UP_SCHEDULED_LOG="$log" \
    WRAP_UP_SCHEDULED_CONFIG="${CONFIG:-$tmp/config.json}" WRAP_UP_SCHEDULED_FLEET_STATE="${FLEETSTATE:-$tmp/fleet.json}" \
    WRAP_UP_SCHEDULED_LOAD_CMD="echo ${LOAD:-1}" WRAP_UP_SCHEDULED_WRAP_UP="$tmp/wrap-up.sh" \
    FAKE_CALLS="$calls" FAKE_FAIL_REPO="${FAIL_REPO:-none}" FAKE_ORCA="${FAKE_ORCA:-ready}" FAKE_BLOCK="${FAKE_BLOCK:-}" \
    ORCA_CLI_COMMAND=/nonexistent/orca WRAP_UP_FLEET_CONFIG=/caller/fleet.json \
    bash "$script"
}
# Bounded wait on a file the other side creates (no sleeps: it ends the moment the file exists, or after ~20 s of polling).
waitfor() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 200000 ]; do i=$((i+1)); done; [ -e "$1" ]; }
reset() { rm -rf "$calls" "$log" "$tmp/state"/* ; FAKE_BLOCK=; FAKE_ORCA=ready; LOAD=1; FAIL_REPO=none; CONFIG=; FLEETSTATE=; }

reset
round; status=$?
check 'normal round exits 0' test "$status" -eq 0
check 'normal round runs both repos' test "$(ncalls)" -eq 2
check 'repo with fleet_config gets --fleet and its own config' has "args=--apply --fleet --repo $tmp/repo-a fleet_config=$tmp/fleet-a.json" "$calls"
check 'repo without fleet_config runs without --fleet and with the caller config cleared' has "args=--apply --repo $tmp/repo-b fleet_config=<unset>" "$calls"
check 'wrap-up runs with ORCA_CLI_COMMAND unset' test "$(grep -c 'orca_cmd=<unset>' "$calls")" -eq 2
check 'log has start line' has 'round start' "$log"
check 'log has per repo exit codes' has "repo $tmp/repo-b exit 0" "$log"
check 'log has finished line' has 'round finished' "$log"
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

reset
FAKE_ORCA=fail round; status=$?
check 'orca unavailable exits 0' test "$status" -eq 0
check 'orca unavailable runs no wrap-up' test "$(ncalls)" -eq 0
check 'orca unavailable logs why' has 'Orca not ready' "$log"
reset
FAKE_ORCA=starting round; status=$?
check 'orca not ready runs no wrap-up' test "$status" -eq 0 -a "$(ncalls)" -eq 0

reset
LOAD=20 round; status=$?
check 'load above the limit exits 0' test "$status" -eq 0
check 'load above the limit runs nothing' test "$(ncalls)" -eq 0
check 'load above the limit logs why' has 'load 20' "$log"
reset
LOAD=8 round
check 'load at the limit still runs' test "$(ncalls)" -eq 2
reset
printf '{"local_host":"gamma","host_load_ceilings":{"alpha":8}}\n' > "$tmp/fleet-nolimit.json"
FLEETSTATE="$tmp/fleet-nolimit.json" round; status=$?
check 'no limit for the local host runs nothing' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'no limit logs why' has 'no load limit' "$log"
reset
FLEETSTATE="$tmp/missing.json" round; status=$?
check 'missing fleet config runs nothing' test "$status" -eq 0 -a "$(ncalls)" -eq 0

reset
FAIL_REPO="$tmp/repo-a" round; status=$?
check 'failing repo does not stop the next' test "$(ncalls)" -eq 2
check 'failing repo exit code logged' has "repo $tmp/repo-a exit 3" "$log"
check 'round with a failing repo still finishes' has 'round finished' "$log"
check 'round with a failing repo exits 0' test "$status" -eq 0

reset
printf '{"repos":[{"path":"~/r","fleet_config":"~/f.json"}]}\n' > "$tmp/config-tilde.json"
CONFIG="$tmp/config-tilde.json" round
check 'a leading ~ in the config means the home of the job' has "args=--apply --fleet --repo $tmp/home/r fleet_config=$tmp/home/f.json" "$calls"

reset
CONFIG="$tmp/none.json" round; status=$?
check 'missing config runs nothing and exits 0' test "$status" -eq 0 -a "$(ncalls)" -eq 0
check 'missing config logged' has 'no config' "$log"

reset
mkdir -p "$(dirname "$log")"
head -c 5300000 /dev/zero > "$log"
round
check 'big log is rotated once' test -f "$log.1" -a "$(wc -c < "$log.1" | tr -d ' ')" -gt 5000000
check 'new log starts small' test "$(wc -c < "$log" | tr -d ' ')" -lt 100000

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
