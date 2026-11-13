#!/usr/bin/env bash
# Lint a worker brief file for required sections before dispatch.
# Usage: brief-lint.sh <file>
set -euo pipefail

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
  file=/dev/null
fi

awk '
{
  sub(/\r$/, "")
}
/Refs [A-Za-z0-9_.\/-]*#[0-9]+/ {
  has_refs = 1
}
tolower($0) ~ /fullstack-dev/ {
  is_builder = 1
}
# Bold labels from the triage Agent Brief template: **Acceptance criteria:**, **Out of scope:**.
/^\*\*[^*]+:\*\*/ {
  if ($0 ~ /^\*\*Acceptance( criteria)?:\*\*/) sec = "Acceptance"
  else if ($0 ~ /^\*\*Out of scope:\*\*/) sec = "Out of scope"
  else sec = ""
  rest = $0
  sub(/^\*\*[^*]+:\*\*/, "", rest)
  if (sec == "Out of scope" && rest ~ /[^[:space:]]/) has_out_of_scope = 1
  next
}
/^## / {
  if ($0 ~ /^## Acceptance( criteria)?([[:space:]]|$)/) sec = "Acceptance"
  else if ($0 ~ /^## Out of scope([[:space:]]|$)/) sec = "Out of scope"
  else if ($0 ~ /^## Verify([[:space:]]|$)/) sec = "Verify"
  else if ($0 ~ /^## Finish([[:space:]]|$)/) sec = "Finish"
  else sec = ""
  next
}
sec == "Acceptance" && /^[[:space:]]*- / {
  line = $0
  sub(/^[[:space:]]*- (\[\][[:space:]]*|\[[[:space:]]\][[:space:]]*)?/, "", line)
  if (line ~ /[^[:space:]]/) has_acceptance = 1
}
sec == "Out of scope" && /[^[:space:]]/ {
  has_out_of_scope = 1
}
sec == "Verify" && /[^[:space:]]/ {
  has_verify = 1
  if ($0 ~ /checks-local\.sh/) has_checks_local = 1
}
sec == "Finish" && /[^[:space:]]/ {
  has_finish = 1
  if (tolower($0) ~ /self-review|self review/) has_self_review = 1
  if (tolower($0) ~ /40 hex/) has_full_sha = 1
  if (tolower($0) ~ /push/) has_rewrite = 1
  if ($0 ~ /workspace-status in-review/) has_in_review = 1
  if ($0 ~ /gh pr checks|gh run list/) has_green = 1
}
END {
  rc = 0
  if (!has_refs) { print "brief-lint: missing Refs"; rc = 1 }
  if (!has_acceptance) { print "brief-lint: missing Acceptance"; rc = 1 }
  if (!has_out_of_scope) { print "brief-lint: missing Out of scope"; rc = 1 }
  if (!has_verify) { print "brief-lint: missing Verify"; rc = 1 }
  if (has_verify && !has_checks_local) { print "brief-lint: Verify must run script/checks-local.sh"; rc = 1 }
  if (!has_finish) { print "brief-lint: missing Finish"; rc = 1 }
  if (has_finish && !has_self_review) { print "brief-lint: missing Finish self-review step"; rc = 1 }
  # Every Finish moves the Orca board card to in-review before worker_done, so wrap-up can tell finished work from running work.
  if (has_finish && !has_in_review) { print "brief-lint: Finish must run orca worktree set --worktree active --workspace-status in-review before worker_done"; rc = 1 }
  # A fullstack-dev Finish writes ## Self-review with the full 40 hex head sha, and rewrites it after every push.
  if (is_builder && has_self_review && !(has_full_sha && has_rewrite)) { print "brief-lint: Finish must say the builder writes ## Self-review with the full 40 hex head sha and rewrites it after every push"; rc = 1 }
  # A fullstack-dev Finish waits for green PR checks at the final head before worker_done (#940).
  if (is_builder && has_finish && !has_green) { print "brief-lint: Finish must wait for green PR checks at the final head (gh pr checks <n> --watch --fail-fast, or gh run list --branch <branch>) before worker_done"; rc = 1 }
  exit rc
}
' "$file"
