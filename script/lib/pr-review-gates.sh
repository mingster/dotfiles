# Shared review gates for ship.sh and lead-merge.sh (issue #760).
# shellcheck shell=bash

pr_review_gates_orca() { printf '%s\n' "${ORCA_CLI_COMMAND:-orca}"; }

pr_review_gates_launch_state_dir() {
  printf '%s\n' "${WORKER_STARTUP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/worker-startup}"
}

# Written before worker-start so merge gates can resolve model when worker-show omits it.
pr_review_gates_launch_record_worktree() { # <absolute worktree> <agent> <model>
  local wt=$1 agent=$2 model=$3 state hash f
  [ -n "$wt" ] && [ -n "$agent" ] && [ -n "$model" ] || return 1
  state=$(pr_review_gates_launch_state_dir)
  mkdir -p "$state/launches"
  hash=$(printf '%s' "$wt" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$hash" ] || hash=$(printf '%s' "$wt" | openssl dgst -sha256 2>/dev/null | awk '{print $2}')
  [ -n "$hash" ] || return 1
  f="$state/launches/wt-${hash}.json"
  jq -n --arg w "$wt" --arg a "$agent" --arg m "$model" '{worktree:$w,agent:$a,model:$m}' >"$f"
}

pr_review_gates_launch_record_dispatch() { # <dispatch> <agent> <model> [worktree]
  local id=$1 agent=$2 model=$3 wt=${4:-} state f
  [ -n "$id" ] && [ -n "$agent" ] && [ -n "$model" ] || return 1
  state=$(pr_review_gates_launch_state_dir)
  mkdir -p "$state/launches"
  f="$state/launches/$id.json"
  if [ -n "$wt" ]; then
    jq -n --arg d "$id" --arg w "$wt" --arg a "$agent" --arg m "$model" '{dispatchId:$d,worktree:$w,agent:$a,model:$m}' >"$f"
  else
    jq -n --arg d "$id" --arg a "$agent" --arg m "$model" '{dispatchId:$d,agent:$a,model:$m}' >"$f"
  fi
}

pr_review_gates_load_coordinators() {
  [ "${PRG_COORD_LOADED:-0}" = 1 ] && return 0
  local dir cfg
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  cfg=$(python3 "$dir/apply-local-overlay.py" "$dir/lead-merge.config.example.json" "$dir/lead-merge.local.json") \
    || { PRG_COORD_IDS=""; PRG_COORD_LOADED=1; return 1; }
  PRG_COORD_IDS=$(jq -r '.coordinator_ids // [] | .[]' <<<"$cfg" 2>/dev/null || true)
  PRG_COORD_LOADED=1
}

pr_review_gates_is_coordinator_id() { # <id>
  local id=$1
  pr_review_gates_load_coordinators || true
  grep -Fxq -- "$id" <<<"${PRG_COORD_IDS:-}"
}

pr_review_gates_worker_show() { # <dispatch>
  local id=$1 orca out
  orca=$(pr_review_gates_orca)
  out=$("$orca" orchestration worker-show --dispatch "$id" --json 2>/dev/null) || return 1
  jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

pr_review_gates_workspace_path() { # <workspace id string>
  case "$1" in
    *::*) printf '%s' "${1#*::}" ;;
    *) printf '%s' "$1" ;;
  esac
}

pr_review_gates_launch_model_for_worktree() { # <absolute worktree path>
  local wt=$1 state hash f
  [ -n "$wt" ] || return 1
  state=$(pr_review_gates_launch_state_dir)
  hash=$(printf '%s' "$wt" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$hash" ] || hash=$(printf '%s' "$wt" | openssl dgst -sha256 2>/dev/null | awk '{print $2}')
  f="$state/launches/wt-${hash}.json"
  [ -f "$f" ] || return 1
  jq -r '.model // empty' "$f"
}

pr_review_gates_launch_agent_model_for_dispatch() { # <dispatch>
  local id=$1 f state
  state=$(pr_review_gates_launch_state_dir)
  f="$state/launches/$id.json"
  [ -f "$f" ] || return 1
  jq -r 'select(.agent != "" and .model != "") | "\(.agent)\t\(.model)"' "$f" | head -1
}

pr_review_gates_worker_list_row() { # <dispatch> -> json row or fails
  local id=$1 orca cursor="" page m row
  orca=$(pr_review_gates_orca)
  for m in $(seq 1 50); do
    page=$("$orca" orchestration worker-list --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) || return 1
    row=$(jq -r --arg id "$id" '[.result.workers[]? | select(.dispatchId==$id)] | .[0] // empty | @json' <<<"$page")
    [ -n "$row" ] && [ "$row" != null ] && { printf '%s' "$row"; return 0; }
    cursor=$(jq -r '.result.nextCursor // .result.page.nextCursor // empty' <<<"$page")
    [ -n "$cursor" ] || break
  done
  return 1
}

pr_review_gates_worker_agent_model() { # <dispatch> -> prints "agent<TAB>model" or fails
  local id=$1 out agent model row wt
  out=$(pr_review_gates_worker_show "$id" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    agent=$(jq -r '.result.agent // .result.dispatch.agent // .result.worker.agent // empty' <<<"$out")
    model=$(jq -r '.result.model // .result.dispatch.model // .result.worker.model // empty' <<<"$out")
    if [ -n "$agent" ] && [ -n "$model" ]; then
      printf '%s\t%s\n' "$agent" "$model"
      return 0
    fi
  fi
  local launch_pair
  launch_pair=$(pr_review_gates_launch_agent_model_for_dispatch "$id")
  if [ -n "$launch_pair" ] && grep -q $'\t' <<<"$launch_pair"; then
    printf '%s\n' "$launch_pair"
    return 0
  fi
  row=$(pr_review_gates_worker_list_row "$id" 2>/dev/null) || return 1
  agent=$(jq -r '.agent // empty' <<<"$row")
  wt=$(pr_review_gates_workspace_path "$(jq -r '.workspace // empty' <<<"$row")")
  model=$(pr_review_gates_launch_model_for_worktree "$wt")
  if [ -z "$model" ]; then
    model=$(jq -r '.model // empty' <<<"$row")
  fi
  [ -n "$agent" ] && [ -n "$model" ] || return 1
  printf '%s\t%s\n' "$agent" "$model"
}

pr_review_gates_resolve_builder_dispatch() { # <verdict author> <head_branch> <refuse_fn>
  local author=$1 branch=$2 refuse=$3 row wt path id orca cursor="" page
  PRG_BUILDER_DISPATCH=""
  if [[ "$author" == ctx_* ]]; then
    PRG_BUILDER_DISPATCH=$author
    return 0
  fi
  if [ "$author" != unknown ]; then
    $refuse "verdict author $author is not a builder dispatch"
    return 1
  fi
  [ -n "$branch" ] || { $refuse "cannot resolve builder: verdict author is unknown and head branch is missing"; return 1; }
  orca=$(pr_review_gates_orca)
  id=""
  for _ in $(seq 1 50); do
    page=$("$orca" orchestration worker-list --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) || break
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      wt=$(pr_review_gates_workspace_path "$(jq -r '.workspace // empty' <<<"$row")")
      path=$(basename "$wt")
      if [ "$path" = "$branch" ] || [[ "$wt" == */"$branch" ]]; then
        id=$(jq -r '.dispatchId // empty' <<<"$row")
        [ -n "$id" ] && break
      fi
    done < <(jq -r '.result.workers[]? | @json' <<<"$page" 2>/dev/null)
    [ -n "$id" ] && break
    cursor=$(jq -r '.result.nextCursor // .result.page.nextCursor // empty' <<<"$page")
    [ -n "$cursor" ] || break
  done
  [ -n "$id" ] || { $refuse "cannot resolve builder dispatch for branch $branch"; return 1; }
  PRG_BUILDER_DISPATCH=$id
  return 0
}

pr_review_gates_self_review_head() { # <body>
  local body=$1 section sha
  section=$(printf '%s' "$body" | awk '
    /^## Self-review([[:space:]]|$)/ { on=1; next }
    /^## / { if (on) exit; on=0 }
    on { print }
  ')
  sha=$(printf '%s' "$section" | grep -Eo '[0-9a-f]{40}' | head -1)
  printf '%s' "$sha"
}

pr_review_gate_self_review() { # <pr_body> <head_sha> <refuse_fn> [carry_fn_name]
  local body=$1 head=$2 refuse=$3 carry=${4:-} reviewed
  reviewed=$(pr_review_gates_self_review_head "$body")
  [ -n "$reviewed" ] || { $refuse "missing ## Self-review naming head $head"; return 1; }
  [ "$reviewed" = "$head" ] && return 0
  if [ -n "$carry" ] && declare -F "$carry" >/dev/null 2>&1 && "$carry" "$reviewed" "$head"; then
    return 0
  fi
  $refuse "no self-review at head $head (reviewed $reviewed)"
  return 1
}

pr_review_gate_verifier_known() { # <verifier_id> <builder_dispatch> <known_dispatches_newline> <refuse_fn>
  local verifier=$1 builder=$2 known=$3 refuse=$4
  [ -n "$builder" ] && [ "$verifier" = "$builder" ] && { $refuse "verifier $verifier is the PR builder"; return 1; }
  if pr_review_gates_is_coordinator_id "$verifier"; then
    return 0
  fi
  if [ -n "$known" ]; then
    grep -Fxq -- "$verifier" <<<"$known" && return 0
    $refuse "verdict verifier $verifier is not a known dispatch"
    return 1
  fi
  if ! pr_review_gates_worker_show "$verifier" >/dev/null; then
    $refuse "verdict verifier $verifier is not a known dispatch"
    return 1
  fi
  return 0
}

pr_review_gate_coordinator_verdict() { # <verifier> <author> <builder_dispatch> <refuse_fn>
  local verifier=$1 author=$2 builder=$3 refuse=$4 pair agent
  [ -n "$builder" ] || { $refuse "missing builder dispatch for coordinator verdict check"; return 1; }
  pair=$(pr_review_gates_worker_agent_model "$builder" 2>/dev/null) || {
    $refuse "cannot resolve builder agent/model for $builder"
    return 1
  }
  agent=${pair%%$'\t'*}
  [ "$agent" = cursor ] || return 0
  pr_review_gates_is_coordinator_id "$verifier" || { $refuse "verdict verifier $verifier is not a coordinator identity"; return 1; }
  if [ "$author" != "$builder" ]; then
    $refuse "cursor PR verdict must name builder $builder as author (got $author)"
    return 1
  fi
  return 0
}

pr_review_gate_same_agent_model() { # <verifier> <builder_dispatch> <refuse_fn>
  local verifier=$1 builder=$2 refuse=$3 pair v_agent v_model b_agent b_model
  pr_review_gates_is_coordinator_id "$verifier" && return 0
  [ -n "$builder" ] || { $refuse "missing builder dispatch for cross-model review check"; return 1; }
  pair=$(pr_review_gates_worker_agent_model "$verifier" 2>/dev/null) || {
    $refuse "cannot resolve verifier agent/model for $verifier"
    return 1
  }
  v_agent=${pair%%$'\t'*}
  v_model=${pair#*$'\t'}
  pair=$(pr_review_gates_worker_agent_model "$builder" 2>/dev/null) || {
    $refuse "cannot resolve builder agent/model for $builder"
    return 1
  }
  b_agent=${pair%%$'\t'*}
  b_model=${pair#*$'\t'}
  if [ "$v_agent" = "$b_agent" ] && [ "$v_model" = "$b_model" ]; then
    $refuse "verifier and builder share agent=$v_agent model=$v_model"
    return 1
  fi
  return 0
}
