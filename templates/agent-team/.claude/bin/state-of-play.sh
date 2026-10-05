#!/usr/bin/env bash
# Prints the state of play for the Tech Lead at session start, so the lead does not spend turns on git and gh.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
echo
echo "## State of play (from .claude/bin/state-of-play.sh)"
b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ab=$(git rev-list --left-right --count "origin/$b...HEAD" 2>/dev/null | awk '{print "behind " $1 ", ahead " $2}')
echo "branch: $b | uncommitted files: $dirty | ${ab:-no upstream}"
echo "worktrees: $(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
if command -v gh >/dev/null 2>&1; then
  echo "open hotfix issues:"
  gh issue list --label hotfix --state open --limit 10 --json number,title --jq '.[] | "  #\(.number) \(.title)"' 2>/dev/null || echo "  (gh unavailable)"
  echo "open PRs:"
  gh pr list --state open --limit 15 --json number,title,headRefName,isDraft,reviewDecision --jq '.[] | "  #\(.number) \(.title) [\(.headRefName)]\(if .isDraft then " draft" else "" end) \(if (.reviewDecision // "") == "" then "no review" else .reviewDecision end)"' 2>/dev/null || echo "  (gh unavailable)"
fi
exit 0
