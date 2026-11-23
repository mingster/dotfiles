#!/usr/bin/env bash
# The pr-body-gate check, run locally before a PR opens (#1676), so a builder fixes the body
# before review instead of at review time. Same rules as fleet-watch and ship.sh (script/pr-body-gate.py).
# Usage: check-pr-body.sh [--issue <n>] <body file>
# Exit 0: the body may open. Exit 1: refused; the message names the missing section. Exit 2: usage.
# Required: ## Self-check with a command and a line of its output, a Builder: line, the issue closing
# line (Closes #<n> when --issue is given), and no unchecked Acceptance box.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: check-pr-body.sh [--issue <n>] <body file>" >&2; exit 2; }

issue="" file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --issue) [ $# -ge 2 ] || usage; issue=$2; shift 2 ;;
    *) [ -z "$file" ] || usage; file=$1; shift ;;
  esac
done
[ -n "$file" ] && [ -f "$file" ] || usage

if reason=$(python3 "$here/pr-body-gate.py" ${issue:+--issue "$issue"} <"$file"); then
  exit 0
fi
echo "check-pr-body: refused: $reason" >&2
echo "Fix the PR body, then open the PR. Sections: closing line, Builder: line, ## Self-check (command and output tail)." >&2
exit 1
