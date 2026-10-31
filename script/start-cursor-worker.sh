#!/usr/bin/env bash
# Create and trust a worktree on the execution environment before Cursor starts.
# Usage: --run ID --spec FILE --title TEXT --model ID [--from HANDLE] [--on ENV]
#        (--worktree-path PATH | --name NAME --repo PATH_OR_SELECTOR [--base-branch REF])
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
run='' spec='' title='' model='' wt='' name='' repo='' base='' environment=''
from=${ORCA_TERMINAL_HANDLE:-}
usage() { echo "need --run --spec --title --model --from and --worktree-path or --name --repo" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --run|--spec|--title|--model|--from|--worktree-path|--name|--repo|--base-branch|--on)
      [ $# -ge 2 ] || usage
      case "$1" in
        --run) run=$2 ;; --spec) spec=$2 ;; --title) title=$2 ;; --model) model=$2 ;;
        --on) environment=$2; [ -n "$environment" ] || usage ;; --from) from=$2 ;; --worktree-path) wt=$2 ;; --name) name=$2 ;; --repo) repo=$2 ;; --base-branch) base=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$model" ] && [ -n "$from" ] || usage
brief=$(cat "$spec")
[ -n "${brief//[[:space:]]/}" ] || { echo "spec file is empty: $spec" >&2; exit 2; }
if [ -z "$wt" ]; then
  [ -n "$name" ] && [ -n "$repo" ] || usage
  case "$repo" in
    id:*|path:*) repo_selector=$repo ;;
    *) repo_selector="path:$repo" ;;
  esac
  # An id selector has no local directory; let Orca resolve its default base.
  if [ -z "$base" ] && [ -z "$environment" ] && [[ "$repo_selector" == path:* ]]; then
    base=$(git -C "${repo_selector#path:}" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  fi
  create_args=(--name "$name" --repo "$repo_selector")
  [ -z "$base" ] || create_args+=(--base-branch "$base")
  create_args+=(--setup run --json)
  [ -z "$environment" ] || create_args+=(--environment "$environment")
  result=$("$orca" worktree create "${create_args[@]}") || {
    status=$?
    printf 'orca worktree create failed (exit %s)\n%s\n' "$status" "$result" >&2
    exit "$status"
  }
  wt=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["worktree"]["path"])')
fi
case "$wt" in /*) ;; *) echo 'worktree path must be absolute' >&2; exit 2 ;; esac
if [ -n "$environment" ]; then
  # Quote both the Python program and path for the remote login shell. HOME is
  # deliberately read by Python there, never expanded on the coordinator.
  command=$(python3 - "$wt" <<'PYCOMMAND'
import shlex, sys
program = """import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
wt = sys.argv[1]
directory = Path(os.environ['HOME']) / '.cursor/projects' / wt.lstrip('/').replace('/', '-').replace('.', '-')
directory.mkdir(parents=True, exist_ok=True)
with (directory / '.workspace-trusted').open('w') as f:
    json.dump({'trustedAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'workspacePath': wt}, f)
"""
print('exec python3 -c ' + shlex.quote(program) + ' ' + shlex.quote(sys.argv[1]))
PYCOMMAND
)
  result=$("$orca" terminal create --environment "$environment" --worktree "path:$wt" --command "$command" --json)
  terminal=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["terminal"]["handle"])')
  result=$("$orca" terminal wait --environment "$environment" --terminal "$terminal" --for exit --timeout-ms 60000 --json)
  # A timeout, missing exit code, or failed write must never authorize dispatch.
  printf '%s' "$result" | python3 -c '
import json, sys
wait = json.load(sys.stdin)["result"]["wait"]
if not (wait.get("satisfied") is True and wait.get("status") == "exited" and wait.get("exitCode") == 0):
    sys.exit("remote workspace trust did not complete successfully")
'
  "$orca" terminal close --environment "$environment" --terminal "$terminal" --json >/dev/null
  exec bash "$(dirname "$0")/start-remote-worker.sh" --run "$run" --spec "$brief" --agent cursor --model "$model" \
    --on "$environment" --worktree "path:$wt" --task-title "$title" --from "$from" --json
else
# Cursor omits the leading slash, then replaces remaining slashes and dots.
python3 - "$wt" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
wt = sys.argv[1]
directory = Path(os.environ['HOME']) / '.cursor/projects' / wt.lstrip('/').replace('/', '-').replace('.', '-')
directory.mkdir(parents=True, exist_ok=True)
with (directory / '.workspace-trusted').open('w') as f:
    json.dump({'trustedAt': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'workspacePath': wt}, f)
PY
fi
exec "$orca" orchestration worker-start --run "$run" --spec "$brief" --agent cursor --model "$model" \
  --worktree "path:$wt" --task-title "$title" --from "$from" --json
