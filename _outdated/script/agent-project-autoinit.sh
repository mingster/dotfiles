#!/usr/bin/env bash
# agent-project-autoinit.sh: Claude Code SessionStart hook.
# In a git repo whose origin is github.com/mingster/* and that has no
# docs/agents/issue-tracker.md, seed the per repo agent config with
# init-agent-project.sh. Never fails the session, never commits.
# Test mode: AUTOINIT_NO_LABELS=1 skips the gh label step.
cat >/dev/null 2>&1 || true   # drain the hook JSON on stdin
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
url=$(git -C "$root" remote get-url origin 2>/dev/null) || exit 0
case "$url" in
  *github.com[:/]mingster/*) ;;
  *) exit 0 ;;
esac
[ -f "$root/docs/agents/issue-tracker.md" ] && exit 0
flags=""
[ -z "${AUTOINIT_NO_LABELS:-}" ] && flags="--labels"
# shellcheck disable=SC2086
to=""; command -v timeout >/dev/null 2>&1 && to="timeout 8"
if $to "$DOTFILES/script/init-agent-project.sh" $flags "$root" >/dev/null 2>&1 \
   || [ -f "$root/docs/agents/issue-tracker.md" ]; then
  echo "agent-project-autoinit: seeded docs/agents and the Agent skills block in $root (uncommitted)."
fi
exit 0
