#!/usr/bin/env bash
# Same arguments as Orca worker-start, requiring --on and --agent.
# Probe the execution environment's login-shell PATH before creating a worker.
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
args=("$@")
environment= agent= worktree=
while [ $# -gt 0 ]; do
  case "$1" in
    --on|--agent|--worktree)
      [ $# -ge 2 ] || exit 2
      case "$1" in
        --on) [ -z "$environment" ] || exit 2; environment=$2 ;;
        --agent) [ -z "$agent" ] || exit 2; agent=$2 ;;
        --worktree) [ -z "$worktree" ] || exit 2; worktree=$2 ;;
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
case "$agent" in
  claude) cli=$agent; probe="command -v $agent >/dev/null 2>&1" ;;
  cursor) cli='agent (or cursor-agent)'; probe='command -v agent >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1' ;;
  antigravity) cli=agy; probe='command -v agy >/dev/null 2>&1' ;;
  *) echo "start-remote-worker: unsupported agent: $agent" >&2; exit 2 ;;
esac
terminal_args=(--environment "$environment" --json)
case "$worktree" in
  ''|new-top-level) ;; # Probe the remote default workspace before creation.
  current|active|new-child) echo 'start-remote-worker: need an exact remote worktree or new-top-level' >&2; exit 2 ;;
  *) terminal_args+=(--worktree "$worktree") ;;
esac
result=$("$orca" terminal create "${terminal_args[@]}" --command "if $probe; then exit 0; else exit 127; fi")
terminal=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["terminal"]["handle"])')
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
exec "$orca" orchestration worker-start "${args[@]}"
