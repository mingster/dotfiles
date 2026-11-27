#!/usr/bin/env bash
# settle-orphan-task.sh (#2022) against a fake orca. Each case sets the fake's answers with files in $FX and checks
# the exit code, the output and which mutating calls (task-update, worker-abandon) were made.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tests=0

cat > "$work/orca" <<'ORCA'
#!/usr/bin/env bash
echo "$*" >> "$FX/calls"
env=local
[[ " $* " =~ \ --environment\ ([^ ]+) ]] && env=${BASH_REMATCH[1]}
case "$1 $2" in
  "environment list") cat "$FX/envs.json" ;;
  "orchestration task-list") cat "$FX/tasks.json" ;;
  "orchestration dispatch-show")
    [[ -e "$FX/show-$env.fail" ]] && { echo '{"ok":false,"error":{"message":"unreachable"}}'; exit 1; }
    if [[ -e "$FX/dispatch-$env" ]]; then echo '{"ok":true,"result":{"dispatch":{"id":"ctx_x"}}}'
    else echo '{"ok":true,"result":{"dispatch":null}}'; fi ;;
  "orchestration task-update")
    if [[ -e "$FX/update-refuses" && ! -e "$FX/abandoned" ]]; then
      echo '{"ok":false,"error":{"message":"cannot move to failed while supervised Dispatch (a start on a paired server) is active"}}'; exit 1
    fi
    echo '{"ok":true,"result":{"task":{"status":"failed"}}}' ;;
  "orchestration worker-list")
    echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_9","taskId":"task_o","outcome":"in_progress"}]}}' ;;
  "orchestration worker-abandon") touch "$FX/abandoned"; echo '{"ok":true,"result":{}}' ;;
  *) echo "UNEXPECTED $*" >> "$FX/calls"; exit 9 ;;
esac
ORCA
chmod +x "$work/orca"

reset() {
  FX="$work/fx"; rm -rf "$FX"; mkdir -p "$FX"; export FX
  echo '{"ok":true,"result":{"environments":[{"id":"env_1","name":"remote"}]}}' > "$FX/envs.json"
  echo '{"ok":true,"result":{"tasks":[{"id":"task_o","status":"dispatched"},{"id":"task_d","status":"completed"}]}}' > "$FX/tasks.json"
  : > "$FX/calls"
}

settle() {
  set +e
  out=$(ORCA_CLI_COMMAND="$work/orca" bash "$root/script/settle-orphan-task.sh" "$@" 2>&1)
  rc=$?
  set -e
}

fail() { printf 'FAIL: %s\n%s\n--- calls\n%s\n' "$1" "$out" "$(cat "$FX/calls")" >&2; exit 1; }
want() { [[ $rc -eq $1 ]] || fail "$3: exit $rc, want $1"; [[ $out == *"$2"* ]] || fail "$3: expected \"$2\""; tests=$((tests + 1)); }
mutated() { grep -qE 'task-update|worker-abandon' "$FX/calls"; }

reset; settle --run run_1 --task task_o
want 0 'settled task_o: failed' 'orphan settles'
grep -q 'dispatch-show --task task_o --environment env_1' "$FX/calls" || fail 'checked the paired server'
grep -q 'task-update --id task_o --status failed' "$FX/calls" || fail 'task-update ran'

reset; touch "$FX/dispatch-local"; settle --run run_1 --task task_o
want 1 'has a dispatch record on local' 'local dispatch refuses'
! mutated || fail 'local dispatch: nothing is changed'

reset; touch "$FX/dispatch-env_1"; settle --run run_1 --task task_o
want 1 'has a dispatch record on remote' 'paired dispatch refuses'
! mutated || fail 'paired dispatch: nothing is changed'

reset; touch "$FX/show-env_1.fail"; settle --run run_1 --task task_o
want 1 'cannot read dispatch-show on remote' 'unreadable server refuses'
! mutated || fail 'unreadable server: nothing is changed'

reset; touch "$FX/update-refuses"; settle --run run_1 --task task_o
want 0 'fenced ctx_9 on local' 'refusal is fenced then settled'
want 0 'settled task_o' 'refusal is fenced then settled'
grep -q 'worker-abandon --dispatch ctx_9' "$FX/calls" || fail 'abandon ran'

reset; settle --run run_1 --task task_o --dry-run
want 0 'dry run: would mark task_o failed' 'dry run'
! mutated || fail 'dry run: nothing is changed'

reset; settle --run run_1 --task task_d
want 0 'already completed' 'settled task is a no-op'
! mutated || fail 'settled task: nothing is changed'

reset; settle --run run_1 --task task_none
want 1 'is not a task of run_1' 'unknown task'

reset; settle --run run_1
want 2 'Usage:' 'usage'

echo "settle-orphan-task.test.sh: $tests checks passed"
