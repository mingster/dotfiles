#!/usr/bin/env bash
# elon-startup.sh section 6 (#1778, #1838): on the coordinator host it checks that the Orca automation fleet-watch is enabled
# (it starts no loop), writes the waiter script and names the 5 minute watch. Other hosts check and write nothing.
# Temp HOME, fixture state repo, stub automation status script.
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
# Stub status: prints what install-fleet-automations.sh --status would, from $work/fw.status (missing when absent).
cat >"$work/script/fw-status.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>"$STATUS_DIR/status.calls"
echo "fleet-watch: $(cat "$STATUS_DIR/fw.status" 2>/dev/null || echo missing)"
echo "wrap-up-daily: enabled"
STUB
chmod +x "$work/bin/hostname" "$work/home/.claude/state/fleet-load.sh" "$work/script/fw-status.sh"
echo '{"hosts":[],"repos":[]}' > "$work/fleet.json"
echo '{"runs":[{"id":"run_test_1"}]}' > "$work/home/.claude/state/fleet-watch-elon.json"

setup() {
  rm -rf "$work/origin.git" "$work/seed" "$work/state" "$work/status.calls" "$work/agent-team"/*
  echo enabled >"$work/fw.status"
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
  OUT=$(cd "$work/cwd" && FAKE_HOST="$1" HOME="$work/home" PATH="$work/bin:$PATH" AGENT_STATE_DIR="$work/state" STATUS_DIR="$work" \
    ELON_STATE_DIR="$work/agent-team" FLEET_AUTOMATION_STATUS_CMD="$work/script/fw-status.sh" \
    FLEET_PULL_CONFIG="$work/fleet.json" GIT_TERMINAL_PROMPT=0 bash "$work/script/elon-startup.sh" --no-pull 2>&1)
  RC=$?
}
ok_if() { # ok_if <name> <condition exit code>
  if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; echo "$OUT" | sed 's/^/     /'; fi
}
has() { grep -qF -- "$1" <<<"$OUT"; }
set +e # a failed check is counted by ok_if, not fatal

setup; run coordinator-a
has "job fleet-watch: Orca automation enabled"; ok_if "coordinator finds the automation enabled" $?
! has "fleet-watch-loop" && ! has "fleet-watch loop"; ok_if "no loop is started or named" $?
has "job waiter: armed, script $work/agent-team/elon-wait.sh (run run_test_1, backstop 3600000 ms)"; ok_if "waiter armed with the run id" $?
grep -qF -- '--run run_test_1 --wait --timeout-ms 3600000' "$work/agent-team/elon-wait.sh"; ok_if "waiter script waits 3600000 ms on the run" $?
[ -x "$work/agent-team/elon-wait.sh" ]; ok_if "waiter script is executable" $?
has "job watch: every 5 minutes (300 s)"; ok_if "watch is named" $?
! has "PROBLEM"; ok_if "no problem flagged" $?

setup; echo disabled >"$work/fw.status"; run coordinator-a
has "PROBLEM fleet-watch automation is disabled"; ok_if "a disabled automation is flagged" $?

setup; rm -f "$work/fw.status"; run coordinator-a
has "PROBLEM fleet-watch automation is missing"; ok_if "a missing automation is flagged" $?

setup; run backup-a
has "skip elon jobs: this host may not dispatch"; ok_if "other host skips the jobs" $?
[ ! -f "$work/status.calls" ] && [ ! -f "$work/agent-team/elon-wait.sh" ]; ok_if "other host checks and writes nothing" $?

setup; echo '{"runs":[]}' > "$work/home/.claude/state/fleet-watch-elon.json"; run coordinator-a
has "PROBLEM waiter not armed: no run id"; ok_if "no run id is flagged" $?

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
