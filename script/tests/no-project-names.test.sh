#!/usr/bin/env bash
# Guard: the public dotfiles repo must not name our projects, hosts or company ids.
# A thin caller of script/check-project-names.sh (all matching lives there). Project values live in
# untracked *.local.* overlays (see script/apply-local-overlay.py). Pattern file: see the checker.
# Scans tracked text files and, when origin/main exists, the commit messages on origin/main..HEAD.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root" || exit 1

args=(--allow-missing --tracked)
git rev-parse --verify -q origin/main >/dev/null 2>&1 && args+=(--commits origin/main..HEAD)
err=$(mktemp)
trap 'rm -f "$err"' EXIT
out=$(bash "$root/script/check-project-names.sh" "${args[@]}" 2>"$err")
rc=$?
if [ "$rc" -ne 0 ]; then
  # Source and line only: head-checks posts failed output to a public PR comment.
  echo "FAIL: project names found:"; head -30 "$err"
  exit 1
fi
echo "$out"
case "$out" in *" checked, "*) echo "ok: no project names in tracked text files" ;; esac
