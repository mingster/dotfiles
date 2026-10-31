#!/usr/bin/env bash
# Finish path for a settled worker: verify head (when required), native worker-release, optional worktree removal.
# Usage: worker-finish.sh --worktree <path> [--dispatch <id>]... [--task-id <id>] [--skip-head-checks "<reason>"]
#   DRY_RUN=1 only prints. Head-checks run first unless skipped or the head is already merged.
# Worktree removal runs only after every dispatch receives released or already_released from worker-release.
set -euo pipefail
dry=${DRY_RUN:-0}
orca=${ORCA_CLI_COMMAND:-orca}
wt="" dispatches=() skip="" skip_set=0 expect_task=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt=${2:-}; shift 2 ;;
    --dispatch) dispatches+=("${2:-}"); shift 2 ;;
    --task-id) expect_task=${2:-}; shift 2 ;;
    --skip-head-checks) skip_set=1; skip=${2:-}; [ $# -ge 2 ] && shift; shift ;;
    *) echo "worker-finish: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$wt" ] || { echo "usage: worker-finish.sh --worktree <path> [--dispatch <id>]... [--task-id <id>]" >&2; exit 2; }
run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
real() { if [ -d "$1" ]; then (cd -P "$1" && pwd); else printf '%s\n' "$1"; fi; }
wt=$(real "$wt")
archive_dir=${WORKER_FINISH_ARCHIVE_DIR:-}
if [ -n "$archive_dir" ]; then mkdir -p "$archive_dir"; fi

merged() {
  git -C "$wt" fetch -q origin main 2>/dev/null || true
  if git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then echo "HEAD is already in origin/main"; return 0; fi
  [ "$(cd "$wt" && gh pr view --json state -q .state 2>/dev/null)" = MERGED ] && echo "its PR is already merged"
}

head_proven_in_merged_main() {
  if ! git -C "$wt" fetch -q origin main 2>&1; then
    echo "worker-finish: cannot verify main ancestry; worktree kept at $wt" >&2
    return 1
  fi
  if git -C "$wt" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    return 0
  fi
  local pr_state="" pr_head="" head=""
  pr_state=$(cd "$wt" && gh pr view --json state -q .state 2>/dev/null) || pr_state=""
  pr_head=$(cd "$wt" && gh pr view --json headRefOid -q .headRefOid 2>/dev/null) || pr_head=""
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=""
  if [ "$pr_state" = MERGED ] && [ -n "$pr_head" ] && [ "$pr_head" = "$head" ]; then
    return 0
  fi
  echo "worker-finish: HEAD not proven in merged main; worktree kept at $wt" >&2
  return 1
}

if [ "$skip_set" = 1 ]; then
  [ -n "$skip" ] || { echo "worker-finish: --skip-head-checks needs a reason" >&2; exit 2; }
  echo "worker-finish: skipping head-checks: $skip"
else
  checks=${HEAD_CHECKS:-$HOME/dotfiles/script/head-checks.sh}
  if why=$(merged); then
    echo "worker-finish: skipping head-checks, $why"
  elif [ "$dry" = 1 ]; then
    echo "[dry-run] $checks --repo $wt --ref HEAD --base origin/main"
  elif ! "$checks" --repo "$wt" --ref HEAD --base origin/main; then
    echo "worker-finish: head-checks failed, refusing worker_done" >&2
    exit 1
  fi
fi

if [ ${#dispatches[@]} -eq 0 ] && command -v "$orca" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  while IFS=$'\t' read -r id path; do
    [ -n "$id" ] && [ "$(real "$path")" = "$wt" ] && dispatches+=("$id")
  done < <("$orca" orchestration worker-list --json 2>/dev/null \
    | jq -r '.result.workers[]? | select(.dispatchStatus != "released") | [.dispatchId, ((.worktreeId // "") | split("::")[1] // "")] | @tsv' 2>/dev/null || true)
fi

if ! command -v "$orca" >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "worker-finish: orca and jq are required for worker-release" >&2
  exit 1
fi

if [ ${#dispatches[@]} -eq 0 ]; then
  echo "worker-finish: no dispatch id for $wt; refusing release and worktree removal" >&2
  exit 1
fi

closed=0 already=0 retained=0 pending=0 unknown=0
fail=0
release_body="" release_rc=0

for id in ${dispatches[@]+"${dispatches[@]}"}; do
  if [ "$dry" = 1 ]; then
    echo "[dry-run] $orca orchestration worker-show --dispatch $id --json"
    echo "[dry-run] $orca orchestration worker-release --dispatch $id --json"
    closed=$((closed + 1))
    continue
  fi
  show=$("$orca" orchestration worker-show --dispatch "$id" --json 2>&1) || {
    echo "worker-finish: worker-show failed for $id; refusing cleanup" >&2
    exit 1
  }
  if [ -n "$archive_dir" ]; then printf '%s\n' "$show" > "$archive_dir/show-$id.json"; fi
  status=$(printf '%s' "$show" | jq -r '.result.dispatch.status // empty' 2>/dev/null) || status=""
  case "$status" in
    completed|failed|cancelled|released) ;;
    *)
      echo "worker-finish: refusing release for $id (dispatch status=${status:-unknown})" >&2
      exit 1
      ;;
  esac
  if [ -n "$expect_task" ]; then
    got=$(printf '%s' "$show" | jq -r '.result.dispatch.taskId // .result.task.id // empty' 2>/dev/null) || got=""
    [ "$got" = "$expect_task" ] || {
      echo "worker-finish: task id mismatch for $id (expected $expect_task, got ${got:-<empty>})" >&2
      exit 1
    }
  fi
  release_body=$("$orca" orchestration worker-release --dispatch "$id" --json 2>&1) || release_rc=$?
  if [ -n "$archive_dir" ]; then printf '%s\n' "$release_body" > "$archive_dir/release-$id.json"; fi
  parsed=$(RELEASE_BODY="$release_body" RELEASE_RC="${release_rc:-0}" DISPATCH_ID="$id" python3 <<'PY'
import json, os, sys
body = os.environ.get("RELEASE_BODY", "")
rc = int(os.environ.get("RELEASE_RC", "0"))
dispatch_id = os.environ.get("DISPATCH_ID", "")
try:
    doc = json.loads(body)
except Exception:
    print("malformed", rc)
    sys.exit(0)
if doc.get("ok") is not True:
    code = (doc.get("error") or {}).get("code") or "error"
    print(code, rc)
    sys.exit(0)
result = doc.get("result") or {}
rid = result.get("dispatchId")
if dispatch_id:
    if rid is None or rid == "":
        print("missing", rc)
        sys.exit(0)
    if rid != dispatch_id:
        print("id_mismatch", rc)
        sys.exit(0)
state = result.get("state") or "missing"
if state in ("released", "already_released") and rc != 0:
    print("nonzero_success", rc)
    sys.exit(0)
print(state, rc)
PY
) || {
    echo "worker-finish: could not parse worker-release response for $id" >&2
    fail=1
    unknown=$((unknown + 1))
    continue
  }
  state=${parsed%% *}
  prc=${parsed#* }
  case "$state" in
    released) closed=$((closed + 1)) ;;
    already_released) already=$((already + 1)) ;;
    retained)
      retained=$((retained + 1))
      reason=$(printf '%s' "$release_body" | jq -r '.result.reason // empty' 2>/dev/null || true)
      echo "worker-finish: $id retained${reason:+ ($reason)}; worktree kept" >&2
      ;;
    release_pending) pending=$((pending + 1)); echo "worker-finish: $id release_pending; worktree kept" >&2 ;;
    release_unknown|missing|malformed|error|dispatch_not_found|id_mismatch|nonzero_success)
      unknown=$((unknown + 1))
      fail=1
      echo "worker-finish: worker-release for $id failed ($state, exit $prc)" >&2
      printf '%s\n' "$release_body" >&2
      ;;
    *)
      unknown=$((unknown + 1))
      fail=1
      echo "worker-finish: worker-release for $id returned unknown state $state" >&2
      printf '%s\n' "$release_body" >&2
      ;;
  esac
done

echo "worker-finish: closed=$closed already_released=$already retained=$retained pending=$pending unknown=$unknown"

if [ "$fail" -ne 0 ]; then
  echo "worker-finish: refusing worktree removal after failed or unknown release" >&2
  exit 1
fi

if [ "$retained" -ne 0 ] || [ "$pending" -ne 0 ]; then
  echo "worker-finish: worktree kept at $wt"
  exit 0
fi

if [ "$dry" != 1 ]; then
  wt_porcelain=""
  if ! wt_porcelain=$(git -C "$wt" status --porcelain 2>&1); then
    echo "worker-finish: cannot inspect worktree status; worktree kept at $wt" >&2
    exit 0
  fi
  if [ -n "$wt_porcelain" ] \
    || git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    || [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)" ] \
    || [ -n "$(git -C "$wt" ls-files -u 2>/dev/null || true)" ]; then
    echo "worker-finish: dirty or unmerged worktree kept at $wt"
    exit 0
  fi
fi

if [ "$dry" = 1 ]; then
  echo "[dry-run] git worktree remove -- $wt"
  echo "[dry-run] git worktree prune"
  exit 0
fi

if ! head_proven_in_merged_main; then
  exit 0
fi

if [ -d "$wt" ]; then
  if ! run git worktree remove -- "$wt"; then
    echo "worker-finish: worktree remove failed; kept $wt" >&2
    exit 1
  fi
  run git worktree prune
  echo "worker-finish: removed worktree $wt"
fi
