#!/usr/bin/env bash
# Shared model pick for cold review on gate and workflow paths (no project-specific names).
# Before calling review_model_pick, set:
#   REVIEW_MODEL_HAS_REVIEW_STRONG (0|1)
#   REVIEW_MODEL_NAMES_MULTILINE — newline-separated changed paths (same set as pr-review names)
# Exports: REVIEW_MODEL, REVIEW_MODEL_DUAL, REVIEW_AGENT (claude|antigravity)

REVIEW_MODEL_STRONG='^\.github/|^\.claude/hooks/|^\.orca/|^script/usage-gate\.py|^script/heavy-gate|^script/head-checks|^script/(coordinator-publication|fleet-watch|post-verdict|lead-merge|pr-review)\.sh'
REVIEW_MODEL_MONEY='(^|/)(payment|payments|stripe|wallet|ledger|billing|subscription|secrets)'

review_model_pick() {
  REVIEW_MODEL=sonnet
  REVIEW_MODEL_DUAL=0
  REVIEW_AGENT=claude
  if [ "${REVIEW_MODEL_HAS_REVIEW_STRONG:-0}" -eq 1 ]; then
    REVIEW_MODEL=opus
  fi
  if grep -qiE "$REVIEW_MODEL_STRONG" <<<"${REVIEW_MODEL_NAMES_MULTILINE:-}"; then
    REVIEW_MODEL=opus
  fi
  if grep -qiE "$REVIEW_MODEL_MONEY" <<<"${REVIEW_MODEL_NAMES_MULTILINE:-}"; then
    REVIEW_MODEL=opus
    REVIEW_MODEL_DUAL=1
  fi
}
