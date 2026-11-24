#!/usr/bin/env bash
# elon-tick.sh (#1790) against fake gh, orca, pgrep, worker-watch, loop status and mailbox.
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
  echo '{"open_asks":{}}' > "$FX/state.json"
  echo '{"ok":true,"result":{"environments":[]}}' > "$FX/envs.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"t1","status":"dispatched","title":"#40|fullstack-dev"}]}}' > "$FX/tasks.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"t1","task_title":"#40|fullstack-dev","spec":"Refs o/proj#40\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
  worker live in_progress > "$FX/workers-local-active.json"
  echo '[{"number":50,"title":"fix 40","body":"Closes #40","headRefName":"mingster/issue-40","comments":[{"body":"Review: PASS at abc"}]}]' \
    > "$FX/gh-pr-o_proj.json"
  echo '[{"number":40,"title":"bug","body":"","labels":[]}]' > "$FX/gh-issue-o_proj.json"
  touch "$FX/loop" "$FX/waiter"
  printf '#!/usr/bin/env bash\necho "ctx_a term_a OK"\n' > "$FX/ww.sh"
  printf '#!/usr/bin/env bash\necho "mailbox $*" >> "$FX/calls"\n' > "$FX/root/.claude/bin/support-mailbox.sh"
  : > "$FX/calls"
}

# worker <liveness> <outcome> [workspace]: a worker-list reply with one row for dispatch ctx_a, task t1.
worker() {
  printf '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_a","taskId":"t1","state":"ready","outcome":"%s","liveness":"%s","terminalState":"active","workspace":"%s"}]}}' \
    "$2" "$1" "${3:-/x/workspaces/proj/issue-40}"
}

tick() {
  set +e
  out=$(PATH="$work/bin:$PATH" ELON_TICK_LOOP_STATUS="test -e $FX/loop" ELON_TICK_WORKER_WATCH="$FX/ww.sh" \
    bash "$root/script/elon-tick.sh" --run run_t --config "$FX/config.json" --state "$FX/state.json" 2>&1)
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

reset; rm "$FX/loop"
expect 'W1 loop down' '[W1] fleet-watch-loop is not running'

reset; rm "$FX/waiter"
expect 'M6 no waiter' '[M6] no inbox waiter for run_t'

reset; printf '#!/usr/bin/env bash\necho "ctx_a term_a IDLE > "\nexit 4\n' > "$FX/ww.sh"
expect 'W2 idle worker' '[W2] worker ctx_a is IDLE'

reset; printf '{"open_asks":{"msg_1":{"at":%d,"dispatch":"ctx_a","answered":false}}}' $((now - 3600)) > "$FX/state.json"
expect 'W5 unanswered ask' '[W5] unanswered ask msg_1 from ctx_a for 60 minutes'

reset; printf '{"open_asks":{"msg_1":{"at":%d,"dispatch":"ctx_a","answered":false}}}' $((now - 60)) > "$FX/state.json"
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

reset; worker live succeeded > "$FX/workers-local-active.json"
expect 'M2 done worker owns open PR' '[M2] do not release ctx_a yet: it owns open PR o/proj#50'

reset; echo '[{"number":50,"title":"fix 40","body":"Closes #40","headRefName":"mingster/issue-40","comments":[{"body":"Review: PASS at abc"},{"body":"Verdict: FAIL at abc\nmissing test"}]}]' \
  > "$FX/gh-pr-o_proj.json"
expect 'M7 Verdict FAIL' '[M7] o/proj#50 latest receipt is "Verdict: FAIL at abc"; send the defect to ctx_a'

reset; echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#40\nRole: fullstack-dev, rework PR 41"}]}}' > "$FX/tasks-full.json"
expect 'M5 closed PR in Role line' '[M5] brief of ctx_a names #41, which is closed or missing'

reset; echo '{"ok":true,"result":{"tasks":[{"id":"t1","spec":"Refs o/proj#39\nRole: fullstack-dev"}]}}' > "$FX/tasks-full.json"
expect 'M5 closed Refs issue' '[M5] brief of ctx_a names #39, which is closed or missing in o/proj'

reset; echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":42,"title":"b","body":"Blocked by #40","labels":[{"name":"ready-for-agent"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'M4 ready but blocked' '[M4] o/proj#42 is ready-for-agent but blocked by open #40; relabel it blocked'

reset; echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":43,"title":"b","body":"## Blocked by\n- #7","labels":[{"name":"blocked"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'M4 blocked with closed blockers' '[M4] o/proj#43 is labeled blocked but every blocker closed; relabel it ready-for-agent'

reset; echo '[{"number":40,"title":"bug","body":"Waiting on: vendor@example.com since 2026-11-20","labels":[]}]' > "$FX/gh-issue-o_proj.json"
printf '#!/usr/bin/env bash\necho "mailbox $*" >> "$FX/calls"\necho "2026-11-21 vendor@example.com Re: review"\n' > "$FX/root/.claude/bin/support-mailbox.sh"
expect 'M3 vendor mail' '[M3] o/proj#40 waits on a vendor and the mailbox has 1 match(es): 2026-11-21 vendor@example.com Re: review'
grep -q '^mailbox search --from vendor@example.com --limit 10 --since 2026-11-20$' "$FX/calls" || fail 'M3 mailbox args'

reset; echo '[{"number":40,"title":"bug","body":"Waiting on: vendor@example.com since 2026-11-20","labels":[]}]' > "$FX/gh-issue-o_proj.json"
printf '#!/usr/bin/env bash\necho "support-mailbox: no credential" >&2\nexit 1\n' > "$FX/root/.claude/bin/support-mailbox.sh"
expect 'M3 mailbox unreadable' '[M3] NOT CHECKED: o/proj#40 mailbox: support-mailbox: no credential'

reset; sed -i.bak 's/"target_workers":1/"target_workers":3/' "$FX/config.json"
echo '[{"number":40,"title":"bug","body":"","labels":[]},{"number":44,"title":"b","body":"","labels":[{"name":"ready-for-agent"}]}]' \
  > "$FX/gh-issue-o_proj.json"
expect 'W3 under target with supply' '[W3] 1 of 3 workers live and 1 ready-for-agent issue(s); start up to 1'

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

# The mistakes table: both copies identical, every row names a check id that elon-tick prints and this file tests.
out=$(diff "$root/docs/agents/elon-mistakes.md" "$root/templates/agent-team/docs/agents/elon-mistakes.md" 2>&1) \
  || fail 'docs and template elon-mistakes.md differ'
ids=$(grep -oE '^\| [MW][0-9]+ \|' "$root/docs/agents/elon-mistakes.md" | tr -d '| ')
[[ -n $ids ]] || fail 'elon-mistakes.md has no check rows'
for id in $ids; do
  grep -q "'\[$id\]" "$root/script/elon-tick.py" || fail "row $id has no check in elon-tick.py"
  grep -q "'\[$id\]" "$0" || fail "row $id has no case in this test"
done
for id in $(grep -oE "'\[[MW][0-9]+\]" "$root/script/elon-tick.py" | tr -d "'[]" | sort -u); do
  grep -q "^| $id |" "$root/docs/agents/elon-mistakes.md" || fail "check $id has no row in elon-mistakes.md"
done
tests=$((tests + 1))

echo "elon-tick: $tests tests passed"
