# Shared setup for the agent-team-cases-*.test.sh parts (split from agent-team.test.sh, #1325).
# Source it from a part. It sets tmp, DOTFILES (a symlinked copy of the repo), pass/fail, check, SCRIPT,
# here (the script dir) and real_dotfiles, and removes tmp on exit. A part ends with agent_team_cases_done.
# shellcheck shell=bash
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
real_dotfiles=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DOTFILES="$tmp/dotfiles"
mkdir "$DOTFILES"
for entry in "$real_dotfiles"/* "$real_dotfiles"/.[!.]*; do
  [ "$(basename "$entry")" = .git ] || ln -s "$entry" "$DOTFILES/"
done

export HOME="$tmp/home"
mkdir -p "$HOME"

pass=0
fail=0
check() {
  if [ "$2" = ok ]; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
  fi
}

SCRIPT="$here/agent-team.sh"

agent_team_cases_done() {
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
