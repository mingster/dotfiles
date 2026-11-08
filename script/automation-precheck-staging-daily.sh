#!/usr/bin/env bash
# Daily 19:00 Asia/Taipei staging precheck for Orca fleet automations.
# Inspects configured project repositories (from FLEET_STAGING_REPOS or fleet-config.json),
# fetches origin, and compares origin/main with origin/staging (or configured <component>/staging
# branches in .claude/hooks/guard-config.json). Logs "skip: staging equals main" when up to date,
# or wakes the active coordinator run via `orca orchestration send` to dispatch release-manager
# for staging deploy followed by /staging-review (production deploy remains gated on owner approval).
set -uo pipefail

DOTFILES="${DOTFILES:-${DOTFILES_DIR:-$HOME/dotfiles}}"
state_dir="${AGENT_STATE_DIR:-$HOME/agent-state}"
fleet_watch_cfg="${FLEET_WATCH_CONFIG:-$HOME/.config/fleet-watch/config.json}"
log="${STAGING_DAILY_LOG:-$HOME/.local/state/agent-team/staging-daily.log}"
orca_cli="${ORCA_CLI_COMMAND:-orca}"

mkdir -p "$(dirname "$log")"

emit() {
  printf '%s\n' "$*"
  if [ ! "$log" -ef /dev/stdout ]; then
    printf '%s\n' "$*" >>"$log"
  fi
}

set_trace_summary() {
  if [ -n "${AUTOMATION_TRACE_SUMMARY_FILE:-}" ]; then
    printf '%s\n' "$1" >"$AUTOMATION_TRACE_SUMMARY_FILE"
  fi
}

resolve_repos() {
  DOTFILES="$DOTFILES" AGENT_STATE_DIR="$state_dir" FLEET_WATCH_CONFIG="$fleet_watch_cfg" python3 - <<'PY'
import json
import os
import re

def expand(p: str) -> str:
    return os.path.expanduser(p.strip())

raw_env = (os.environ.get("FLEET_STAGING_REPOS") or "").strip()
repos = []
if raw_env:
    if raw_env.startswith("["):
        try:
            items = json.loads(raw_env)
            if isinstance(items, list):
                repos = [expand(str(x)) for x in items if str(x).strip()]
        except Exception:
            repos = []
    elif os.path.isdir(expand(raw_env)):
        repos = [expand(raw_env)]
    else:
        for token in re.split(r"[\s,:]+", raw_env):
            if token.strip():
                repos.append(expand(token))
else:
    state_dir = os.environ.get("AGENT_STATE_DIR") or os.path.expanduser("~/agent-state")
    dotfiles = os.environ.get("DOTFILES") or os.path.expanduser("~/dotfiles")
    candidates = [
        os.environ.get("FLEET_CONFIG") or "",
        os.environ.get("FLEET_PULL_CONFIG") or "",
        os.path.join(state_dir, "fleet-config.json"),
        os.path.join(state_dir, "fleet-pull.json"),
        os.path.join(dotfiles, "script", "fleet-pull.config.json"),
    ]
    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        try:
            data = json.load(open(path, encoding="utf-8"))
        except Exception:
            continue
        items = data.get("staging_repos") or data.get("repos") or []
        if isinstance(items, list) and items:
            for item in items:
                if isinstance(item, str) and item.strip():
                    repos.append(expand(item))
                elif isinstance(item, dict) and isinstance(item.get("path"), str):
                    repos.append(expand(item["path"]))
            if repos:
                break
    if not repos:
        fw = os.environ.get("FLEET_WATCH_CONFIG") or ""
        if fw and os.path.isfile(fw):
            try:
                data = json.load(open(fw, encoding="utf-8"))
                roots = (data.get("issue_scan") or {}).get("repo_roots") or {}
                if isinstance(roots, dict):
                    for v in roots.values():
                        if isinstance(v, str) and v.strip():
                            repos.append(expand(v))
            except Exception:
                pass

seen = set()
for r in repos:
    if r and r not in seen:
        seen.add(r)
        print(r)
PY
}

resolve_stage_branches() {
  local repo=$1
  REPO_PATH="$repo" python3 - <<'PY'
import json
import os

repo = os.environ["REPO_PATH"]
cfg_path = os.path.join(repo, ".claude", "hooks", "guard-config.json")
branches = []
if os.path.isfile(cfg_path):
    try:
        data = json.load(open(cfg_path, encoding="utf-8"))
    except Exception:
        data = {}
    raw = []
    for key in ("staging_branches", "stage_branches"):
        val = data.get(key)
        if isinstance(val, list):
            raw.extend(val)
    for item in raw:
        if not isinstance(item, str):
            continue
        b = item.strip()
        if b == "staging" or b.endswith("/staging"):
            if b not in branches:
                branches.append(b)
        elif b.endswith("/*"):
            cand = b[:-2] + "/staging"
            if cand not in branches:
                branches.append(cand)

for b in branches:
    print(b)
PY
}

resolve_coordinator_target() {
  local target=""
  if [ -n "${FLEET_STAGING_COORDINATOR_RUN:-}" ]; then
    printf '%s\n' "$FLEET_STAGING_COORDINATOR_RUN"
    return 0
  fi
  if [ -n "${COORDINATOR_RUN_ID:-}" ]; then
    printf '%s\n' "$COORDINATOR_RUN_ID"
    return 0
  fi
  target=$(FLEET_WATCH_CONFIG="$fleet_watch_cfg" AGENT_STATE_DIR="$state_dir" python3 - <<'PY'
import json
import os

candidates = [
    os.environ.get("FLEET_WATCH_CONFIG") or "",
    os.path.expanduser("~/.claude/state/fleet-watch-elon.json"),
    os.path.join(os.environ.get("AGENT_STATE_DIR") or os.path.expanduser("~/agent-state"), "fleet-config.json"),
]
for path in candidates:
    if not path or not os.path.isfile(path):
        continue
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        continue
    runs = data.get("runs") or []
    if isinstance(runs, list) and runs:
        first = runs[0] if isinstance(runs[0], dict) else {}
        rid = (first.get("id") or "").strip()
        if rid:
            print(rid)
            raise SystemExit(0)
        term = (first.get("terminal") or "").strip()
        if term:
            print(term)
            raise SystemExit(0)
    scan = data.get("issue_scan") or {}
    if isinstance(scan, dict):
        rid = (scan.get("run") or "").strip()
        if rid:
            print(rid)
            raise SystemExit(0)
        term = (scan.get("from_terminal") or "").strip()
        if term:
            print(term)
            raise SystemExit(0)
PY
  )
  if [ -n "$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  target=$({ "$orca_cli" orchestration run-list --json 2>/dev/null || true; } | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
    box = data.get("result") if isinstance(data.get("result"), dict) else data
    runs = (box or {}).get("runs") or []
    if runs and isinstance(runs[0], dict) and runs[0].get("id"):
        print(runs[0]["id"])
except Exception:
    pass
')
  if [ -n "$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  printf 'coordinator\n'
}

emit "$(date '+%Y-%m-%dT%H:%M:%S%z') staging-daily-1900"

repos=()
while IFS= read -r line; do
  [ -n "$line" ] && repos+=("$line")
done < <(resolve_repos)

if [ "${#repos[@]}" -eq 0 ]; then
  emit "skip: staging equals main (no configured repositories)"
  set_trace_summary "skip: staging equals main"
  exit 0
fi

ahead_items=()
rc=0

for repo in "${repos[@]}"; do
  if [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    emit "warn: skipping missing or non-git path $repo"
    continue
  fi
  repo_name=$(basename "$repo")
  if ! git -C "$repo" fetch -q origin 2>/dev/null; then
    emit "error: git fetch origin failed in $repo"
    rc=1
    continue
  fi

  main_sha=$(git -C "$repo" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)
  if [ -z "$main_sha" ]; then
    emit "warn: missing origin/main in $repo"
    continue
  fi
  main_short=$(git -C "$repo" rev-parse --short "$main_sha" 2>/dev/null || printf '%s' "$main_sha")

  stage_branches=()
  while IFS= read -r b; do
    [ -n "$b" ] && stage_branches+=("$b")
  done < <(resolve_stage_branches "$repo")

  if [ "${#stage_branches[@]}" -eq 0 ]; then
    if git -C "$repo" show-ref --verify --quiet refs/remotes/origin/staging; then
      stage_branches+=("staging")
    else
      while IFS= read -r b; do
        [ -n "$b" ] && stage_branches+=("$b")
      done < <(git -C "$repo" for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/*/staging' 2>/dev/null || true)
    fi
  fi

  if [ "${#stage_branches[@]}" -eq 0 ]; then
    continue
  fi

  for stage_branch in "${stage_branches[@]}"; do
    stage_sha=$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$stage_branch" 2>/dev/null || true)
    if [ -z "$stage_sha" ]; then
      ahead_count=$(git -C "$repo" rev-list --count "$main_sha" 2>/dev/null || echo 1)
      stage_short="none"
    elif [ "$stage_sha" = "$main_sha" ]; then
      ahead_count=0
      stage_short=$(git -C "$repo" rev-parse --short "$stage_sha" 2>/dev/null || printf '%s' "$stage_sha")
    else
      ahead_count=$(git -C "$repo" rev-list --count "${stage_sha}..${main_sha}" 2>/dev/null || echo 0)
      stage_short=$(git -C "$repo" rev-parse --short "$stage_sha" 2>/dev/null || printf '%s' "$stage_sha")
    fi

    if [ "${ahead_count:-0}" -gt 0 ]; then
      if [ "$stage_branch" = "staging" ]; then
        item="${repo_name} (origin/staging..origin/main +${ahead_count} commits, ${stage_short}..${main_short})"
      else
        comp="${stage_branch%/staging}"
        item="${repo_name}/${comp} (origin/${stage_branch}..origin/main +${ahead_count} commits, ${stage_short}..${main_short})"
      fi
      ahead_items+=("$item")
      emit "ahead: repo=${repo_name} branch=${stage_branch} commits=${ahead_count} range=${stage_short}..${main_short}"
    else
      emit "equal: repo=${repo_name} branch=${stage_branch} sha=${main_short}"
    fi
  done
done

if [ "${#ahead_items[@]}" -eq 0 ]; then
  emit "skip: staging equals main"
  set_trace_summary "skip: staging equals main"
  exit "$rc"
fi

ahead_summary=$(printf '%s; ' "${ahead_items[@]}")
ahead_summary="${ahead_summary%; }"

target=$(resolve_coordinator_target)
case "$target" in
  run:*)
    to_arg="$target"
    run_arg=("--run" "${target#run:}")
    ;;
  term_*)
    to_arg="$target"
    run_arg=()
    ;;
  *)
    to_arg="run:$target"
    run_arg=("--run" "$target")
    ;;
esac

subject="staging-daily-1900: deploy staging and run /staging-review"
body="Daily 19:00 Asia/Taipei staging check: origin/main is ahead of staging for ${ahead_summary}. Dispatch release-manager for staging deploy (/deploy staging) and then run /staging-review. Production deploy remains gated on owner approval."

if ! "$orca_cli" orchestration send --to "$to_arg" ${run_arg[@]+"${run_arg[@]}"} --type status --subject "$subject" --body "$body" --json >/dev/null 2>&1; then
  emit "error: failed to send orchestration wake to $to_arg for ${ahead_summary}"
  set_trace_summary "failed wake send for ${ahead_summary}"
  exit 1
fi

emit "wake: notified $to_arg for ${ahead_summary}"
set_trace_summary "wake: ${ahead_summary}"
exit "$rc"
