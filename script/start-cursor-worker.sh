#!/usr/bin/env bash
# Create and trust a worktree on the execution environment before Cursor starts.
# Optional --owner-lead HANDLE [--owner-repo R --owner-branch B] writes the owner record after the start.
# Usage: --run ID --spec FILE --title TEXT --model ID [--from HANDLE] [--on ENV]
#        (--worktree-path PATH | --name NAME --repo PATH_OR_SELECTOR [--base-branch REF])
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
run='' spec='' title='' model='' wt='' name='' repo='' base='' environment=''
from=${ORCA_TERMINAL_HANDLE:-}
owner_lead='' owner_repo='' owner_branch=''
self=start-cursor-worker
usage() { echo "need --run --spec --title --model --from and --worktree-path or --name --repo" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --run|--spec|--title|--model|--from|--worktree-path|--name|--repo|--base-branch|--on|--owner-lead|--owner-repo|--owner-branch)
      [ $# -ge 2 ] || usage
      case "$1" in
        --run) run=$2 ;; --spec) spec=$2 ;; --title) title=$2 ;; --model) model=$2 ;;
        --on) environment=$2; [ -n "$environment" ] || usage ;; --from) from=$2 ;; --worktree-path) wt=$2 ;; --name) name=$2 ;; --repo) repo=$2 ;; --base-branch) base=$2 ;;
        --owner-lead) owner_lead=$2 ;; --owner-repo) owner_repo=$2 ;; --owner-branch) owner_branch=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$model" ] && [ -n "$from" ] || usage
# Run worker-start; with --owner-lead, also write the owner record from the dispatch id in its output.
# The start output is printed unchanged and a failed record write only warns.
start_and_record() {
  local out status dispatch record_args
  out=$(mktemp)
  status=0
  "$orca" orchestration worker-start "$@" > "$out" || status=$?
  cat "$out"
  if [ "$status" = 0 ]; then
    dispatch=$(python3 - "$out" <<'PY' 2>/dev/null || true
import json, re, sys
def find(node):
    if isinstance(node, dict):
        if isinstance(node.get("dispatchId"), str):
            return node["dispatchId"]
        node = list(node.values())
    if isinstance(node, list):
        for value in node:
            found = find(value)
            if found:
                return found
try:
    found = find(json.load(open(sys.argv[1])))
except (OSError, ValueError):
    found = None
print(found if found and re.fullmatch(r"[A-Za-z0-9_-]+", found) else "")
PY
)
    if [ -z "$dispatch" ]; then
      echo "$self: no dispatch id in the start output, owner record not written" >&2
    else
      record_args=(record --dispatch "$dispatch" --lead "$owner_lead")
      if [ -n "$owner_repo" ] && [ -n "$owner_branch" ]; then
        record_args+=(--kind builder --repo "$owner_repo" --branch "$owner_branch")
      elif [ -n "$owner_repo$owner_branch" ]; then
        echo "$self: --owner-repo and --owner-branch go together; the record has no kind, so it is never swept" >&2
      fi
      bash "$(dirname "$0")/worker-done-relay.sh" "${record_args[@]}" || echo "$self: owner record for $dispatch not written" >&2
    fi
  fi
  rm -f "$out"
  return "$status"
}
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
  owner_args=()
  [ -z "$owner_lead" ] || owner_args+=(--owner-lead "$owner_lead")
  [ -z "$owner_repo" ] || owner_args+=(--owner-repo "$owner_repo")
  [ -z "$owner_branch" ] || owner_args+=(--owner-branch "$owner_branch")
  exec bash "$(dirname "$0")/start-remote-worker.sh" --run "$run" --spec "$brief" --agent cursor --model "$model" \
    --on "$environment" --worktree "path:$wt" --task-title "$title" --from "$from" ${owner_args[@]+"${owner_args[@]}"} --json
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
if [ -z "$owner_lead" ]; then
  exec "$orca" orchestration worker-start --run "$run" --spec "$brief" --agent cursor --model "$model" \
    --worktree "path:$wt" --task-title "$title" --from "$from" --json
fi
start_and_record --run "$run" --spec "$brief" --agent cursor --model "$model" \
  --worktree "path:$wt" --task-title "$title" --from "$from" --json
