#!/usr/bin/env bash
# Orca repo setup hook for a new worker worktree: bring it to a fresh origin/main, then install
# dependencies where a package.json has no node_modules beside it. Runs in the new worktree only; the main checkout
# (clean, stale or dirty) is never touched.
# Wire it as the repo's setup hook, and start workers with `--base-branch origin/main --setup run`.
set -euo pipefail
# --git-only: fetch and fast-forward only, skip the install loop (briefs with `Setup: none`).
git_only=0
case "${1:-}" in
  '') ;;
  --git-only) git_only=1 ;;
  *) echo "Usage: worktree-setup.sh [--git-only]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: worktree-setup.sh [--git-only]" >&2; exit 2; }

git fetch --quiet origin
# Fast-forward only: a worktree that already has its own commits is left as it is.
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  git merge --quiet --ff-only origin/main
fi
# Commit-time guard against private names (dotfiles only; other repos have no .githooks/commit-msg).
[ -x .githooks/commit-msg ] && git config core.hooksPath .githooks
[ "$git_only" = 1 ] && exit 0
# The project may sit in the root or one folder down (for example web/).
for pkg in package.json */package.json; do
  [ -f "$pkg" ] || continue
  dir=$(dirname "$pkg")
  if [ ! -d "$dir/node_modules" ]; then
    (cd "$dir" && bun install)
  fi
done
