#!/usr/bin/env bash
# Orca repo setup hook for a new worker worktree: bring it to a fresh origin/main, then install
# dependencies where a package.json has no node_modules beside it. Runs in the new worktree only; the main checkout
# (clean, stale or dirty) is never touched.
# Wire it as the repo's setup hook, and start workers with `--base-branch origin/main --setup run`.
set -euo pipefail

git fetch --quiet origin
# Fast-forward only: a worktree that already has its own commits is left as it is.
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  git merge --quiet --ff-only origin/main
fi
# The project may sit in the root or one folder down (for example web/).
for pkg in package.json */package.json; do
  [ -f "$pkg" ] || continue
  dir=$(dirname "$pkg")
  if [ ! -d "$dir/node_modules" ]; then
    (cd "$dir" && bun install)
  fi
done
