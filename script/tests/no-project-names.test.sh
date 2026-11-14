#!/usr/bin/env bash
# Guard: the public dotfiles repo must not name our projects, hosts or company ids.
# Project values live in untracked *.local.* overlays (see script/apply-local-overlay.py).
# Pattern list (not in repo): ${NO_PROJECT_NAMES_FILE:-$XDG_CONFIG_HOME/dotfiles/project-names.pattern}
# Format: one extended-regex fragment per line; blank lines are ignored; lines are OR'd with |.
# Scans tracked text files (binary files skipped). Run from anywhere.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root" || exit 1

pattern_file="${NO_PROJECT_NAMES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/project-names.pattern}"

if [ ! -f "$pattern_file" ]; then
  echo "SKIPPED (no pattern file; CI runs this)"
  exit 0
fi

pattern=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] && continue
  if [ -z "$pattern" ]; then
    pattern="$line"
  else
    pattern="$pattern|$line"
  fi
done <"$pattern_file"
if [ -z "$pattern" ]; then
  echo "skip: project-names pattern file empty ($pattern_file)"
  exit 0
fi

set +e
hits=$(git grep -lIiE "$pattern" -- . ':!templates/agent-team/.claude/hooks/' 2>/dev/null)
grep_ec=$?
set -e
if [ "$grep_ec" -gt 1 ]; then
  echo "FAIL: invalid project-names pattern ($pattern_file)"
  exit 1
fi
if [ "$grep_ec" -eq 0 ] && [ -n "$hits" ]; then
  # File names only: head-checks posts failed output to a public PR comment.
  echo "FAIL: project names found in tracked files:"; echo "$hits" | head -30
  exit 1
fi
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  bad_commits=""
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if git show -s --format='%B' "$sha" | grep -qiE "$pattern"; then
      bad_commits="${bad_commits:+$bad_commits$'\n'}${sha:0:12}"
    fi
  done < <(git rev-list origin/main..HEAD)
  if [ -n "$bad_commits" ]; then
    echo "FAIL: project names found in commit messages:"; echo "$bad_commits" | head -30
    exit 1
  fi
fi
echo "ok: no project names in tracked text files"
