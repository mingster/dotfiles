#!/usr/bin/env bash
# Lint a worker brief for the parts a person must write: Refs, Acceptance, Out of scope, Verify.
# The fixed Finish steps are appended by worker-startup.sh (#968), so they are not checked here.
# An optional "Type:" line is build (the default when the line is absent), rework, verify, or
# rule/guide change (also "rule/guide"). A rule/guide brief names one rg, grep, or git grep
# command, in backticks or alone on a line under Acceptance or Verify, for the builder and the
# verifier. A command under Out of scope does not count. A verify brief names script/post-verdict.sh
# or the exact first line (Verdict: PASS|PASS+NOTES|FAIL head=<40 hex> ...), since ship.sh parses only that (#1157). A rework brief links the Verdict
# (a comment URL plus the word Verdict) and has a Self-check acceptance item.
# Verify must name script/checks-local.sh unless a target repo dir is given that has no such script (#1195).
# Refs is "Refs #<n>", "Refs: #<n>", "Closes #<n>", "Fixes #<n>" or "Resolves #<n>", each with an optional owner/repo before the #.
# --issue-body lints a draft issue body: the issue has no number yet, so Refs is not required (#1201).
# A builder brief (any Type but verify) whose "Allowed files" names an owner gated path (script/lib/protected-paths.sh) gets a
# "brief-lint: warning:" line. The exit code does not change (#1328).
# #1840: a brief that runs install-fleet-automations.sh, a setup-*.sh or install.sh (outside Out of scope and
# Allowed files) runs it with --dry-run first and has a "Side effects:" line; a script with no --dry-run cannot be
# run from a brief. A build or rework brief whose Allowed files is under web/src/app or a components folder has a
# 390x844 phone step. An explicit "Type: build" brief has a "Tests:" line naming test files.
# Usage: brief-lint.sh [--issue-body] <file> [<target-repo-dir>]   (-h and --help print this line; an unreadable file exits 2)
set -euo pipefail

lint_rc=0
lint_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
print_usage() { sed -n '/^# Usage:/{s/^# //p;q;}' "${BASH_SOURCE[0]}"; }
need_refs=1
case "${1:-}" in -h|--help) print_usage; exit 0 ;; esac
if [ "${1:-}" = --issue-body ]; then
  need_refs=0
  shift
fi

file="${1:-}"
case "$file" in -h|--help) print_usage; exit 0 ;; esac
if [ -z "$file" ]; then
  print_usage >&2
  exit 2
fi
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "brief-lint: cannot read $file" >&2
  exit 2
fi
repo_dir="${2:-}"
need_checks_local=1
if [ -n "$repo_dir" ] && [ -d "$repo_dir" ] && [ ! -f "$repo_dir/script/checks-local.sh" ]; then
  need_checks_local=0
fi

# Bytes, not characters: BSD awk in a UTF-8 locale dies with "towc: multibyte conversion failure" when match()
# and substr() split a multibyte character (#1886). Every pattern below is ASCII, so byte mode matches the same.
LC_ALL=C awk -v need_checks_local="$need_checks_local" -v need_refs="$need_refs" -v repo_root="${repo_dir:-$lint_here/..}" '
# The script path when cmd runs an installer (interpreter, arguments, or a ./ or ~/ path), else "".
# A bare name such as `install.sh` is a mention, not a run.
function installer_run(cmd,    c, interp, path, rest, base) {
  c = cmd
  sub(/^[[:space:]]+/, "", c)
  sub(/^\$[[:space:]]+/, "", c)
  while (c ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", c)
  interp = 0
  if (c ~ /^(bash|sh|zsh)[[:space:]]+/) { interp = 1; sub(/^(bash|sh|zsh)[[:space:]]+/, "", c) }
  if (!match(c, /^[^[:space:]]+/)) return ""
  path = substr(c, 1, RLENGTH)
  rest = substr(c, RLENGTH + 1)
  base = path
  sub(/.*\//, "", base)
  if (base !~ /^(install-fleet-automations|setup-[A-Za-z0-9_-]+|install)\.sh$/) return ""
  if (!interp && rest !~ /[^[:space:]]/ && path !~ /^(\.|~)\//) return ""
  return path
}

# 1 when the script in the target repo (script/<name>, or install.sh at the root) has a --dry-run flag, 0 when it has
# none, 1 when it is not here (another repo), since only its own file can say.
function supports_dry_run(base,    f, l, found, rc) {
  f = (base == "install.sh") ? repo_root "/install.sh" : repo_root "/script/" base
  found = 0
  rc = (getline l < f)
  if (rc < 0) return 1
  while (rc > 0) {
    if (index(l, "--dry-run") > 0) found = 1
    rc = (getline l < f)
  }
  close(f)
  return found
}

function note_installer(cmd,    path, base) {
  path = installer_run(cmd)
  if (path == "") return
  base = path
  sub(/.*\//, "", base)
  if (!(base in installers)) { installers[base] = 1; installer_order[++ninstallers] = base }
  if (!(base in installer_first_dry)) installer_first_dry[base] = (cmd ~ /(^|[[:space:]])--dry-run([[:space:]=]|$)/) ? 1 : 0
}

# A run is a command in backticks or alone on a line, or "run <installer>" in prose (also "run `<name>`").
# Out of scope, Allowed files and context sections (Problem, Background ...) never run anything.
function harvest_installers(line,    rest, chunk, pre, prose, low, cmd, bare, rstart, rlen) {
  if (sec == "Out of scope" || sec == "Allowed" || sec == "Context" || line ~ /^(\*\*)?Allowed files:/) return
  rest = line
  prose = ""
  while (match(rest, /`[^`]+`/)) {
    # note_installer runs installer_run, which overwrites the awk globals RSTART and RLENGTH, so save them first.
    rstart = RSTART
    rlen = RLENGTH
    pre = substr(rest, 1, rstart - 1)
    chunk = substr(rest, rstart + 1, rlen - 2)
    prose = prose pre " "
    cmd = chunk
    # "run `bash x.sh`" already names its interpreter, so only a bare "run `x.sh`" gets one added.
    if (tolower(pre) ~ /(^|[^a-z])(run|runs|rerun|re-run)[[:space:]]+$/ && cmd !~ /^(bash|sh|zsh)[[:space:]]/) cmd = "bash " cmd
    note_installer(cmd)
    rest = substr(rest, rstart + rlen)
  }
  prose = prose rest
  low = tolower(prose)
  while (match(low, /(^|[^a-z])(run|runs|rerun|re-run)[[:space:]]+[^[:space:]]*(install-fleet-automations|setup-[a-z0-9_-]+|install)\.sh([[:space:]]+-[^[:space:],;]+)*/)) {
    rstart = RSTART
    rlen = RLENGTH
    cmd = substr(prose, rstart, rlen)
    sub(/^[^A-Za-z]*[A-Za-z-]+[[:space:]]+/, "", cmd)
    note_installer("bash " cmd)
    prose = substr(prose, rstart + rlen)
    low = substr(low, rstart + rlen)
  }
  if (index(line, "`") > 0) return
  bare = line
  sub(/^[[:space:]]*((-|\*)[[:space:]]+|[0-9]+[.)][[:space:]]+)/, "", bare)
  sub(/^\[[ xX]\][[:space:]]+/, "", bare)
  sub(/^[A-Za-z ]+:[[:space:]]+/, "", bare)
  note_installer(bare)
}

function note_allowed(text,    n, i, toks, t) {
  gsub(/[,`"\047]/, " ", text)
  n = split(text, toks, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    t = toks[i]
    sub(/^\.\//, "", t)
    if (t ~ /(^|\/)web\/src\/app(\/|$)/ || t ~ /(^|\/)components(\/|$)/) ui_brief = 1
  }
}

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
  harvest_installers($0)
  if ($0 ~ /^(\*\*)?Allowed files:(\*\*)?/) {
    rest = $0
    sub(/^(\*\*)?Allowed files:(\*\*)?/, "", rest)
    note_allowed(rest)
  } else if (sec == "Allowed") {
    note_allowed($0)
  }
  if (sec != "Out of scope") {
    if (index($0, "390x844") > 0) has_phone = 1
    if ($0 ~ /^[[:space:]]*([-*][[:space:]]+)?(\*\*)?Side effects:(\*\*)?[[:space:]]*[^[:space:]]/) has_side_effects = 1
    if ($0 ~ /^[[:space:]]*([-*][[:space:]]+)?(\*\*)?Tests:(\*\*)?[[:space:]]/) {
      rest = $0
      sub(/^[[:space:]]*([-*][[:space:]]+)?(\*\*)?Tests:(\*\*)?/, "", rest)
      if (tolower(rest) ~ /[^[:space:],`]*(test|spec)[^[:space:],`]*\.[A-Za-z0-9]+/) has_tests = 1
    }
  }
  if (sec != "Out of scope") {
    prose = $0
    gsub(/`[^`]*`/, " ", prose)
    low = tolower(prose)
    if (low ~ /(^|[^a-z])builder([^a-z]|$)/) saw_builder = 1
    if (low ~ /(^|[^a-z])verifier([^a-z]|$)/) saw_verifier = 1
  }
  if ($0 ~ /https?:\/\/[^[:space:]]*#issuecomment-[0-9]+/) has_verdict_url = 1
  if (index($0, "Verdict") > 0) has_verdict_word = 1
  if ($0 ~ /post-verdict\.sh/ || $0 ~ /Verdict: (PASS|FAIL)[^[:space:]]* head=/) has_verdict_format = 1
}
/^Type:/ {
  type_count++
  brief_type = $0
  sub(/^Type:[[:space:]]*/, "", brief_type)
  sub(/[[:space:]]+$/, "", brief_type)
  next
}
/(Refs|Closes|Fixes|Resolves):?[[:space:]]+[A-Za-z0-9_.\/-]*#[0-9]+/ {
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
  else if ($0 ~ /^## Allowed files([[:space:]]|$)/) sec = "Allowed"
  else if ($0 ~ /^## (Problem|Why|Background|Context|Evidence|Source|Owner decision)/) sec = "Context"
  else sec = ""
  next
}
sec == "Acceptance" && /^[[:space:]]*(- |[0-9]+[.)] )/ {
  line = $0
  sub(/^[[:space:]]*([0-9]+[.)] |- )(\[\][[:space:]]*|\[[[:space:]]\][[:space:]]*)?/, "", line)
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
  if (need_refs == 1 && !has_refs) { print "brief-lint: missing Refs"; rc = 1 }
  if (!has_acceptance) { print "brief-lint: missing Acceptance"; rc = 1 }
  if (!has_out_of_scope) { print "brief-lint: missing Out of scope"; rc = 1 }
  if (!has_verify) { print "brief-lint: missing Verify"; rc = 1 }
  if (need_checks_local == 1 && has_verify && !has_checks_local && !(qa_sdet && github_green)) { print "brief-lint: Verify must run script/checks-local.sh"; rc = 1 }
  if (type_count > 1) {
    print "brief-lint: brief has more than one Type"; rc = 1
  } else if (type_count == 1 && brief_type != "build" && brief_type != "rework" && brief_type != "verify" && brief_type != "rule/guide" && brief_type != "rule/guide change") {
    print "brief-lint: unknown brief type"; rc = 1
  } else if (brief_type == "verify") {
    if (!has_verdict_format) { print "brief-lint: verify brief must name script/post-verdict.sh or the exact Verdict first line"; rc = 1 }
  } else if (brief_type == "rework") {
    if (!(has_verdict_url && has_verdict_word)) { print "brief-lint: rework brief must link the Verdict"; rc = 1 }
    if (!has_self_check) { print "brief-lint: rework brief must require a Self-check"; rc = 1 }
  } else if (brief_type == "rule/guide" || brief_type == "rule/guide change") {
    if (nsearch != 1 || !saw_builder || !saw_verifier) {
      print "brief-lint: rule/guide brief must name one search command for the builder and the verifier"; rc = 1
    }
  }
  for (i = 1; i <= ninstallers; i++) {
    b = installer_order[i]
    if (!supports_dry_run(b)) { print "brief-lint: " b " has no --dry-run, so a brief cannot run it; the owner runs it"; rc = 1 }
    else if (!installer_first_dry[b]) { print "brief-lint: the first run of " b " must use --dry-run"; rc = 1 }
  }
  if (ninstallers > 0 && !has_side_effects) { print "brief-lint: a brief that runs an installer needs a Side effects: line"; rc = 1 }
  is_builder = (type_count <= 1 && (brief_type == "" || brief_type == "build" || brief_type == "rework"))
  if (is_builder && ui_brief && !has_phone) { print "brief-lint: UI brief needs a 390x844 phone check step"; rc = 1 }
  if (type_count == 1 && brief_type == "build" && !has_tests) { print "brief-lint: build brief needs a Tests: line naming test files"; rc = 1 }
  exit rc
}
' "$file" || lint_rc=$?

# Warn when a builder brief lets the worker edit an owner gated path. Tokens split without globbing, \r stripped.
warn_owner_paths() {
  [ -r "$file" ] && [ -r "$lint_here/lib/protected-paths.sh" ] || return 0
  # shellcheck source=lib/protected-paths.sh
  . "$lint_here/lib/protected-paths.sh"
  local line sec="" body tok seen=" " btype="" warns=""
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in Type:*) btype=${line#Type:}; btype=${btype//[[:space:]]/} ;; esac
    body=""
    case "$line" in
      "## Allowed files"*) sec=heading; continue ;;
      "## "*) sec="" ;;
      "**Allowed files:**"*) sec=inline; body=${line#"**Allowed files:**"} ;;
      "Allowed files:"*) sec=inline; body=${line#"Allowed files:"} ;;
      *) if [ -z "${line//[[:space:]]/}" ]; then [ "$sec" = heading ] || sec=""; elif [ -n "$sec" ]; then body=$line; fi ;;
    esac
    [ -n "$body" ] || continue
    body=${body//,/ }; body=${body//\`/ }; body=${body//\"/ }; body=${body//\'/ }
    for tok in $body; do
      tok=${tok#./}; tok=${tok%%[.;:)]}
      [ -n "$tok" ] || continue
      case "$seen" in *" $tok "*) continue ;; esac
      seen="$seen$tok "
      if owner_only_path "$tok" || protected_path "$tok"; then
        warns="${warns}brief-lint: warning: Allowed files names owner gated path $tok; the PR waits for the owner"$'\n'
      fi
    done
  done <"$file"
  set +f
  [ "$btype" = verify ] || printf '%s' "$warns"
}
warn_owner_paths
exit "$lint_rc"
