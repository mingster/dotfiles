#!/usr/bin/env bash
# Lint a worker brief file for the parts a person must write: Refs, Acceptance, Out of scope, Verify.
# The fixed Finish steps are appended by worker-startup.sh (#968), so they are not checked here.
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
END {
  rc = 0
  if (!has_refs) { print "brief-lint: missing Refs"; rc = 1 }
  if (!has_acceptance) { print "brief-lint: missing Acceptance"; rc = 1 }
  if (!has_out_of_scope) { print "brief-lint: missing Out of scope"; rc = 1 }
  if (!has_verify) { print "brief-lint: missing Verify"; rc = 1 }
  if (has_verify && !has_checks_local) { print "brief-lint: Verify must run script/checks-local.sh"; rc = 1 }
  exit rc
}
' "$file"
