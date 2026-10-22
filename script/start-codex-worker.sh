#!/usr/bin/env bash
# Start an Orca worker on Codex without the agent_readiness failure (codex 0.160.1):
# Orca only sees a Codex terminal as ready after Codex has finished one turn, so open the
# Codex terminal first, give it a one line warm-up turn, then hand it the task.
# Usage: start-codex-worker.sh --run <run_id> --spec <file> --title <text>
# Briefs must list Allowed files and say: Read only these; Grep before Read; Read with offset/limit.
# Reviewer slices may inspect at most 40 files.
#          (--worktree-path <path> | --name <new worktree> --repo <path> [--base-branch <ref>])
#          [--model gpt-6.1-sol] [--effort medium] [--from <coordinator handle>]
# --from defaults to $ORCA_TERMINAL_HANDLE; a coordinator without one (Elon in Claude Code) passes its
# orca_session_id, or worker-start fails consumer_fenced after the worktree and terminal exist.
# Prints the dispatch id and terminal handle; exits 1 if the dispatch is not running, 3 if --model gpt-6-astra lacks OWNER_ASTRA_YES.
set -u
poll="${START_CODEX_POLL:-1}"; orca="${ORCA_CLI_COMMAND:-orca}"; model=gpt-6.1-sol; effort=medium; base=
# Plugins a coding or review worker does not need; each one slows Codex startup.
off=; for p in codex-app-tools@openai-bundled unified-computer-use@openai-bundled visualize@openai-bundled \
  documents@openai-primary-runtime pdf@openai-primary-runtime spreadsheets@openai-primary-runtime \
  presentations@openai-primary-runtime template-creator@openai-primary-runtime; do
  off="$off -c plugins.\"$p\".enabled=false"; done
run= spec= title= wt= name= repo= from="${ORCA_TERMINAL_HANDLE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --run) run=$2;; --spec) spec=$2;; --title) title=$2;; --worktree-path) wt=$2;;
  --name) name=$2;; --repo) repo=$2;; --base-branch) base=$2;; --model) model=$2;; --effort) effort=$2;; --from) from=$2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift 2; done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] || { echo "need --run --spec --title" >&2; exit 2; }
[ -n "$from" ] || { echo "need --from <coordinator handle> (no ORCA_TERMINAL_HANDLE)" >&2; exit 2; }
# gpt-6-astra costs about 4 times gpt-6.1-sol per token (2026-10-22: one astra worker moved the weekly reading 65% to 95%).
# Owner rule 2026-10-22: only with the owner'"'"'s yes for that specific use; OWNER_ASTRA_YES names the issue or message of that yes.
case "$model" in gpt-6-astra*) [ -n "${OWNER_ASTRA_YES:-}" ] || {
  echo "start-codex-worker: refused: $model needs the owner's yes for this use; set OWNER_ASTRA_YES=<issue or message ref>, or use gpt-6.1-sol" >&2; exit 3; } ;; esac
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }
if [ -z "$wt" ]; then
  [ -n "$name" ] && [ -n "$repo" ] || { echo "need --worktree-path or --name and --repo" >&2; exit 2; }
  if [ -z "$base" ]; then
    base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || {
      echo "cannot resolve origin/HEAD for $repo; pass --base-branch explicitly" >&2; exit 1;
    }
  fi
  wt=$("$orca" worktree create --name "$name" --repo "path:$repo" --base-branch "$base" --setup run --json | j 'd["result"]["worktree"]["path"]') || exit 1
fi
term=$("$orca" terminal create --worktree "path:$wt" --title "$title" \
  --command "codex -m $model -c model_reasoning_effort=$effort$off" --json | j 'd["result"]["terminal"]["handle"]') || exit 1
for i in $(seq 1 180); do   # up to 180 s for the Codex prompt
  "$orca" terminal read --terminal "$term" --screen --json 2>/dev/null | grep -q 'Ask Codex\|? for shortcuts\|GPT-[0-9]' && break; sleep "$poll"; done
"$orca" terminal send --terminal "$term" --text "Say ready and wait for your task." --enter --json >/dev/null
for i in $(seq 1 90); do   # up to 90 s for the warm-up turn to finish
  sleep "$poll"; scr=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null)
  echo "$scr" | grep -q 'Working' || { echo "$scr" | grep -qi 'ready' && break; }; done
out=$("$orca" orchestration worker-start --run "$run" --spec "$(cat "$spec")" --terminal "$term" \
  --worktree "path:$wt" --task-title "$title" --from "$from" --json) || { echo "$out" >&2; exit 1; }
disp=$(echo "$out" | j 'd["result"]["dispatchId"]'); st=$(echo "$out" | j 'd["result"]["state"]')
"$orca" terminal rename --terminal "$term" --title "$title" --json >/dev/null   # Codex overwrites the title
echo "$disp $term $st"; [ "$st" = ready ] || [ "$st" = dispatched ]
