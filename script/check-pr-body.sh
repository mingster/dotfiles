#!/usr/bin/env bash
# The pr-body-gate check, run locally before a PR opens (#1676), so a builder fixes the body
# before review instead of at review time. Same rules as fleet-watch and ship.sh (script/pr-body-gate.py).
# Usage: check-pr-body.sh [--issue <n>] [--title "<PR title>"] <body file>
# Exit 0: the body may open. Exit 1: refused; the message names the missing section. Exit 2: usage.
# Required: ## Self-check with a command and a line of its output, a Builder: line, the issue closing
# line (Closes #<n> when --issue is given), and no unchecked Acceptance box. With --title it also runs
# check-pr-body-issues.sh (#1688): each issue number in the title must be closed or referred to in the body.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: check-pr-body.sh [--issue <n>] [--title <PR title>] <body file>" >&2; exit 2; }

issue="" file="" title=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --issue) [ $# -ge 2 ] || usage; issue=$2; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
    *) [ -z "$file" ] || usage; file=$1; shift ;;
  esac
done
[ -n "$file" ] && [ -f "$file" ] || usage
issue=${issue#\#}
case "$issue" in *[!0-9]*) usage ;; esac

if reason=$(python3 "$here/pr-body-gate.py" ${issue:+--issue "$issue"} <"$file"); then
  if [ -n "$title" ]; then
    bash "$here/check-pr-body-issues.sh" --title "$title" --body-file "$file" || {
      echo "check-pr-body: refused: the body does not match the title's issues" >&2
      exit 1
    }
  fi
  exit 0
fi
echo "check-pr-body: refused: $reason" >&2
echo "Fix the PR body, then open the PR. Sections: closing line, Builder: line, ## Self-check (command and output tail)." >&2
exit 1
