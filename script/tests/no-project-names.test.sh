#!/usr/bin/env bash
# Guard: the public dotfiles repo must not name our projects, hosts or company ids.
# Project values live in untracked *.local.* overlays (see script/apply-local-overlay.py).
# Pattern list (not in repo): ${NO_PROJECT_NAMES_FILE:-$XDG_CONFIG_HOME/dotfiles/project-names.pattern}
# Scans tracked text files (binary files skipped). Run from anywhere.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root" || exit 1

pattern_file="${NO_PROJECT_NAMES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/project-names.pattern}"

if [ ! -f "$pattern_file" ]; then
  echo "skip: project-names pattern file missing ($pattern_file)"
  exit 0
fi

pattern=$(tr -d '\n\r' <"$pattern_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ -z "$pattern" ]; then
  echo "skip: project-names pattern file empty ($pattern_file)"
  exit 0
fi

hits=$(git grep -IiE "$pattern" -- . \
  ':!templates/agent-team/.claude/hooks/' \
  || true)
if [ -n "$hits" ]; then
  echo "FAIL: project names found in tracked files:"; echo "$hits" | cut -c1-160 | head -30
  exit 1
fi
echo "ok: no project names in tracked text files"
