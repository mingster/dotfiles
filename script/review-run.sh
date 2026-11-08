#!/usr/bin/env bash
# Run a read-only cold review prompt with the chosen agent CLI. Sources review-run helpers only.
# Requires: REVIEW_RUN_AGENT, REVIEW_RUN_MODEL, REVIEW_RUN_EFFORT (optional), REVIEW_RUN_PROMPT, REVIEW_RUN_WORKDIR
set -euo pipefail

review_run_invoke() {
  : "${REVIEW_RUN_AGENT:?}"
  : "${REVIEW_RUN_MODEL:?}"
  : "${REVIEW_RUN_PROMPT:?}"
  : "${REVIEW_RUN_WORKDIR:?}"
  local effort=()
  [ -n "${REVIEW_RUN_EFFORT:-}" ] && effort=(--effort "$REVIEW_RUN_EFFORT")
  case "$REVIEW_RUN_AGENT" in
    claude)
      (cd "$REVIEW_RUN_WORKDIR" && claude -p "$REVIEW_RUN_PROMPT" --model "$REVIEW_RUN_MODEL" \
        "${effort[@]+"${effort[@]}"}" \
        --allowedTools "Read,Grep,Glob" --disallowedTools "Bash,Edit,Write,WebFetch,WebSearch")
      ;;
    antigravity)
      (cd "$REVIEW_RUN_WORKDIR" && agy --model "$REVIEW_RUN_MODEL" --dangerously-skip-permissions \
        -p "$REVIEW_RUN_PROMPT")
      ;;
    cursor)
      local agent_cmd=agent
      command -v agent >/dev/null 2>&1 || agent_cmd=cursor-agent
      (cd "$REVIEW_RUN_WORKDIR" && "$agent_cmd" -p "$REVIEW_RUN_PROMPT" --model "$REVIEW_RUN_MODEL" \
        --mode ask)
      ;;
    *)
      echo "unsupported review agent: $REVIEW_RUN_AGENT" >&2
      return 1
      ;;
  esac
}
