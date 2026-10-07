#!/usr/bin/env bash
# Start an Orca worker on Codex without the agent_readiness failure (codex 0.160.1):
# Orca only sees a Codex terminal as ready after Codex has finished one turn, so open the
# Codex terminal first, give it a one line warm-up turn, then hand it the task.
# Usage: start-codex-worker.sh --run <run_id> --spec <file> --title <text>
#          (--worktree-path <path> | --name <new worktree> --repo <path> [--base-branch origin/main])
#          [--model gpt-6.1-sol] [--effort medium]
# Prints the dispatch id and terminal handle; exits 1 if the dispatch is not running.
set -u
poll="${START_CODEX_POLL:-3}"; orca="${ORCA_CLI_COMMAND:-orca}"; model=gpt-6.1-sol; effort=medium; base=origin/main
run= spec= title= wt= name= repo=
while [ $# -gt 0 ]; do case "$1" in
  --run) run=$2;; --spec) spec=$2;; --title) title=$2;; --worktree-path) wt=$2;;
  --name) name=$2;; --repo) repo=$2;; --base-branch) base=$2;; --model) model=$2;; --effort) effort=$2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift 2; done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] || { echo "need --run --spec --title" >&2; exit 2; }
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
if [ -z "$wt" ]; then
  [ -n "$name" ] && [ -n "$repo" ] || { echo "need --worktree-path or --name and --repo" >&2; exit 2; }
  wt=$("$orca" worktree create --name "$name" --repo "path:$repo" --base-branch "$base" --setup run --json | j 'd["result"]["worktree"]["path"]') || exit 1
fi
term=$("$orca" terminal create --worktree "path:$wt" --title "$title" \
  --command "codex -m $model -c model_reasoning_effort=$effort" --json | j 'd["result"]["terminal"]["handle"]') || exit 1
for i in $(seq 1 30); do   # up to 90 s for the Codex prompt
  "$orca" terminal read --terminal "$term" --screen --json 2>/dev/null | grep -q 'Ask Codex\|? for shortcuts' && break; sleep "$poll"; done
"$orca" terminal send --terminal "$term" --text "Say ready and wait for your task." --enter --json >/dev/null
for i in $(seq 1 30); do   # up to 90 s for the warm-up turn to finish
  sleep "$poll"; scr=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null)
  echo "$scr" | grep -q 'Working' || { echo "$scr" | grep -qi 'ready' && break; }; done
out=$("$orca" orchestration worker-start --run "$run" --spec "$(cat "$spec")" --terminal "$term" \
  --worktree "path:$wt" --task-title "$title" --json) || { echo "$out" >&2; exit 1; }
disp=$(echo "$out" | j 'd["result"]["dispatchId"]'); st=$(echo "$out" | j 'd["result"]["state"]')
"$orca" terminal rename --terminal "$term" --title "$title" --json >/dev/null   # Codex overwrites the title
echo "$disp $term $st"; [ "$st" = ready ] || [ "$st" = dispatched ]
