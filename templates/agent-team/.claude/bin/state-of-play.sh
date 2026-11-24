#!/usr/bin/env bash
# Prints the state of play for Elon at session start, so Elon does not spend turns on git and gh.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
echo
echo "## State of play (from .claude/bin/state-of-play.sh)"
# Fast-forward clean main checkouts and name tools below the fleet floor before reading the branch
[ -f "$HOME/dotfiles/script/session-sync.sh" ] && bash "$HOME/dotfiles/script/session-sync.sh" "$PWD"
b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ab=$(git rev-list --left-right --count "origin/$b...HEAD" 2>/dev/null | awk '{print "behind " $1 ", ahead " $2}')
echo "branch: $b | uncommitted files: $dirty | ${ab:-no upstream}"
echo "worktrees: $(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
if command -v gh >/dev/null 2>&1; then
  # Both gh calls run at once and are stopped after 3 s (macOS has no timeout), so a slow GitHub cannot hold the session.
  d=$(mktemp -d)
  ( exec gh issue list --label P0 --state open --limit 10 --json number,title --jq '.[] | "  #\(.number) \(.title)"' >"$d/issues" 2>/dev/null ) &
  issue_pid=$!
  ( exec gh pr list --state open --limit 15 --json number,title,headRefName,isDraft,reviewDecision --jq '.[] | "  #\(.number) \(.title) [\(.headRefName)]\(if .isDraft then " draft" else "" end) \(if (.reviewDecision // "") == "" then "no review" else .reviewDecision end)"' >"$d/prs" 2>/dev/null ) &
  pr_pid=$!
  ( sleep 3; kill "$issue_pid" "$pr_pid" 2>/dev/null ) >/dev/null 2>&1 &
  dog=$!
  wait "$issue_pid"; issue_rc=$?
  wait "$pr_pid"; pr_rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  show() { # <name> <exit code>: the output, or a note when gh failed or was stopped
    if [ "$2" -eq 0 ]; then cat "$d/$1"; elif [ "$2" -eq 143 ]; then echo "  (gh timed out)"; else echo "  (gh unavailable)"; fi
  }
  echo "open P0 issues:"
  show issues "$issue_rc"
  echo "open PRs:"
  show prs "$pr_rc"
  rm -rf "$d"
fi
exit 0
