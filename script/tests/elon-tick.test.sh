#!/usr/bin/env bash
# elon-tick.sh (#1790) against fake gh, orca, pgrep, worker-watch, fleet-watch automation status and log, and mailbox.
# Each case starts from a healthy fixture (prints OK), breaks one thing, and expects that check's ACTION line.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tests=0

mkdir -p "$work/bin"
# Fakes log every call. Any verb other than the reads elon-tick needs exits 9, so a write fails the case.
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$FX/calls"
[[ "$1 $2 $5 $6" == "pr list --state open" || "$1 $2 $5 $6" == "issue list --state open" ]] \
  || { echo "MUTATE gh $*" >> "$FX/calls"; exit 9; }
f="$FX/gh-$1-${4//\//_}.json"
[[ -e "$f.fail" ]] && exit 1
if [[ -e "$f" ]]; then cat "$f"; else echo '[]'; fi
GH
cat > "$work/bin/orca" <<'ORCA'
#!/usr/bin/env bash
echo "orca $*" >> "$FX/calls"
case "$1 $2" in
  "environment list") cat "$FX/envs.json" ;;
  "orchestration task-list")
    if [[ " $* " == *" --full "* ]]; then cat "$FX/tasks-full.json"; else cat "$FX/tasks.json"; fi ;;
  "orchestration worker-list")
    host=local
    [[ " $* " =~ \ --on\ ([^ ]+) ]] && host=${BASH_REMATCH[1]}
    [[ " $* " =~ \ --terminal-state\ ([^ ]+) ]] && state=${BASH_REMATCH[1]}
    f="$FX/workers-$host-$state.json"
    [[ " $* " =~ \ --cursor\ ([^ ]+) ]] && f="$FX/workers-$host-$state-${BASH_REMATCH[1]}.json"
    [[ -e "$FX/workers-$host.fail" ]] && exit 1
    if [[ -e "$f" ]]; then cat "$f"; else echo '{"ok":true,"result":{"workers":[]}}'; fi ;;
  *) echo "MUTATE orca $*" >> "$FX/calls"; exit 9 ;;
esac
ORCA
cat > "$work/bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
echo "pgrep $*" >> "$FX/calls"
[[ -e "$FX/waiter" && "$*" == *"--run run_t"*"--wait"* ]]
PGREP
chmod +x "$work/bin/"*

now=$(date +%s)

# Healthy fixture: one live owner on PR o/proj#50 (Closes #40) with Review PASS, nothing else waiting.
reset() {
  FX="$work/fx"
  rm -rf "$FX"; mkdir -p "$FX/root/.claude/bin"
  export FX
  cat > "$FX/config.json" <<EOF
{"pr_watch":{"repos":["o/proj","o/dot"]},"repo_roots":{"o/proj":"$FX/root"},"work_order":{"target_workers":1}}
EOF
  mkdir -p "$FX/home/.local/state/agent-team"
  heavy_state "$now" '{}' '[]'

  echo '{"ok":true,"result":{"environments":[]}}' > "$FX/envs.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"t1","status":"dispatched","title":"#40|fullstack-dev"}]}}' > "$FX/tasks.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"t1","task_title":"#40|fullstack-dev","spec":"Refs o/proj#40\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
  worker live in_progress > "$FX/workers-local-active.json"
  echo '[{"number":50,"title":"fix 40","body":"Closes #40","headRefName":"mingster/issue-40","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","comments":[{"body":"Review: PASS head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]' \
    > "$FX/gh-pr-o_proj.json"
  echo '[{"number":40,"title":"bug","body":"","labels":[]}]' > "$FX/gh-issue-o_proj.json"
  touch "$FX/waiter"
  # The fleet-watch automation (#1838): install-fleet-automations.sh --status output and the wrapper log, one finished pass now.
  printf 'fleet-watch: enabled\nwrap-up-daily: enabled\n' > "$FX/fw.status"
  fw_end 60
  printf '#!/usr/bin/env bash\necho "ctx_a term_a OK"\n' > "$FX/ww.sh"
  # check-fleet-status.py --count stand in (#2022): prints $FX/real (default 1, the one live row), exits 1 with $FX/real.fail.
  printf '#!/usr/bin/env bash\n[[ -e "$FX/real.fail" ]] && exit 1\ncat "$FX/real" 2>/dev/null || echo 1\n' > "$FX/rc.sh"
  printf '#!/usr/bin/env bash\necho "mailbox $*" >> "$FX/calls"\n' > "$FX/root/.claude/bin/support-mailbox.sh"
  : > "$FX/calls"
}

# heavy_state <at> <hosts json> <unread json> [open_asks json]: the fleet-watch state with its heavy job report (#2068).
heavy_state() {
  # macOS bash 3.2 keeps the backslash in "${4:-{\}}", so the default is set here instead.
  local asks=${4:-}
  [[ -n $asks ]] || asks='{}'
  printf '{"open_asks":%s,"heavy_jobs":{"at":%s,"hosts":%s,"unread":%s}}' "$asks" "$1" "$2" "$3" \
    > "$FX/home/.local/state/agent-team/fleet-watch.state.json"
}

# worker <liveness> <outcome> [workspace]: a worker-list reply with one row for dispatch ctx_a, task t1.
worker() {
  printf '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_a","taskId":"t1","state":"ready","outcome":"%s","liveness":"%s","terminalState":"active","workspace":"%s"}]}}' \
    "$2" "$1" "${3:-/x/workspaces/proj/issue-40}"
}

# workers "<dispatch> <task> <outcome> <workspace>"...: a worker-list reply with one live row per argument.
workers() {
  local rows='' sep='' d t o ws
  for row in "$@"; do
    read -r d t o ws <<<"$row"
    rows+="$sep{\"dispatchId\":\"$d\",\"taskId\":\"$t\",\"state\":\"ready\",\"outcome\":\"$o\",\"liveness\":\"live\",\"terminalState\":\"active\",\"workspace\":\"$ws\"}"
    sep=,
  done
  printf '{"ok":true,"result":{"workers":[%s]}}' "$rows"
}

# fw_end <seconds ago>: the wrapper log holds one phase=end line that old, stamped in local time like the wrapper.
fw_end() {
  printf '%s host=h automation=fleet-watch run=r phase=end exit=0 duration=30s summary=ok\n' \
    "$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - int(sys.argv[1]))))' "$1")" \
    > "$FX/fw.log"
}

tick() {
  set +e
  out=$(env -u FLEET_WATCH_STATE HOME="$FX/home" PATH="$work/bin:$PATH" ELON_TICK_FW_STATUS="cat $FX/fw.status" ELON_TICK_FW_LOG="$FX/fw.log" ELON_TICK_WORKER_WATCH="$FX/ww.sh" ELON_TICK_REAL_COUNT="bash $FX/rc.sh" \
    bash "$root/script/elon-tick.sh" --run run_t --config "$FX/config.json" 2>&1)
  rc=$?
  set -e
}

fail() { printf 'FAIL: %s\n%s\n' "$1" "$out" >&2; exit 1; }

expect() {
  local label=$1 want=$2
  tick
  [[ $out == *"$want"* ]] || fail "$label: expected \"$want\""
  [[ $rc -eq 1 ]] || fail "$label: exit $rc, want 1"
  [[ $out != *"OK nothing to do"* ]] || fail "$label: printed OK next to an action"
  ! grep -q MUTATE "$FX/calls" || fail "$label: a write call was made: $(grep MUTATE "$FX/calls")"
  tests=$((tests + 1))
}

reset; tick
[[ $out == "OK nothing to do" && $rc -eq 0 ]] || fail "healthy fixture prints OK"
tests=$((tests + 1))

# GitHub budget: one pr list and one issue list per repo, nothing else.
for kind in pr issue; do
  for repo in o/proj o/dot; do
    n=$(grep -c "^gh $kind list -R $repo " "$FX/calls" || true)
    [[ $n -eq 1 ]] || fail "budget: $n x gh $kind list $repo"
  done
done
[[ $(grep -c '^gh ' "$FX/calls") -eq 4 ]] || fail "budget: $(grep '^gh ' "$FX/calls")"
tests=$((tests + 1))

reset; printf 'fleet-watch: disabled\n' > "$FX/fw.status"
expect 'W1 automation disabled' '[W1] Orca automation fleet-watch is disabled'
reset; printf 'wrap-up-daily: enabled\n' > "$FX/fw.status"
expect 'W1 automation missing' '[W1] Orca automation fleet-watch is missing'
reset; fw_end 1200
expect 'W1 no pass for 10 minutes' '[W1] Orca automation fleet-watch finished no pass in the last 10 minutes'
reset; rm "$FX/fw.log"
expect 'W1 no log' '[W1] Orca automation fleet-watch finished no pass in the last 10 minutes'

# fleet-watch writes long head-checks receipts into the same log, after the phase=end line (#2014).
reset; for i in $(seq 300); do echo "  receipt line $i"; done >> "$FX/fw.log"; tick
[[ $out == "OK nothing to do" && $rc -eq 0 ]] || fail "W1 fresh pass followed by 300 receipt lines is not stale"
tests=$((tests + 1))

reset; rm "$FX/waiter"
expect 'M6 no waiter' '[M6] no inbox waiter for run_t'

reset; printf '#!/usr/bin/env bash\necho "ctx_a term_a IDLE > "\nexit 4\n' > "$FX/ww.sh"
expect 'W2 idle worker' '[W2] worker ctx_a is IDLE'

reset; heavy_state "$now" '{}' '[]' "{\"msg_1\":{\"at\":$((now - 3600)),\"dispatch\":\"ctx_a\",\"answered\":false}}"
expect 'W5 unanswered ask' '[W5] unanswered ask msg_1 from ctx_a for 60 minutes'

reset; heavy_state "$now" '{}' '[]' "{\"msg_1\":{\"at\":$((now - 60)),\"dispatch\":\"ctx_a\",\"answered\":false}}"
tick; [[ $out == "OK nothing to do" ]] || fail 'W5 a fresh ask is not an action'
tests=$((tests + 1))

reset; worker live in_progress /x/workspaces/proj/issue-41 > "$FX/workers-local-active.json"
echo '{"ok":true,"result":{"tasks":[{"id":"t1","title":"#41|fullstack-dev"}]}}' > "$FX/tasks.json"
echo '{"ok":true,"result":{"tasks":[]}}' > "$FX/tasks-full.json"
expect 'M1 orphan PR' '[M1] ORPHAN PR o/proj#50'

reset; rm "$FX/workers-local-active.json"
echo '{"ok":true,"result":{"environments":[{"id":"e1","name":"h1"}]}}' > "$FX/envs.json"
worker live in_progress > "$FX/workers-h1-active.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M1 a live owner on a paired host counts'
tests=$((tests + 1))

reset; touch "$FX/workers-h1.fail"
echo '{"ok":true,"result":{"environments":[{"id":"e1","name":"h1"}]}}' > "$FX/envs.json"
expect 'M1 unreadable host' '[M1] NOT CHECKED: host h1 worker list unreadable'

# A shared parent on a second Refs line (an epic) does not make a worker the owner of every PR under it.
reset; worker live in_progress /x/workspaces/proj/issue-41 > "$FX/workers-local-active.json"
echo '{"ok":true,"result":{"tasks":[{"id":"t1","title":"#41|fullstack-dev"}]}}' > "$FX/tasks.json"
echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#41\nRefs #40\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
echo '[{"number":50,"title":"fix 45","body":"Refs #40","headRefName":"mingster/issue-45","comments":[]},{"number":41,"title":"x","body":"","headRefName":"b","comments":[]}]' \
  > "$FX/gh-pr-o_proj.json"
expect 'M1 epic Refs is not ownership' '[M1] ORPHAN PR o/proj#50'

# M5 reads the task's own Refs line only; a closed epic on a later Refs line is not a defect.
reset; echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#40\nRefs #5, #6\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M5 later Refs line is not checked'
tests=$((tests + 1))

reset; printf '#!/usr/bin/env bash\necho "ctx_a term_a UNKNOWN_COVERAGE"\nexit 4\n' > "$FX/ww.sh"
expect 'W2 unreadable screen' '[W2] NOT CHECKED: worker ctx_a screen unreadable'

# A worker on an unverifiable host link, or in a retained terminal still in progress, is live (as in fleet-watch.py).
reset; worker unverifiable in_progress > "$FX/workers-local-active.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M1 unverifiable owner is live'
tests=$((tests + 1))

# worker-list pages: the owner on page 2 is found.
reset; printf '{"ok":true,"result":{"workers":[],"nextCursor":"c1"}}' > "$FX/workers-local-active.json"
worker live in_progress > "$FX/workers-local-active-c1.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M1 owner on the second worker-list page'
tests=$((tests + 1))

reset; worker live succeeded > "$FX/workers-local-active.json"
expect 'M2 done worker owns open PR' '[M2] do not release ctx_a yet: it owns open PR o/proj#50'

reset; rm "$FX/workers-local-active.json"
worker live succeeded | sed 's/"terminalState":"active"/"terminalState":"retained"/' > "$FX/workers-local-retained.json"
expect 'M2 retained done worker' '[M2] do not release ctx_a yet: it owns open PR o/proj#50'

# M2 stays quiet once the PR has a new live owner: the finished ctx_a may be released.
reset; workers "ctx_a t1 succeeded /x/workspaces/proj/issue-40" "ctx_b t1 in_progress /x/workspaces/proj/issue-40-b" \
  > "$FX/workers-local-active.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M2 a PR with a new live owner is not flagged'
tests=$((tests + 1))

# A verifier (verify-* worktree) is not an owner: alone it leaves the PR orphaned, and done it is not M2.
reset; workers "ctx_v t1 in_progress /x/workspaces/proj/verify-40" > "$FX/workers-local-active.json"
expect 'M1 a live verifier is not an owner' '[M1] ORPHAN PR o/proj#50'
reset; workers "ctx_a t1 in_progress /x/workspaces/proj/issue-40" "ctx_v t1 succeeded /x/workspaces/proj/verify-40" \
  > "$FX/workers-local-active.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M2 a finished verifier is not an owner'
tests=$((tests + 1))

# M8: ctx_h runs ready issue #44 and fleet-watch did not start it. The next issue is the P0 #46 before the older P2 #45.
m8() {
  workers "ctx_a t1 in_progress /x/workspaces/proj/issue-40" "ctx_h t2 in_progress /x/workspaces/proj/issue-44" \
    > "$FX/workers-local-active.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"t1","status":"dispatched","title":"#40|fullstack-dev"},{"id":"t2","status":"dispatched","title":"#44|fullstack-dev"}]}}' \
    > "$FX/tasks.json"
  local acc='## Acceptance\n- [ ] done'
  printf '[{"number":40,"title":"bug","body":"","labels":[]},
    {"number":44,"title":"a","body":"%s","labels":[{"name":"status:進行中"}],"createdAt":"2026-11-01T00:00:00Z"},
    {"number":45,"title":"b","body":"%s","labels":[{"name":"ready-for-agent"},{"name":"P2"}],"createdAt":"2026-11-02T00:00:00Z"},
    {"number":46,"title":"c","body":"%s","labels":[{"name":"ready-for-agent"},{"name":"P0"}],"createdAt":"2026-11-03T00:00:00Z"}]' \
    "$acc" "$acc" "$acc" > "$FX/gh-issue-o_proj.json"
}
reset; m8
expect 'M8 hand started ready issue' '[M8] ctx_h runs ready issue o/proj#44, which fleet-watch did not start'
[[ $out == *'[M8] next by the fleet-watch queue key: o/proj#46;'* ]] || fail 'M8 prints the next issue by the queue key'

reset; m8; printf '{"open_asks":{},"heavy_jobs":{"at":%d,"hosts":{},"unread":[]},"own_dispatches":{"ctx_h":{"kind":"issue"}}}' "$now" > "$FX/home/.local/state/agent-team/fleet-watch.state.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M8 a worker fleet-watch started is not flagged'
tests=$((tests + 1))

head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa old=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# pr50 <comment body>...: PR o/proj#50 at $head with these comments, oldest first.
pr50() {
  local c='' sep='' b
  for b in "$@"; do c+="$sep{\"body\":\"$b\"}"; sep=,; done
  printf '[{"number":50,"title":"fix 40","body":"Closes #40","headRefName":"mingster/issue-40","headRefOid":"%s","comments":[%s]}]' \
    "$head" "$c" > "$FX/gh-pr-o_proj.json"
}

reset; pr50 "Review: PASS head=$head" "Verdict: FAIL head=$head\\nmissing test"
expect 'M7 Verdict FAIL' "[M7] o/proj#50 latest receipt is \"Verdict: FAIL head=$head\"; send the defect to ctx_a"

reset; pr50 "Review: FAIL head=$head" "Verdict: PASS head=$head"
expect 'M7 Review FAIL beside a Verdict PASS' "[M7] o/proj#50 latest receipt is \"Review: FAIL head=$head\""

reset; pr50 "Verdict: FAIL head=$old" "Review: PASS head=$head"
tick; [[ $out == "OK nothing to do" ]] || fail 'M7 a FAIL at an older head is not current'
tests=$((tests + 1))

reset; pr50 "Review: FAIL head=$head" "Review: PASS head=$head"
tick; [[ $out == "OK nothing to do" ]] || fail 'M7 a newer PASS of the same kind replaces the FAIL'
tests=$((tests + 1))

reset; echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#40\nRole: fullstack-dev, rework PR 41"}]}}' > "$FX/tasks-full.json"
expect 'M5 closed PR in Role line' '[M5] brief of ctx_a names #41, which is closed or missing'

reset; echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#39\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
expect 'M5 closed Refs issue' '[M5] brief of ctx_a names #39, which is closed or missing in o/proj'

reset; echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":42,"title":"b","body":"Blocked by #40","labels":[{"name":"ready-for-agent"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'M4 ready but blocked' '[M4] o/proj#42 is ready-for-agent but waits on open #40; do not start it until they close'

reset; echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":43,"title":"b","body":"## Blocked by\n- #7","labels":[{"name":"blocked"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'M4 blocked with closed blockers' '[M4] o/proj#43 is labeled blocked but every blocker closed; relabel it ready-for-agent'

# A range ("#38 through #41") covers the open #40 between its ends.
reset; echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":43,"title":"b","body":"- Blocked by: #38 through #41.","labels":[{"name":"blocked"}]}]' \
  > "$FX/gh-issue-o_proj.json"
tick; [[ $out == "OK nothing to do" ]] || fail 'M4 a blocker range holds an open issue'
tests=$((tests + 1))

reset; echo '[{"number":40,"title":"bug","body":"Waiting on: vendor@example.com since 2026-11-20","labels":[]}]' > "$FX/gh-issue-o_proj.json"
# The real search prints `uid | date | from | subject | read` rows, then a `support-mailbox: N mail(s) shown` line.
printf '#!/usr/bin/env bash\necho "mailbox $*" >> "$FX/calls"\necho "7 | Fri, 21 Nov 2026 | vendor@example.com | Re: review | unread"\necho "support-mailbox: 1 mail(s) shown from INBOX."\n' \
  > "$FX/root/.claude/bin/support-mailbox.sh"
expect 'M3 vendor mail' '[M3] o/proj#40 waits on a vendor and the mailbox has 1 match(es): 7 | Fri, 21 Nov 2026 | vendor@example.com | Re: review | unread'
grep -q '^mailbox search --from vendor@example.com --limit 10 --since 2026-11-20$' "$FX/calls" || fail 'M3 mailbox args'

reset; echo '[{"number":40,"title":"bug","body":"Waiting on: vendor@example.com since 2026-11-20","labels":[]}]' > "$FX/gh-issue-o_proj.json"
printf '#!/usr/bin/env bash\necho "support-mailbox: 0 mail(s) shown from INBOX."\n' > "$FX/root/.claude/bin/support-mailbox.sh"
tick; [[ $out == "OK nothing to do" ]] || fail 'M3 no mail is not an action'
tests=$((tests + 1))

reset; echo '[{"number":40,"title":"bug","body":"Waiting on: vendor@example.com since 2026-11-20","labels":[]}]' > "$FX/gh-issue-o_proj.json"
printf '#!/usr/bin/env bash\necho "support-mailbox: no credential" >&2\nexit 1\n' > "$FX/root/.claude/bin/support-mailbox.sh"
expect 'M3 mailbox unreadable' '[M3] NOT CHECKED: o/proj#40 mailbox: support-mailbox: no credential'

reset; sed -i.bak 's/"target_workers":1/"target_workers":3/' "$FX/config.json"
echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":44,"title":"b","body":"## Acceptance\n- x","labels":[{"name":"ready-for-agent"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'W3 under target with supply' '[W3] 1 of 3 workers live and 1 ready issue(s); check fleet-watch is starting them (next by the fleet-watch queue key: o/proj#44;'

# #2022: W3 prints the real count (a live agent with recent activity), not Orca's rows. Orca lists 1 live row here.
reset; sed -i.bak 's/"target_workers":1/"target_workers":3/' "$FX/config.json"
echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":44,"title":"b","body":"## Acceptance\n- x","labels":[{"name":"ready-for-agent"}]}]' \
  > "$FX/gh-issue-o_proj.json"
echo 2 > "$FX/real"
expect 'W3 prints the real count' '[W3] 2 of 3 workers live (Orca lists 1) and 1 ready issue(s)'

reset; echo 0 > "$FX/real"
expect 'W3 real count below Orca rows' '[W3] 0 of 1 workers live (Orca lists 1) and no ready-for-agent issue'

reset; touch "$FX/real.fail"; sed -i.bak 's/"target_workers":1/"target_workers":3/' "$FX/config.json"
expect 'W3 falls back to Orca rows when the real count is unreadable' '[W3] 1 of 3 workers live and no ready-for-agent issue'

reset; echo '[{"number":40,"title":"bug","body":"","labels":[{"name":"needs-triage"}]}]' > "$FX/gh-issue-o_proj.json"
expect 'W4 triage queue' '[W4] o/proj has 1 needs-triage issue(s)'

# Fail closed: a source that cannot be read prints NOT CHECKED, never OK.
reset; touch "$FX/gh-pr-o_dot.json.fail"
expect 'gh pr list fails' '[M1] NOT CHECKED: gh pr list'

reset; touch "$FX/workers-local.fail"
expect 'orca worker-list fails' '[M1] NOT CHECKED: orca orchestration worker-list'

reset; python3 -c 'import json; print(json.dumps([{"number": n, "title": "", "body": "", "labels": []} for n in range(1000)]))' \
  > "$FX/gh-issue-o_dot.json"
expect 'issue list cut off at the limit' '[M4] NOT CHECKED: o/dot issue or PR list unreadable'

# H1 (#2068): running heavy jobs and orphans, from the report fleet-watch writes into its state each pass.
reset; heavy_state "$now" '{"host-a":{"env":"","jobs":[{"worker":"ctx_a","kind":"build","minutes":12},{"worker":"head-checks","kind":"tsc","minutes":3}],"orphans":[]}}' '[]'
expect 'H1 running heavy job' '[H1] heavy job on host-a: ctx_a runs build for 12 minutes'
[[ $out == *'[H1] heavy job on host-a: head-checks runs tsc for 3 minutes'* ]] || fail 'H1 lists every job'
reset; heavy_state "$now" '{"host-a":{"env":"","jobs":[],"orphans":[{"type":"sim","name":"verify-10779-se","id":"AAAA-1","minutes":300},{"type":"dev","name":"next-server","id":"4242","minutes":90}]}}' '[]'
expect 'H1 orphan simulator' '[H1] orphan simulator verify-10779-se on host-a, up 300 minutes, no live worker owns it; clean it up on that host with: xcrun simctl shutdown AAAA-1'
[[ $out == *'[H1] orphan dev server next-server on host-a, up 90 minutes'*'with: kill 4242'* ]] || fail 'H1 orphan dev server names kill'
reset; heavy_state "$now" '{}' '["h1"]'
expect 'H1 unreadable host' '[H1] NOT CHECKED: host h1 heavy jobs unreadable'
reset; heavy_state "$((now - 3600))" '{}' '[]'
expect 'H1 stale report' '[H1] NOT CHECKED: fleet-watch wrote no heavy job report'
reset; echo '{"open_asks":{}}' > "$FX/home/.local/state/agent-team/fleet-watch.state.json"
expect 'H1 no report' '[H1] NOT CHECKED: fleet-watch wrote no heavy job report'
reset; fw_end 1200
expect 'H1 stale fleet-watch' '[H1] NOT CHECKED: fleet-watch finished no recent pass'

# The mistakes table: both copies identical, every row names a check id that elon-tick prints and this file tests.
out=$(diff "$root/docs/agents/elon-mistakes.md" "$root/templates/agent-team/docs/agents/elon-mistakes.md" 2>&1) \
  || fail 'docs and template elon-mistakes.md differ'
ids=$(grep -oE '^\| [MWH][0-9]+ \|' "$root/docs/agents/elon-mistakes.md" | tr -d '| ')
[[ -n $ids ]] || fail 'elon-mistakes.md has no check rows'
for id in $ids; do
  grep -q "'\[$id\]" "$root/script/elon-tick.py" || fail "row $id has no check in elon-tick.py"
  grep -qE "[\"']\[$id\]" "$0" || fail "row $id has no case in this test"
done
for id in $(grep -oE "'\[[MWH][0-9]+\]" "$root/script/elon-tick.py" | tr -d "'[]" | sort -u); do
  grep -q "^| $id |" "$root/docs/agents/elon-mistakes.md" || fail "check $id has no row in elon-mistakes.md"
done
tests=$((tests + 1))

echo "elon-tick: $tests tests passed"
