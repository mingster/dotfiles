#!/usr/bin/env bash
# Fail early on project or host names in text bound for the public dotfiles repo.
# Pattern file (not in repo): ${NO_PROJECT_NAMES_FILE:-$XDG_CONFIG_HOME/dotfiles/project-names.pattern}
# One extended-regex fragment per line; blank lines ignored; lines are OR'd. Same file as
# script/tests/no-project-names.test.sh. No pattern file: one warning line, exit 0.
# Usage: name-lint.sh message <file> | text <label> (stdin) | branch [<base>] (default origin/main)
# NAME_LINT_QUIET=1 hides the missing pattern file warning.
# Exit 1 on a match, naming the word that matched (the word only, never the pattern file).
set -uo pipefail

pattern_file="${NO_PROJECT_NAMES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/project-names.pattern}"
mode=${1:-}
[ -n "$mode" ] || { echo "Usage: $0 message <file> | text <label> | branch [<base>]" >&2; exit 2; }

if [ ! -f "$pattern_file" ]; then
  [ "${NAME_LINT_QUIET:-}" = 1 ] || echo "name-lint: no pattern file, names not checked (CI will): $pattern_file" >&2
  exit 0
fi
pattern=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  pattern="${pattern:+$pattern|}$line"
done <"$pattern_file"
[ -n "$pattern" ] || exit 0

reword="Reword it: say \"the project\" or \"the host\" instead of the name. This repo is public."
# <label> reads stdin; prints the first matching word and returns 1 on a match.
scan() {
  local word
  word=$(grep -oiE -m1 "$pattern" | head -1)
  if [ -n "$word" ]; then
    echo "name-lint: $1 contains the private name \"$word\". $reword" >&2
    return 1
  fi
}

case "$mode" in
  message) [ -f "${2:-}" ] || { echo "name-lint: message needs a file" >&2; exit 2; }
    scan "commit message" <"$2" ;;
  text) scan "${2:-text}" ;;
  branch)
    cd "$(dirname "$0")/.." || exit 1
    base=${2:-origin/main}
    git rev-parse --verify -q "$base" >/dev/null || exit 0
    rc=0
    while IFS= read -r sha; do
      git show -s --format=%B "$sha" | scan "commit ${sha:0:12}" || rc=1
    done < <(git rev-list "$base"..HEAD)
    changed=()
    while IFS= read -r f; do changed+=("$f"); done < <(git diff --diff-filter=d --name-only "$(git merge-base "$base" HEAD)" HEAD -- . ':!templates/agent-team/.claude/hooks/')
    if [ "${#changed[@]}" -gt 0 ]; then
      hits=$(git grep -lIiE "$pattern" HEAD -- "${changed[@]}" 2>/dev/null | sed 's/^HEAD://')
      if [ -n "$hits" ]; then
        echo "name-lint: private names in changed files (file names only):" >&2
        echo "$hits" | head -30 >&2
        rc=1
      fi
    fi
    exit "$rc" ;;
  *) echo "Usage: $0 message <file> | text <label> | branch [<base>]" >&2; exit 2 ;;
esac
