#!/usr/bin/env bash
# Same arguments as Orca worker-start, requiring --on and --agent.
# Probe the execution environment's login-shell PATH before creating a worker.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/lib/pr-review-gates.sh"
orca=${ORCA_CLI_COMMAND:-orca}
args=("$@")
environment='' agent='' worktree='' model=''
while [ $# -gt 0 ]; do
  case "$1" in
    --on|--agent|--worktree|--model)
      [ $# -ge 2 ] || exit 2
      case "$1" in
        --on) [ -z "$environment" ] || exit 2; environment=$2 ;;
        --agent) [ -z "$agent" ] || exit 2; agent=$2 ;;
        --worktree) [ -z "$worktree" ] || exit 2; worktree=$2 ;;
        --model) model=$2 ;;
      esac; shift 2 ;;
    --terminal|--environment|--pairing-code)
      echo "start-remote-worker: refused alternate placement or existing terminal: $1" >&2; exit 2 ;;
    --json) shift ;;
    *) [ $# -ge 2 ] || exit 2; shift 2 ;;
  esac
done
[ -n "$environment" ] && [ -n "$agent" ] || {
  echo 'start-remote-worker: need --on <environment> --agent <agent>' >&2; exit 2;
}
python3 "${USAGE_GATE_CLI:-$(dirname "$0")/usage-gate.py}" check --provider "$agent" ${model:+--model "$model"} >&2 \
  || { echo "start-remote-worker: refused by the usage gate" >&2; exit 3; }
case "$agent" in
  claude) cli=$agent; probe="command -v $agent >/dev/null 2>&1" ;;
  cursor) cli='agent (or cursor-agent)'; probe='command -v agent >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1' ;;
  antigravity) cli=agy; probe='command -v agy >/dev/null 2>&1' ;;
  *) echo "start-remote-worker: unsupported agent: $agent" >&2; exit 2 ;;
esac
terminal_args=(--environment "$environment" --json)
case "$worktree" in
  ''|new-top-level) # The remote refuses a terminal without a worktree, so probe in an existing one.
    existing=$("$orca" worktree list --environment "$environment" --json 2>&1 | python3 -c '
import json, sys
rows = json.load(sys.stdin)["result"]["worktrees"]
rows = [r for r in rows if not r.get("isArchived") and r.get("path")]
rows.sort(key=lambda r: not r.get("isMainWorktree"))
print("path:" + rows[0]["path"] if rows else "")
' 2>/dev/null) || existing=
    [ -n "$existing" ] || { echo "start-remote-worker: no existing worktree on $environment for the preflight terminal" >&2; exit 1; }
    terminal_args+=(--worktree "$existing") ;;
  current|active|new-child) echo 'start-remote-worker: need an exact remote worktree or new-top-level' >&2; exit 2 ;;
  *) terminal_args+=(--worktree "$worktree") ;;
esac
# The target host must have clean, fast-forwarded checkouts of dotfiles, state dir, and the app repo,
# and pass host_check on the target host before starting a worker.
remote_repo=${REMOTE_REPO:-}
# shellcheck disable=SC2016
refresh='
check_remote_repo() {
  local d
  case "$1" in
    "~") d=$HOME ;;
    "~/"*) d=$HOME/${1#"~/"} ;;
    *) d=$1 ;;
  esac
  if [ -e "$d/.git" ]; then
    [ "$(git -C "$d" branch --show-current 2>/dev/null)" = main ] || exit 1
    [ -z "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ] || exit 1
    git -C "$d" pull -q --ff-only origin main || exit 1
  elif [ -d "$d" ]; then
    git -C "$d" pull -q --ff-only origin main || exit 1
  fi
}
if [ -d "$HOME/dotfiles" ]; then
  check_remote_repo "$HOME/dotfiles"
fi
if [ -f "$HOME/dotfiles/script/setup-orca.sh" ]; then
  bash "$HOME/dotfiles/script/setup-orca.sh" >/dev/null || exit 1
fi
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
if [ -e "$state_dir/.git" ]; then
  check_remote_repo "$state_dir"
fi
if [ -n "'"$remote_repo"'" ] && [ -e "'"$remote_repo"'/.git" ]; then
  check_remote_repo "'"$remote_repo"'"
fi
if [ -f "$state_dir/fleet-pull.json" ] && command -v jq >/dev/null 2>&1; then
  for r in $(jq -r "(.repos // [])[]" "$state_dir/fleet-pull.json" 2>/dev/null); do
    check_remote_repo "$r"
  done
fi
'
preflight_failed() {
  echo "start-remote-worker: preflight failed on $environment: $1" >&2
  exit 1
}
errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
result=$("$orca" terminal create "${terminal_args[@]}" --command "if $probe; then $refresh exit 0; else exit 127; fi" 2>"$errors") \
  || preflight_failed "$(cat "$errors"; printf '%s' "$result")"
terminal=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["terminal"]["handle"])') \
  || preflight_failed "$result"
result=$("$orca" terminal wait --environment "$environment" --terminal "$terminal" --for exit --timeout-ms 60000 --json)
if ! printf '%s' "$result" | python3 -c '
import json, sys
w = json.load(sys.stdin)["result"]["wait"]
sys.exit(0 if w.get("satisfied") is True and w.get("status") == "exited" and w.get("exitCode") == 0 else 1)
'; then
  echo "start-remote-worker: refused: required CLI $cli missing or preflight unconfirmed on $environment; run script/install-agent-clis.sh there and retry (terminal $terminal)." >&2
  exit 1
fi
"$orca" terminal close --environment "$environment" --terminal "$terminal" --json >/dev/null
wt_path=""
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = --worktree ] && [ $((i + 1)) -lt ${#args[@]} ]; then
    case "${args[$((i + 1))]}" in
      path:*) wt_path="${args[$((i + 1))]#path:}" ;;
    esac
    break
  fi
done
pr_review_gates_orchestration_worker_start "$agent" "${model:-}" "$wt_path" -- "${args[@]}"
