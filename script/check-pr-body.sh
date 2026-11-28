#!/usr/bin/env bash
# The pr-body-gate check, run locally before a PR opens (#1676), so a builder fixes the body
# before review instead of at review time. Same rules as fleet-watch and ship.sh (script/pr-body-gate.py).
# Usage: check-pr-body.sh [--issue <n>] [--title "<PR title>"] [--repo <owner/name>] [--diff <file>] [--asked yes|no] [--repo-dir <dir>] <body file>
# Exit 0: the body may open. Exit 1: refused; the message names the missing section. Exit 2: usage.
# Required: ## Self-check with a command and a line of its output, a Builder: line, the issue closing
# line (Closes #<n> when --issue is given), and no unchecked Acceptance box. With --title it also runs
# check-pr-body-issues.sh (#1688): each issue number in the title must be closed or referred to in the body.
# --repo-dir <dir> names the target project checkout (default the current directory) for the diff and the Perf: rule.
# Readers: rule (#1882): --diff <file>, else the target checkout's diff from its merge base with origin/HEAD
# (or origin/main) to HEAD; outside a checkout the rule is off. --asked yes|no is passed on (no means the
# Decisions: rule applies).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: check-pr-body.sh [--issue <n>] [--title <PR title>] [--repo <owner/name>] [--diff <file>] [--asked yes|no] [--repo-dir <dir>] <body file>" >&2; exit 2; }

issue="" file="" title="" repo="" diff="" asked="" repo_dir=.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --issue) [ $# -ge 2 ] || usage; issue=$2; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --diff) [ $# -ge 2 ] && [ -f "$2" ] || usage; diff=$2; shift 2 ;;
    --asked) [ $# -ge 2 ] || usage; asked=$2; shift 2 ;;
    --repo-dir) [ $# -ge 2 ] && [ -d "$2" ] || usage; repo_dir=$2; shift 2 ;;
    *) [ -z "$file" ] || usage; file=$1; shift ;;
  esac
done
[ -n "$file" ] && [ -f "$file" ] || usage
issue=${issue#\#}
case "$issue" in *[!0-9]*) usage ;; esac
case "$asked" in ""|yes|no) ;; *) usage ;; esac

if [ -z "$diff" ]; then
  base=$(git -C "$repo_dir" merge-base HEAD origin/HEAD 2>/dev/null || git -C "$repo_dir" merge-base HEAD origin/main 2>/dev/null) || base=""
  if [ -n "$base" ]; then
    diff=$(mktemp)
    trap 'rm -f "$diff"' EXIT
    git -C "$repo_dir" diff "$base" HEAD >"$diff"
  fi
fi

if reason=$(python3 "$here/pr-body-gate.py" ${issue:+--issue "$issue"} ${diff:+--diff "$diff"} ${asked:+--asked "$asked"} --repo-dir "$repo_dir" <"$file"); then
  if [ -n "$title" ]; then
    bash "$here/check-pr-body-issues.sh" --title "$title" --body-file "$file" ${repo:+--repo "$repo"} || {
      echo "check-pr-body: refused: the body does not match the title's issues" >&2
      exit 1
    }
  fi
  exit 0
fi
echo "check-pr-body: refused: $reason" >&2
echo "Fix the PR body, then open the PR. Sections: closing line, Builder: line, ## Self-check (command and output tail)." >&2
exit 1
