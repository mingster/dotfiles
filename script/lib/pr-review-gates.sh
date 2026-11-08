# Shared review gates for ship.sh and lead-merge.sh (issue #760).
# shellcheck shell=bash

pr_review_gates_orca() { printf '%s\n' "${ORCA_CLI_COMMAND:-orca}"; }

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

pr_review_gates_worker_agent_model() { # <dispatch> -> prints "agent<TAB>model" or fails
  local id=$1 out agent model
  out=$(pr_review_gates_worker_show "$id") || return 1
  agent=$(jq -r '.result.agent // .result.dispatch.agent // .result.worker.agent // empty' <<<"$out")
  model=$(jq -r '.result.model // .result.dispatch.model // .result.worker.model // empty' <<<"$out")
  [ -n "$agent" ] && [ -n "$model" ] || return 1
  printf '%s\t%s\n' "$agent" "$model"
}

# Builder: dispatch=<id> agent=<name> model=<id> (one line in PR body)
pr_review_gates_parse_builder() { # <body> -> dispatch agent model on stdout or rc 1
  local body=$1 line
  line=$(printf '%s' "$body" | grep -m1 -E '^Builder:[[:space:]]+' || true)
  [ -n "$line" ] || return 1
  if [[ "$line" =~ dispatch=([^[:space:]]+) ]]; then PRG_BUILDER_DISPATCH="${BASH_REMATCH[1]}"; else return 1; fi
  if [[ "$line" =~ agent=([^[:space:]]+) ]]; then PRG_BUILDER_AGENT="${BASH_REMATCH[1]}"; else return 1; fi
  if [[ "$line" =~ model=([^[:space:]]+) ]]; then PRG_BUILDER_MODEL="${BASH_REMATCH[1]}"; else return 1; fi
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

pr_review_gate_self_review() { # <pr_body> <head_sha> <refuse_fn>
  local body=$1 head=$2 refuse=$3 reviewed
  reviewed=$(pr_review_gates_self_review_head "$body")
  [ -n "$reviewed" ] || { $refuse "missing ## Self-review naming head $head"; return 1; }
  [ "$reviewed" = "$head" ] || { $refuse "no self-review at head $head (reviewed $reviewed)"; return 1; }
}

pr_review_gate_verifier_known() { # <verifier_id> <known_dispatches_newline> <refuse_fn>
  local verifier=$1 known=$2 refuse=$3
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

pr_review_gate_coordinator_verdict() { # <verifier> <author> <pr_body> <refuse_fn>
  local verifier=$1 author=$2 body=$3 refuse=$4
  pr_review_gates_parse_builder "$body" || return 0
  [ "${PRG_BUILDER_AGENT:-}" = cursor ] || return 0
  pr_review_gates_is_coordinator_id "$verifier" || { $refuse "verdict verifier $verifier is not a coordinator identity"; return 1; }
  case "$author" in
    unknown) ;;
    *)
      if [[ "$author" == ctx_* ]]; then
        $refuse "forged coordinator verdict: author $author cannot supply a coordinator verifier"
        return 1
      elif ! pr_review_gates_is_coordinator_id "$author"; then
        $refuse "forged coordinator verdict: author $author is not a coordinator identity"
        return 1
      fi
      ;;
  esac
  return 0
}

pr_review_gate_same_agent_model() { # <verifier> <pr_body> <refuse_fn>
  local verifier=$1 body=$2 refuse=$3
  local pair v_agent v_model
  pr_review_gates_is_coordinator_id "$verifier" && return 0
  pr_review_gates_parse_builder "$body" || return 0
  pair=$(pr_review_gates_worker_agent_model "$verifier" 2>/dev/null) || return 0
  v_agent=${pair%%$'\t'*}
  v_model=${pair#*$'\t'}
  if [ "$v_agent" = "$PRG_BUILDER_AGENT" ] && [ "$v_model" = "$PRG_BUILDER_MODEL" ]; then
    $refuse "verifier and builder share agent=$v_agent model=$v_model"
    return 1
  fi
  return 0
}
