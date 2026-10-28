#!/usr/bin/env bash
# Create and trust a local worktree before Orca launches Cursor.
# Usage: --run ID --spec FILE --title TEXT --model ID [--from HANDLE]
#        (--worktree-path PATH | --name NAME --repo PATH [--base-branch REF])
# Run on the main Mac only; remote builders use Claude until remote attach works.
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
run= spec= title= model= wt= name= repo= base= from=${ORCA_TERMINAL_HANDLE:-}
usage() { echo "need --run --spec --title --model --from and --worktree-path or --name --repo" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --on|--host|--on=*|--host=*) echo 'start-cursor-worker: main Mac only; remote builders use Claude until remote attach works.' >&2; exit 2 ;;
    --run|--spec|--title|--model|--from|--worktree-path|--name|--repo|--base-branch)
      [ $# -ge 2 ] || usage
      case "$1" in
        --run) run=$2 ;; --spec) spec=$2 ;; --title) title=$2 ;; --model) model=$2 ;;
        --from) from=$2 ;; --worktree-path) wt=$2 ;; --name) name=$2 ;; --repo) repo=$2 ;; --base-branch) base=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$run" ] && [ -n "$spec" ] && [ -n "$title" ] && [ -n "$model" ] && [ -n "$from" ] || usage
brief=$(cat "$spec")
if [ -z "$wt" ]; then
  [ -n "$name" ] && [ -n "$repo" ] || usage
  if [ -z "$base" ]; then
    base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  fi
  result=$("$orca" worktree create --name "$name" --repo "path:$repo" --base-branch "$base" --setup run --json)
  wt=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["worktree"]["path"])')
fi
case "$wt" in /*) ;; *) echo 'worktree path must be absolute' >&2; exit 2 ;; esac
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
exec "$orca" orchestration worker-start --run "$run" --spec "$brief" --agent cursor --model "$model" \
  --worktree "path:$wt" --task-title "$title" --from "$from" --json
