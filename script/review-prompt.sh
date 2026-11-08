#!/usr/bin/env bash
# Shared cold-review prompt (live PR review and offline replay). Sourced by other scripts.
# After sourcing, set: REVIEW_PROMPT_PR (PR number as string), then call review_prompt_build.
# Exports: REVIEW_PROMPT (full prompt string).

review_prompt_build() {
  : "${REVIEW_PROMPT_PR:?REVIEW_PROMPT_PR must be set before review_prompt_build}"
  local tmpl
  tmpl=$(cd "$(dirname "${BASH_SOURCE[0]}")" && cat review-prompt.txt)
  REVIEW_PROMPT=${tmpl//\{\{PR\}\}/$REVIEW_PROMPT_PR}
}
