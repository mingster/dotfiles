#!/usr/bin/env bash
# Daily 19:00 Asia/Taipei precheck for the daily-program-1900 Orca fleet automation.
# Always wakes the active coordinator run via `orca orchestration send` to run the standing program
# kickoff (templates/agent-team/docs/agents/daily-run.md). Inspects configured project repositories
# (from FLEET_STAGING_REPOS or fleet-pull.json), fetches origin, and compares origin/main with
# origin/staging (or configured <component>/staging branches in .claude/hooks/guard-config.json).
# Only the staging deploy step is skipped when staging equals main; otherwise the wake asks for
# release-manager staging deploy and the pstack swarm live lanes (production stays gated on owner approval).
set -uo pipefail

state_dir="${AGENT_STATE_DIR:-$HOME/agent-state}"
fleet_pull_cfg="${FLEET_PULL_CONFIG:-$state_dir/fleet-pull.json}"
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
  FLEET_PULL_CONFIG="$fleet_pull_cfg" python3 - <<'PY'
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
    path = os.environ.get("FLEET_PULL_CONFIG") or ""
    if path and os.path.isfile(path):
        try:
            data = json.load(open(path, encoding="utf-8"))
            items = data.get("repos") or []
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, str) and item.strip():
                        repos.append(expand(item))
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
  FLEET_WATCH_CONFIG="$fleet_watch_cfg" python3 - <<'PY'
import json
import os

path = os.environ.get("FLEET_WATCH_CONFIG") or ""
if path and os.path.isfile(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
        runs = data.get("runs") or []
        if isinstance(runs, list) and runs and isinstance(runs[0], dict):
            rid = (runs[0].get("id") or "").strip()
            if rid:
                print(rid)
    except Exception:
        pass
PY
}

emit "$(date '+%Y-%m-%dT%H:%M:%S%z') daily-program-1900"

repos=()
while IFS= read -r line; do
  [ -n "$line" ] && repos+=("$line")
done < <(resolve_repos)

if [ "${#repos[@]}" -eq 0 ]; then
  emit "warn: no configured repositories"
fi

ahead_items=()
rc=0

for repo in ${repos[@]+"${repos[@]}"}; do
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
      emit "warn: skipping missing origin/$stage_branch in $repo"
      continue
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

kickoff="${DAILY_PROGRAM_KICKOFF:-$HOME/dotfiles/templates/agent-team/docs/agents/daily-run.md}"
if [ "${#ahead_items[@]}" -eq 0 ]; then
  emit "skip: staging deploy, staging equals main"
  staging_step="Staging equals main: skip the staging deploy step."
  summary="program; staging equals main"
else
  ahead_summary=$(printf '%s; ' "${ahead_items[@]}")
  ahead_summary="${ahead_summary%; }"
  staging_step="origin/main is ahead of staging for ${ahead_summary}: dispatch release-manager for staging deploy (/deploy staging), then the pstack swarm live lanes (.agents/skills/orca-adapter/playbooks/swarm.md)."
  summary="program; staging ahead: ${ahead_summary}"
fi

target=$(resolve_coordinator_target)
if [ -z "$target" ]; then
  emit "error: missing coordinator run id in $fleet_watch_cfg"
  set_trace_summary "missing coordinator run id in $fleet_watch_cfg"
  exit 1
fi
run_id="${target#run:}"
to_arg="run:$run_id"
run_arg=("--run" "$run_id")

subject="daily-program-1900: run the standing program"
body="Daily 19:00 Asia/Taipei: read ${kickoff} and run the standing program. ${staging_step} Production deploy remains gated on owner approval."

if ! "$orca_cli" orchestration send --to "$to_arg" ${run_arg[@]+"${run_arg[@]}"} --type status --subject "$subject" --body "$body" --json >/dev/null 2>&1; then
  emit "error: failed to send orchestration wake to $to_arg (${summary})"
  set_trace_summary "failed wake send (${summary})"
  exit 1
fi

emit "wake: notified $to_arg (${summary})"
set_trace_summary "wake: ${summary}"
exit "$rc"
