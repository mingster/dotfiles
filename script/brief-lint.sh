#!/usr/bin/env bash
# Lint a worker brief for the parts a person must write: Refs, Acceptance, Out of scope, Verify.
# The fixed Finish steps are appended by worker-startup.sh (#968), so they are not checked here.
# An optional "Type:" line is build (the default when the line is absent), rework, verify, or
# rule/guide change (also "rule/guide"). A rule/guide brief names one rg, grep, or git grep
# command, in backticks or alone on a line under Acceptance or Verify, for the builder and the
# verifier. A command under Out of scope does not count. A rework brief links the Verdict
# (a comment URL plus the word Verdict) and has a Self-check acceptance item.
# Usage: brief-lint.sh <file>
set -euo pipefail

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
  file=/dev/null
fi

awk '
function note_search(cmd,    key) {
  key = cmd
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
  sub(/[.;]+$/, "", key)
  gsub(/[[:space:]]+/, " ", key)
  if (key ~ /^git grep[[:space:]]+[^[:space:]]/) searches[key] = 1
  else if (key ~ /^(grep|rg)[[:space:]]+[^[:space:]]/) searches[key] = 1
}

function harvest_searches(line,    rest, chunk, bare) {
  if (sec == "Out of scope") return
  rest = line
  while (match(rest, /`[^`]+`/)) {
    chunk = substr(rest, RSTART + 1, RLENGTH - 2)
    note_search(chunk)
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (index(line, "`") > 0) return
  bare = line
  sub(/^[[:space:]]*(-|\*)[[:space:]]+/, "", bare)
  sub(/^\[[ xX]\][[:space:]]+/, "", bare)
  note_search(bare)
}

{
  sub(/\r$/, "")
  harvest_searches($0)
  if (sec != "Out of scope") {
    prose = $0
    gsub(/`[^`]*`/, " ", prose)
    low = tolower(prose)
    if (low ~ /(^|[^a-z])builder([^a-z]|$)/) saw_builder = 1
    if (low ~ /(^|[^a-z])verifier([^a-z]|$)/) saw_verifier = 1
  }
  if ($0 ~ /https?:\/\/[^[:space:]]*#issuecomment-[0-9]+/) has_verdict_url = 1
  if (index($0, "Verdict") > 0) has_verdict_word = 1
}
/^Type:/ {
  type_count++
  brief_type = $0
  sub(/^Type:[[:space:]]*/, "", brief_type)
  sub(/[[:space:]]+$/, "", brief_type)
  next
}
/Refs [A-Za-z0-9_.\/-]*#[0-9]+/ {
  has_refs = 1
}
# Bold labels from the triage Agent Brief template: **Acceptance criteria:**, **Out of scope:**.
/^\*\*[^*]+:\*\*/ {
  if ($0 ~ /^\*\*Acceptance( criteria)?:\*\*/) sec = "Acceptance"
  else if ($0 ~ /^\*\*(Out of scope|Non-goals|Allowed files \/ scope boundaries):\*\*/) sec = "Out of scope"
  else sec = ""
  rest = $0
  sub(/^\*\*[^*]+:\*\*/, "", rest)
  if (sec == "Out of scope" && rest ~ /[^[:space:]]/) has_out_of_scope = 1
  next
}
/^[[:space:]]*-[[:space:]]+\*\*(Out of scope|Non-goals|Allowed files \/ scope boundaries):\*\*/ {
  rest = $0
  sub(/^[[:space:]]*-[[:space:]]+\*\*[^*]+:\*\*/, "", rest)
  if (rest ~ /[^[:space:]]/) has_out_of_scope = 1
  next
}
/^Leave alone:[[:space:]]*[^[:space:]]/ {
  has_out_of_scope = 1
  next
}
/^## / {
  if ($0 ~ /^## Acceptance( criteria)?([[:space:]]|$)/) sec = "Acceptance"
  else if ($0 ~ /^## (Out of scope|Non-goals|Scope)([[:space:]]|$)/) sec = "Out of scope"
  else if ($0 ~ /^## Verify([[:space:]]|$)/) sec = "Verify"
  else sec = ""
  next
}
sec == "Acceptance" && /^[[:space:]]*- / {
  line = $0
  sub(/^[[:space:]]*- (\[\][[:space:]]*|\[[[:space:]]\][[:space:]]*)?/, "", line)
  if (line ~ /[^[:space:]]/) has_acceptance = 1
  if (index($0, "Self-check") > 0) has_self_check = 1
}
sec == "Out of scope" && /[^[:space:]]/ {
  has_out_of_scope = 1
}
sec == "Verify" && /[^[:space:]]/ {
  has_verify = 1
  if ($0 ~ /checks-local\.sh/) has_checks_local = 1
  if ($0 ~ /GitHub Checks are green/) github_green = 1
}
/^Role: qa-sdet([^[:alnum:]-]|$)/ { qa_sdet = 1 }
END {
  rc = 0
  nsearch = 0
  for (s in searches) nsearch++
  if (!has_refs) { print "brief-lint: missing Refs"; rc = 1 }
  if (!has_acceptance) { print "brief-lint: missing Acceptance"; rc = 1 }
  if (!has_out_of_scope) { print "brief-lint: missing Out of scope"; rc = 1 }
  if (!has_verify) { print "brief-lint: missing Verify"; rc = 1 }
  if (has_verify && !has_checks_local && !(qa_sdet && github_green)) { print "brief-lint: Verify must run script/checks-local.sh"; rc = 1 }
  if (type_count > 1) {
    print "brief-lint: brief has more than one Type"; rc = 1
  } else if (type_count == 1 && brief_type != "build" && brief_type != "rework" && brief_type != "verify" && brief_type != "rule/guide" && brief_type != "rule/guide change") {
    print "brief-lint: unknown brief type"; rc = 1
  } else if (brief_type == "rework") {
    if (!(has_verdict_url && has_verdict_word)) { print "brief-lint: rework brief must link the Verdict"; rc = 1 }
    if (!has_self_check) { print "brief-lint: rework brief must require a Self-check"; rc = 1 }
  } else if (brief_type == "rule/guide" || brief_type == "rule/guide change") {
    if (nsearch != 1 || !saw_builder || !saw_verifier) {
      print "brief-lint: rule/guide brief must name one search command for the builder and the verifier"; rc = 1
    }
  }
  exit rc
}
' "$file"
