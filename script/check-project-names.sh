#!/usr/bin/env bash
# The one checker for project, host and company names in this public repo. Callers only invoke it:
# the commit-msg hook, checks-local.sh (worker self-check), ship.sh and no-project-names.test.sh.
# Usage: check-project-names.sh [--allow-missing] [--show-match] <input>...
#   --tracked          every tracked text file
#   --changed <base>   files this branch changed since the merge base with <base>
#   --commits <range>  the message of each commit in <range>, for example origin/main..HEAD
#   --file <path>      one text file, for example a PR title or body written to a temp file (repeatable)
# Pattern file (not in repo): ${NO_PROJECT_NAMES_FILE:-$XDG_CONFIG_HOME/dotfiles/project-names.pattern}
# One extended-regex fragment per line; blank lines ignored; lines are OR'd.
# Each problem goes to stderr as '<source>:<line>: <message>'; stdout gets 'N checked, M problems'.
# A missing pattern file is a problem, unless --allow-missing (hook, CI test): then 'SKIPPED' and exit 0.
# The matched word is hidden unless --show-match: CI posts this output to a public PR comment.
# Exit 0 clean, 1 problems, 2 usage error.
set -uo pipefail

allow_missing=0 show_match=0 tracked=0
changed_base="" commits="" files=()
usage() { echo "Usage: $0 [--allow-missing] [--show-match] [--tracked] [--changed <base>] [--commits <range>] [--file <path>]..." >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-missing) allow_missing=1; shift ;;
    --show-match) show_match=1; shift ;;
    --tracked) tracked=1; shift ;;
    --changed) [ $# -ge 2 ] || usage; changed_base=$2; shift 2 ;;
    --commits) [ $# -ge 2 ] || usage; commits=$2; shift 2 ;;
    --file) [ $# -ge 2 ] || usage; files+=("$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"); shift 2 ;;
    *) usage ;;
  esac
done
[ "$tracked" = 1 ] || [ -n "$changed_base" ] || [ -n "$commits" ] || [ "${#files[@]}" -gt 0 ] || usage

root=$(cd "$(dirname "$0")/.." && pwd -P)
pattern_file="${NO_PROJECT_NAMES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/project-names.pattern}"
checked=0 problems=0
problem() { echo "$1:$2: $3" >&2; problems=$((problems + 1)); }
finish() { echo "$checked checked, $problems problems"; [ "$problems" -eq 0 ]; exit $?; }

if [ ! -f "$pattern_file" ]; then
  if [ "$allow_missing" = 1 ]; then echo "SKIPPED (no pattern file; CI runs this)"; exit 0; fi
  problem "$pattern_file" 0 "pattern file missing; copy it from the coordinator, names cannot be checked"
  finish
fi
pattern=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  pattern="${pattern:+$pattern|}$line"
done <"$pattern_file"
if [ -z "$pattern" ]; then echo "skip: project-names pattern file empty ($pattern_file)"; exit 0; fi
printf '' | grep -qE -- "$pattern" 2>/dev/null; [ $? -le 1 ] || { problem "$pattern_file" 0 "invalid pattern"; finish; }

# Read grep -noi output ('line:word') on stdin for one source and report each line once.
report() { # <source>
  local ln word msg last=""
  while IFS=: read -r ln word; do
    [ "$ln" = "$last" ] && continue
    last=$ln
    msg='private name; say "a project" or "the production host" instead'
    [ "$show_match" = 1 ] && msg="private name \"$word\"; say \"a project\" or \"the production host\" instead"
    problem "$1" "$ln" "$msg"
  done
}

cd "$root" || exit 2
# The hook templates carry host names on purpose (they are matched by the test, not scanned).
skip_path() { case "$1" in templates/agent-team/.claude/hooks/*) return 0 ;; esac; return 1; }
scan_file() { # <path>
  skip_path "$1" && return
  [ -f "$1" ] || return
  checked=$((checked + 1))
  report "$1" < <(grep -noIiE -- "$pattern" "$1")
}

if [ "$tracked" = 1 ]; then
  while IFS= read -r -d '' f; do scan_file "$f"; done < <(git ls-files -z)
fi
if [ -n "$changed_base" ]; then
  mb=$(git merge-base "$changed_base" HEAD 2>/dev/null) || { echo "check-project-names: no merge base with $changed_base" >&2; exit 2; }
  while IFS= read -r f; do scan_file "$f"; done < <(git diff --diff-filter=d --name-only "$mb")
fi
if [ -n "$commits" ]; then
  shas=$(git rev-list "$commits" 2>/dev/null) || { echo "check-project-names: bad commit range $commits" >&2; exit 2; }
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    checked=$((checked + 1))
    report "${sha:0:12}" < <(git show -s --format=%B "$sha" | grep -noiE -- "$pattern")
  done <<<"$shas"
fi
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || { echo "check-project-names: no such file: $f" >&2; exit 2; }
  checked=$((checked + 1))
  report "$f" < <(grep -noIiE -- "$pattern" "$f")
done
finish
