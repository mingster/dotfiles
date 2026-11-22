#!/usr/bin/env bash
# Pre-trust worker worktrees for Grok so a new worktree does not stop at the folder-trust question
# ("Agent startup blocked: agent-trust-workspace"). Grok keeps the answer in ~/.grok/trusted_folders.toml
# (GROK_HOME overrides ~/.grok), one [folders."<path>"] table per folder.
# Usage: grok-trust.sh <worktree path>...   Idempotent: a folder already listed is left alone.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: grok-trust.sh <worktree path>..." >&2; exit 2; }
home=${GROK_HOME:-$HOME/.grok}
store=$home/trusted_folders.toml
mkdir -p "$home"
touch "$store"
chmod 600 "$store" 2>/dev/null || true

for dir in "$@"; do
  [ -d "$dir" ] || { echo "grok-trust: not a directory: $dir" >&2; exit 1; }
  path=$(cd "$dir" && pwd -P)
  esc=${path//\\/\\\\}
  esc=${esc//\"/\\\"}
  header="[folders.\"$esc\"]"
  if grep -qxF "$header" "$store"; then
    echo "grok-trust: already trusted $path"
    continue
  fi
  printf '\n%s\ntrusted = true\ndecided_at = %s\n' "$header" "$(date +%s)" >>"$store"
  echo "grok-trust: trusted $path"
done
