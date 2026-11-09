#!/usr/bin/env bash
# Guard (#844): no test exports a git identity variable, so the test identity cannot leak into real commits.
# Tests get their identity from lib/git-identity.sh (a gitconfig file in the test's temp dir) or `git -C <tmp> config`.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$root" || exit 1
hits=$(git grep -nE '^[[:space:]]*export[^#]*GIT_(AUTHOR|COMMITTER)_(EMAIL|NAME)' -- 'script/*.test.sh' 'script/tests/*.sh' 'script/tests/lib/*.sh' 'ide/*.test.sh' || true)
if [ -n "$hits" ]; then
  echo "FAIL tests export a git identity variable:"; echo "$hits"; exit 1
fi
echo "ok   no test exports GIT_AUTHOR_* or GIT_COMMITTER_*"
