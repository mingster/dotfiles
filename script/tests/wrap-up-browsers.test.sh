#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# wrap-up browser sweep: fake process table, fake stop command and a disposable repo only. Never touches real processes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/cwd"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
echo '[]'
FAKE
# Fake orca. FAKE_ACTIVE_CWD adds one running dispatch whose terminal sits in that path; FAKE_ORCA_BAD breaks the inventory.
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') [ -z "${FAKE_ORCA_BAD:-}" ] || exit 1; echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'orchestration worker-list --json')
    if [ -n "${FAKE_ACTIVE_CWD:-}" ]; then echo '{"ok":true,"result":{"workers":[{"dispatchId":"d1","dispatchStatus":"running"}],"page":{"hasMore":false}}}'
    else echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'; fi ;;
  'orchestration worker-show --dispatch d1 --json') printf '{"ok":true,"result":{"state":"running","task":"%s","terminal":{"cwd":"%s"}}}\n' "${FAKE_ACTIVE_TASK:-edit docs}" "$FAKE_ACTIVE_CWD" ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
# Fake process seam: "list" prints pid, ppid, age in seconds, start, command (tab separated); "show <pid>" prints one such line
# (FAKE_PS_NOW overrides the table, to model a reused pid); "cwd <pid>" prints the working directory or fails.
cat > "$tmp/ps-seam" <<'FAKE'
#!/usr/bin/env bash
table=${FAKE_PS_NOW:-$FAKE_PS}
case "$1" in
  list) cat "$FAKE_PS" ;;
  show) awk -F'\t' -v p="$2" '$1 == p' "$table" ;;
  cwd) [ -f "$FAKE_CWDS/$2" ] || exit 1; cat "$FAKE_CWDS/$2" ;;
esac
FAKE
cat > "$tmp/kill-seam" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_KILLS"
case " ${FAKE_KILL_FAIL:-} " in *" $1 "*) exit 1 ;; esac
exit 0
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/lsof" "$tmp/ps-seam" "$tmp/kill-seam"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export TMPDIR="$tmp/mytmp/"
mkdir -p "$HOME" "$TMPDIR"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
export FAKE_PS="$tmp/ps-table" FAKE_CWDS="$tmp/cwd" FAKE_KILLS="$tmp/kills"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
has() { grep -Fxq -- "$1" "$tmp/output"; }
lacks() { ! grep -Fq -- "$1" "$tmp/output"; }
killed() { grep -Fxq -- "$1" "$FAKE_KILLS" 2>/dev/null; }
nokill() { [ ! -s "$FAKE_KILLS" ]; }
T=$'\t'
# proc <pid> <ppid> <age seconds> <command...>: one process table line; the start is derived from the pid.
proc() { local pid=$1 ppid=$2 age=$3; shift 3; printf '%s\t%s\t%s\tstart-%s\t%s\n' "$pid" "$ppid" "$age" "$pid" "$*" >> "$FAKE_PS"; }
cwd() { printf '%s\n' "$2" > "$FAKE_CWDS/$1"; }
reset() { : > "$FAKE_PS"; : > "$FAKE_KILLS"; rm -f "${FAKE_CWDS:?}"/*; unset FAKE_PS_NOW FAKE_KILL_FAIL FAKE_ACTIVE_CWD FAKE_ACTIVE_TASK FAKE_ORCA_BAD; }
run() { (cd "$tmp/repo" && WRAP_UP_PS_CMD="$tmp/ps-seam" WRAP_UP_KILL_CMD="$tmp/kill-seam" bash "$root/script/wrap-up.sh" "$@" > "$tmp/output" 2>&1); }
DEV='/Applications/Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev'
STABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
CHROMIUM='/Users/someone/Library/Caches/ms-playwright/chromium-1/chrome-mac/Chromium.app/Contents/MacOS/Chromium'
OLD=90000

# Candidates: throwaway profiles under every temp root, stale.
reset
proc 101 1 $OLD "$DEV --user-data-dir=/private/var/folders/xx/T/pw-profile-1 --remote-debugging-port=0"; cwd 101 /Users/someone/work
proc 102 1 $OLD "$CHROMIUM --user-data-dir=/tmp/pw-profile-2 --no-first-run"; cwd 102 /Users/someone/work
proc 103 1 $OLD "$DEV --user-data-dir=${TMPDIR}own-profile"; cwd 103 /Users/someone/work
proc 104 1 $OLD "$DEV --user-data-dir=/private/tmp/pw-profile-4"; cwd 104 /Users/someone/work
run --dry-run
check 'preview lists stale throwaway Chrome Dev' has 'Close browser 101 (stale throwaway browser profile)'
check 'preview lists stale throwaway Chromium' has 'Close browser 102 (stale throwaway browser profile)'
check 'preview lists a profile under $TMPDIR' has 'Close browser 103 (stale throwaway browser profile)'
check 'preview lists a profile under /private/tmp' has 'Close browser 104 (stale throwaway browser profile)'
check 'preview stops nothing' nokill
check 'preview prints a count line' has 'browsers closed=4 kept=0'
run --apply
check 'apply stops the throwaway browsers by pid' test "$(sort "$FAKE_KILLS" | tr '\n' ' ')" = '101 102 103 104 '
check 'apply count line' has 'browsers closed=4 kept=0'

# Never candidates, by construction.
reset
proc 201 1 $OLD "$STABLE --user-data-dir=/tmp/pw-profile"; cwd 201 /Users/someone/work
proc 202 1 $OLD "$DEV --user-data-dir=/Users/someone/.cursor/chrome-dev-agent-profile --remote-debugging-port=9223"; cwd 202 /Users/someone/work
proc 203 1 $OLD "$DEV --user-data-dir=/Users/someone/Library/Application Support/Google/Chrome Dev"; cwd 203 /Users/someone/work
proc 204 1 $OLD "$STABLE"; cwd 204 /Users/someone/work
proc 205 1 $OLD "$DEV --type=renderer --user-data-dir=/tmp/pw-profile"; cwd 205 /Users/someone/work
proc 206 1 $OLD "$DEV"; cwd 206 /Users/someone/work
proc 207 1 $OLD "$DEV --user-data-dir=/tmp/../Users/someone/real-profile"; cwd 207 /Users/someone/work
proc 208 1 $OLD "$DEV --user-data-dir=/tmpfoo/profile"; cwd 208 /Users/someone/work
run --apply
check 'stable Chrome is never a candidate, even on a temp profile' lacks 'browser 201'
check 'the shared agent profile is never a candidate' lacks 'browser 202'
check 'a personal profile outside temp is never a candidate' lacks 'browser 203'
check 'stable Chrome without a profile is never a candidate' lacks 'browser 204'
check 'a helper process is never a candidate' lacks 'browser 205'
check 'a browser without a profile path is never a candidate' lacks 'browser 206'
check 'a profile that climbs out of temp is never a candidate' lacks 'browser 207'
check 'a path that only starts like a temp root is never a candidate' lacks 'browser 208'
check 'nothing was stopped' nokill

# Keep rules.
reset
proc 300 1 10 "some test runner"
proc 301 1 600 "$DEV --user-data-dir=/tmp/young"; cwd 301 /Users/someone/work
proc 302 300 $OLD "$DEV --user-data-dir=/tmp/owned"; cwd 302 /Users/someone/work
proc 303 987654 $OLD "$DEV --user-data-dir=/tmp/orphan"; cwd 303 /Users/someone/work
proc 304 1 $OLD "$DEV --user-data-dir=/tmp/unreadable"
proc 305 1 $OLD "$DEV --user-data-dir=/tmp/busy-cwd"; cwd 305 "$tmp/busy/sub"
proc 306 1 $OLD "$DEV --user-data-dir=$tmp/busy/profile"; cwd 306 /Users/someone/work
mkdir -p "$tmp/busy/sub" "$tmp/busy/profile"
export FAKE_ACTIVE_CWD="$tmp/busy"
run --apply
check 'younger than 2 hours is kept' has 'Kept browser 301 (younger than 2 hours)'
check 'a live parent that is not pid 1 keeps it' has 'Kept browser 302 (parent still running)'
check 'a parent that is gone does not keep it' has 'Close browser 303 (stale throwaway browser profile)'
check 'unreadable working directory is kept' has 'Kept browser 304 (working directory unreadable)'
check 'working directory in an active path is kept' has 'Kept browser 305 (inside an active dispatch path)'
check 'profile in an active path is kept' has 'Kept browser 306 (inside an active dispatch path)'
check 'only the orphan was stopped' test "$(cat "$FAKE_KILLS")" = 303
check 'count line with kept' has 'browsers closed=1 kept=5'

# A running head-checks, QA or gated run shows a temp-profile browser in use, whatever its parent pid.
reset
proc 450 1 $OLD "$DEV --user-data-dir=/tmp/in-use"; cwd 450 /Users/someone/work
proc 451 1 $OLD "/opt/agent-browser/bin/agent-browser daemon"; cwd 451 /Users/someone/work
proc 452 900 100 "bash /repo/script/head-checks.sh"
run --apply
check 'old browser with parent pid 1 stays during a head-checks run' has 'Kept browser 450 (a head-checks, QA or gated run is active)'
check 'old daemon with parent pid 1 stays during a head-checks run' has 'Kept browser 451 (a head-checks, QA or gated run is active)'
check 'a run in progress stops nothing' nokill
for runcmd in 'python3 /repo/script/qa-admission.py admit' 'python3 /repo/script/heavy-gate.py gate -- npm test'; do
  reset
  proc 460 1 $OLD "$DEV --user-data-dir=/tmp/in-use"; cwd 460 /Users/someone/work
  proc 461 900 100 "$runcmd"
  run --apply
  check "a running '${runcmd%% *}' $(printf '%s' "$runcmd" | awk '{print $2}') keeps the browser" has 'Kept browser 460 (a head-checks, QA or gated run is active)'
done
reset
proc 470 1 $OLD "$DEV --user-data-dir=/tmp/idle"; cwd 470 /Users/someone/work
proc 471 900 100 "bash /repo/script/wrap-up.sh --apply"
run --apply
check 'with no such run, the old browser with parent pid 1 still closes' has 'Close browser 470 (stale throwaway browser profile)'

# The run check reads the command, not a substring: "wrap-up" in a path or argument does not hide a run.
for runcmd in 'bash /work/wrap-up-fix/script/head-checks.sh --pr 1' 'python3 /repo/script/heavy-gate.py gate -- bash script/tests/wrap-up-browsers.test.sh' '/usr/bin/env python3 -I /repo/script/qa-admission.py admit wrap-up'; do
  reset
  proc 480 1 $OLD "$DEV --user-data-dir=/tmp/in-use"; cwd 480 /Users/someone/work
  proc 481 900 100 "$runcmd"
  run --apply
  check "a run with wrap-up in its arguments keeps the browser: ${runcmd:0:48}" has 'Kept browser 480 (a head-checks, QA or gated run is active)'
done

# An active dispatch that names a QA, browser, head-checks or gated run counts as a run, though no such process is left.
reset
mkdir -p "$tmp/elsewhere"
proc 490 1 $OLD "$DEV --user-data-dir=/tmp/dispatch-run"; cwd 490 /Users/someone/work
proc 491 1 $OLD "/opt/agent-browser/bin/agent-browser daemon"; cwd 491 /Users/someone/work
export FAKE_ACTIVE_CWD="$tmp/elsewhere" FAKE_ACTIVE_TASK='run the QA pass in the browser'
run --apply
check 'a dispatch that runs QA keeps the old browser' has 'Kept browser 490 (a head-checks, QA or gated run is active)'
check 'a dispatch that runs QA keeps the old daemon' has 'Kept browser 491 (a head-checks, QA or gated run is active)'
check 'a dispatch that runs QA stops nothing' nokill
reset
proc 492 1 $OLD "$DEV --user-data-dir=/tmp/dispatch-docs"; cwd 492 /Users/someone/work
export FAKE_ACTIVE_CWD="$tmp/elsewhere" FAKE_ACTIVE_TASK='edit the docs'
run --apply
check 'a dispatch that is not a run leaves the old browser to close' has 'Close browser 492 (stale throwaway browser profile)'

# Active holds "*", inventory broken, inventory never read: keep everything.
reset
proc 401 1 $OLD "$DEV --user-data-dir=/tmp/a"; cwd 401 /Users/someone/work
proc 402 1 $OLD "agent-browser daemon"; cwd 402 /Users/someone/work
export FAKE_ORCA_BAD=1
run --apply
check 'broken inventory keeps the Chrome' has 'Kept browser 401 (no complete dispatch inventory)'
check 'broken inventory keeps the daemon' has 'Kept browser 402 (no complete dispatch inventory)'
check 'broken inventory stops nothing' nokill
unset FAKE_ORCA_BAD
(cd "$tmp/repo" && ORCA_CLI_COMMAND="$tmp/nonexistent-orca" WRAP_UP_PS_CMD="$tmp/ps-seam" WRAP_UP_KILL_CMD="$tmp/kill-seam" bash "$root/script/wrap-up.sh" --dry-run > "$tmp/output" 2>&1)
check 'no Orca, so no inventory read: keeps everything' has 'Kept browser 401 (no complete dispatch inventory)'
(cd "$tmp/repo" && ORCA_CLI_COMMAND="$tmp/nonexistent-orca" WRAP_UP_PS_CMD="$tmp/ps-seam" WRAP_UP_KILL_CMD="$tmp/kill-seam" bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1) || true
check 'no inventory on apply stops nothing' nokill

# agent-browser daemons.
reset
proc 500 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64 daemon"; cwd 500 /Users/someone/work
proc 520 1 $OLD "node /opt/agent-browser/dist/daemon.js"; cwd 520 /Users/someone/work
proc 521 520 $OLD "$DEV --user-data-dir=/tmp/daemon-owned"; cwd 521 /Users/someone/work
proc 530 1 600 "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64 daemon"; cwd 530 /Users/someone/work
run --apply
check 'orphan daemon with no browser anywhere is closed' has 'Close browser 500 (stale agent-browser daemon)'
check 'daemon with a throwaway child is closed' has 'Close browser 520 (stale agent-browser daemon)'
check 'its child waits a round, its parent is still running' has 'Kept browser 521 (parent still running)'
check 'young daemon is kept' has 'Kept browser 530 (younger than 2 hours)'
check 'stopped: 500 and 520 only' test "$(sort "$FAKE_KILLS" | tr '\n' ' ')" = '500 520 '

# A daemon may be connected over CDP to a browser it did not start, outside temp. It has no child to show for it.
reset
proc 510 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64 daemon"; cwd 510 /Users/someone/work
proc 511 510 $OLD "$DEV --user-data-dir=/Users/someone/.cursor/chrome-dev-agent-profile --remote-debugging-port=9223"; cwd 511 /Users/someone/work
proc 512 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64 daemon"; cwd 512 /Users/someone/work
proc 513 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64 daemon --cdp 9223"; cwd 513 /Users/someone/work
run --apply
check 'daemon with a browser child outside temp is kept' has 'Kept browser 510 (drives a browser outside temp)'
check 'the shared browser itself is not a candidate' lacks 'browser 511'
check 'daemon with no child, while a browser outside temp offers a debugging port, is kept' has 'Kept browser 512 (drives a browser outside temp)'
check 'daemon started with --cdp is kept' has 'Kept browser 513 (drives a browser outside temp)'
check 'nothing was stopped' nokill

# A live daemon has no arguments, and the browser it drives may be stable Chrome with a debugging port.
reset
proc 540 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64"; cwd 540 /Users/someone/work
proc 541 1 $OLD "$STABLE --user-data-dir=/Users/someone/chrome-profile --remote-debugging-port=9222"; cwd 541 /Users/someone/work
run --apply
check 'daemon with no arguments, while stable Chrome outside temp offers a debugging port, is kept' has 'Kept browser 540 (drives a browser outside temp)'
check 'stable Chrome itself is not a candidate' lacks 'browser 541'
check 'stable Chrome case stops nothing' nokill
reset
proc 550 1 $OLD "/opt/homebrew/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64"; cwd 550 /Users/someone/work
proc 551 550 $OLD "$STABLE --user-data-dir=/Users/someone/chrome-profile"; cwd 551 /Users/someone/work
run --apply
check 'daemon whose child is stable Chrome outside temp is kept' has 'Kept browser 550 (drives a browser outside temp)'

# Reused pid, failed stop.
reset
proc 601 1 $OLD "$DEV --user-data-dir=/tmp/reuse"; cwd 601 /Users/someone/work
proc 602 1 $OLD "$DEV --user-data-dir=/tmp/stubborn"; cwd 602 /Users/someone/work
proc 603 1 $OLD "$DEV --user-data-dir=/tmp/gone"; cwd 603 /Users/someone/work
{ printf '601\t1\t5\tstart-NEW\t/usr/bin/some-other-program\n'; printf '602\t1\t%s\tstart-602\t%s\n' "$OLD" "$DEV --user-data-dir=/tmp/stubborn"; } > "$tmp/ps-now"
export FAKE_PS_NOW="$tmp/ps-now" FAKE_KILL_FAIL=602
run --apply
check 'a reused pid is not stopped' test ! "$(killed 601 && echo yes)"
check 'a reused pid is reported as kept' has 'Kept browser 601 (process changed since listed)'
check 'a pid that vanished is reported as kept' has 'Kept browser 603 (process changed since listed)'
check 'a failed stop is reported as kept' has 'Kept browser 602 (stop failed)'
check 'failed and reused stops count as kept' has 'browsers closed=0 kept=3'

# Fleet hosts sweep too: --worktrees-only runs the sweep before it exits.
reset
proc 701 1 $OLD "$DEV --user-data-dir=/tmp/fleet-profile"; cwd 701 /Users/someone/work
run --worktrees-only --apply
check '--worktrees-only closes the throwaway browser too' killed 701
check '--worktrees-only prints the count line' has 'browsers closed=1 kept=0'

# Safety: in test mode (ORCA_CLI_COMMAND set) without both seams, the sweep never reaches real ps or kill.
reset
rm -rf "$tmp/guardbin"; mkdir -p "$tmp/guardbin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/ps-calls"\nexit 0\n' "$tmp" > "$tmp/guardbin/ps"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/kill-calls"\nexit 0\n' "$tmp" > "$tmp/guardbin/kill"
chmod +x "$tmp/guardbin/ps" "$tmp/guardbin/kill"
rm -f "$tmp/ps-calls" "$tmp/kill-calls"
proc 801 1 $OLD "$DEV --user-data-dir=/tmp/guard"; cwd 801 /Users/someone/work
for mode in none ps-only kill-only; do
  case "$mode" in
    none) env=() ;;
    ps-only) env=(WRAP_UP_PS_CMD="$tmp/ps-seam") ;;
    kill-only) env=(WRAP_UP_KILL_CMD="$tmp/kill-seam") ;;
  esac
  : > "$FAKE_KILLS"
  (cd "$tmp/repo" && PATH="$tmp/guardbin:$PATH" env ${env[@]+"${env[@]}"} bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1)
  check "guard ($mode): sweep prints nothing" lacks 'browser'
  check "guard ($mode): no stop" nokill
done
real_ps_read() { [ -e "$tmp/ps-calls" ] && grep -q 'lstart' "$tmp/ps-calls"; }
check 'guard: the real process list was never read' test ! "$(real_ps_read && echo yes)"

check 'guard: the real kill was never used' test ! -e "$tmp/kill-calls"
# No kill-by-name or untrusted signals anywhere in the script.
check 'wrap-up.sh has no pkill, killall or KILL' test -z "$(grep -En 'pkill|killall|kill -(9|KILL)|-KILL|SIGKILL' "$root/script/wrap-up.sh" || true)"

printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
