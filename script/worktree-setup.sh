#!/usr/bin/env bash
# Orca repo setup hook for a new worker worktree: bring it to a fresh origin/main, then install
# dependencies when node_modules is missing. Runs in the new worktree only; the main checkout
# (clean, stale or dirty) is never touched.
# Wire it as the repo's setup hook, and start workers with `--base-branch origin/main --setup run`.
set -euo pipefail

git fetch --quiet origin
# Fast-forward only: a worktree that already has its own commits is left as it is.
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  git merge --quiet --ff-only origin/main
fi
if [ -f package.json ] && [ ! -d node_modules ]; then
  bun install
fi
