#!/usr/bin/env bash
# Pre-trust worker worktrees for Grok so a new worktree does not stop at the folder-trust question
# ("Agent startup blocked: agent-trust-workspace"). Grok keeps the answer in ~/.grok/trusted_folders.toml
# (GROK_HOME overrides ~/.grok), one [folders."<path>"] table per folder.
# Usage: grok-trust.sh <worktree path>...   Idempotent: a folder already listed is left alone.
# A linked git worktree also trusts its main checkout, since Grok asks trust on the repo root.
# -h and --help print this text.
set -euo pipefail
print_usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
for a in ${1+"$@"}; do case "$a" in -h|--help) print_usage; exit 0 ;; --) break ;; esac; done

[ $# -ge 1 ] || { echo "usage: grok-trust.sh <worktree path>..." >&2; exit 2; }
home=${GROK_HOME:-$HOME/.grok}
store=$home/trusted_folders.toml
mkdir -p "$home"
touch "$store"
chmod 600 "$store" 2>/dev/null || true

trust() {
  local path=$1 esc header
  esc=${path//\\/\\\\}
  esc=${esc//\"/\\\"}
  header="[folders.\"$esc\"]"
  if grep -qxF "$header" "$store"; then
    echo "grok-trust: already trusted $path"
    return
  fi
  printf '\n%s\ntrusted = true\ndecided_at = %s\n' "$header" "$(date +%s)" >>"$store"
  echo "grok-trust: trusted $path"
}

for dir in "$@"; do
  [ -d "$dir" ] || { echo "grok-trust: not a directory: $dir" >&2; exit 1; }
  path=$(cd "$dir" && pwd -P)
  trust "$path"
  # Grok resolves trust to the main checkout for a linked worktree (#1908).
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || continue
  [ "$(cd "$top" && pwd -P)" = "$path" ] || continue
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir) || continue
  main=$(cd "${common%/*}" && pwd -P)
  [ "$main" = "$path" ] || trust "$main"
done
