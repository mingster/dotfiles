#!/usr/bin/env bash
# elon-startup.sh section 6 (#1778): on the coordinator host it starts the fleet-watch loop (or finds it running), writes the
# waiter script and names the 5 minute watch. Other hosts start nothing. Temp HOME, fixture state repo, stub loop script.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/git-identity.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/git-identity.sh"
use_test_git_identity "$work"
pass=0 fail=0

mkdir -p "$work/bin" "$work/script" "$work/home/.claude/state" "$work/cwd" "$work/agent-team"
cp "$root/script/elon-startup.sh" "$work/script/elon-startup.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -s ] && echo "$FAKE_HOST" || echo "$FAKE_HOST.local"\n' > "$work/bin/hostname"
printf '#!/usr/bin/env bash\necho load-stub\n' > "$work/home/.claude/state/fleet-load.sh"
printf 'print("[]")\n' > "$work/script/usage-gate.py"
# Stub loop: --status exits 0 when $work/loop.running exists; a plain start creates it and records the call.
cat >"$work/script/fleet-watch-loop.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --status) [ -f "$LOOP_DIR/loop.running" ] && { echo "fleet-watch-loop: running (pid 4242)"; exit 0; }; echo "fleet-watch-loop: not running"; exit 1 ;;
  "") echo "started config=$FLEET_WATCH_CONFIG state=$FLEET_WATCH_STATE" >>"$LOOP_DIR/loop.calls"; : >"$LOOP_DIR/loop.running" ;;
esac
STUB
chmod +x "$work/bin/hostname" "$work/home/.claude/state/fleet-load.sh" "$work/script/fleet-watch-loop.sh"
echo '{"hosts":[],"repos":[]}' > "$work/fleet.json"
echo '{"runs":[{"id":"run_test_1"}]}' > "$work/home/.claude/state/fleet-watch-elon.json"

setup() {
  rm -rf "$work/origin.git" "$work/seed" "$work/state" "$work/loop.running" "$work/loop.calls" "$work/agent-team"/*
  git init -q --bare -b main "$work/origin.git"
  git clone -q "$work/origin.git" "$work/seed" 2>/dev/null
  printf 'coordinator coordinator-a\nbackup backup-a\n' > "$work/seed/coordinator.conf"
  git -C "$work/seed" add -A && git -C "$work/seed" commit -qm init && git -C "$work/seed" push -q origin HEAD:main
  git clone -q "$work/origin.git" "$work/state"
  echo .sync-ok >> "$work/state/.git/info/exclude"
  touch "$work/state/.sync-ok"
}

OUT=''
run() { # run <host>
  set +e
  OUT=$(cd "$work/cwd" && FAKE_HOST="$1" HOME="$work/home" PATH="$work/bin:$PATH" AGENT_STATE_DIR="$work/state" LOOP_DIR="$work" \
    ELON_STATE_DIR="$work/agent-team" FLEET_WATCH_LOOP_CMD="$work/script/fleet-watch-loop.sh" \
    FLEET_PULL_CONFIG="$work/fleet.json" GIT_TERMINAL_PROMPT=0 bash "$work/script/elon-startup.sh" --no-pull 2>&1)
  RC=$?
  set -e
}
ok_if() { # ok_if <name> <condition exit code>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; echo "$OUT" | sed 's/^/     /'; fi
}
has() { grep -qF -- "$1" <<<"$OUT"; }

setup; run coordinator-a
has "job fleet-watch loop: started (fleet-watch-loop: running (pid 4242))"; ok_if "coordinator starts the loop" $?
grep -qF "state=$work/home/.local/state/agent-team/fleet-watch.state.json" "$work/loop.calls"; ok_if "loop gets the default state path" $?
grep -qF "config=$work/home/.claude/state/fleet-watch-elon.json" "$work/loop.calls"; ok_if "loop gets the default config path" $?
has "job waiter: armed, script $work/agent-team/elon-wait.sh (run run_test_1, backstop 3600000 ms)"; ok_if "waiter armed with the run id" $?
grep -qF -- '--run run_test_1 --wait --timeout-ms 3600000' "$work/agent-team/elon-wait.sh"; ok_if "waiter script waits 3600000 ms on the run" $?
[ -x "$work/agent-team/elon-wait.sh" ]; ok_if "waiter script is executable" $?
has "job watch: every 5 minutes (300 s)"; ok_if "watch is named" $?
! has "PROBLEM"; ok_if "no problem flagged" $?

: >"$work/loop.running"; rm -f "$work/loop.calls"; run coordinator-a
has "job fleet-watch loop: found running"; ok_if "a running loop is found, not started twice" $?
[ ! -f "$work/loop.calls" ]; ok_if "no second start" $?

setup; run backup-a
has "skip elon jobs: this host may not dispatch"; ok_if "other host skips the jobs" $?
[ ! -f "$work/loop.calls" ] && [ ! -f "$work/agent-team/elon-wait.sh" ]; ok_if "other host starts and writes nothing" $?

setup; echo '{"runs":[]}' > "$work/home/.claude/state/fleet-watch-elon.json"; run coordinator-a
has "PROBLEM waiter not armed: no run id"; ok_if "no run id is flagged" $?

setup; rm "$work/home/.claude/state/fleet-watch-elon.json"; run coordinator-a
has "PROBLEM fleet-watch loop not started: no config"; ok_if "no config is flagged, loop not started" $?
[ ! -f "$work/loop.calls" ]; ok_if "no config means no start" $?

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
