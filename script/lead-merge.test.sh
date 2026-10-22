#!/usr/bin/env bash
# Test the real extraction helper without running merge commands or calling GitHub.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
eval "$(sed -n '/^issue_from_branch() {$/,/^}$/p' "$here/lead-merge.sh")"

check() {
  local actual
  actual=$(issue_from_branch "$1")
  [ "$actual" = "$2" ] || { echo "FAIL: $1: expected '$2', got '$actual'" >&2; exit 1; }
  echo "ok $1 -> '$actual'"
}

check mingster/fullstack-dev-s4a-4105 4105
check mingster/fullstack-dev-c4145 4145
check mingster/dev-riben-q13-audit ''
check mingster/d4146b-hooks-prompt 4146
check mingster/4105-fix-4146 4146
check mingster/4105-fix-13 4105
check mingster/no-digits ''
echo 'PASS: 7 branch issue extraction cases'
