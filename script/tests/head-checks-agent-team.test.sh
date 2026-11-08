#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# head-checks runs "agent-team.sh check" whenever the base or the head carries project team files,
# and fails closed when that check is missing or errors. Scratch HOME only.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
runner=$(cd "$here/.." && pwd)/head-checks.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

pass=0
fail=0
check() {
  if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

git_in() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid "$@"; }

stub_dotfiles() {
  local dir=$1 rc=$2
  mkdir -p "$dir/script"
  printf '#!/usr/bin/env bash\necho called >> "%s/called"\nexit %s\n' "$tmp" "$rc" > "$dir/script/agent-team.sh"
}

# new_repo <name> <base_has_team_files 0|1>; leaves $repo and $base set.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo/.agents" "$repo/.claude/hooks"
  git -C "$repo" init -q
  printf 'true\n' > "$repo/.agents/head-checks.conf"
  if [ "$2" -eq 1 ]; then
    printf '{}\n' > "$repo/.claude/settings.project.json"
    printf '{}\n' > "$repo/.claude/hooks/guard-config.json"
  fi
  printf 'x\n' > "$repo/code.txt"
  git_in add -A >/dev/null
  git_in commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
}

run_hc() {
  rm -f "$tmp/called"
  DOTFILES_DIR="$1" HEAD_CHECKS_WAIT_SECONDS=0 bash "$runner" --repo "$repo" --ref HEAD --base "$base" >"$tmp/out" 2>&1
}

stub_dotfiles "$tmp/df-ok" 0
stub_dotfiles "$tmp/df-bad" 1
mkdir -p "$tmp/df-missing"

# Deleting both team files in the PR must not skip the gate.
new_repo del 1
git_in rm -q .claude/settings.project.json .claude/hooks/guard-config.json
git_in commit -qm "delete team files"
run_hc "$tmp/df-ok"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/called" ]; then
  check "PR deleting both project team files still runs agent-team check" ok
else
  check "PR deleting both project team files still runs agent-team check" bad
fi
run_hc "$tmp/df-bad"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "PR deleting both project team files fails when the check fails" ok
else
  check "PR deleting both project team files fails when the check fails" bad
fi

# Control: no team files anywhere, no check.
new_repo none 0
printf "y\n" >> "$repo/code.txt"
git_in commit -qam change
run_hc "$tmp/df-bad"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$tmp/called" ]; then
  check "repo without team files skips agent-team check" ok
else
  check "repo without team files skips agent-team check" bad
fi

# Team files present: erroring check fails, missing script fails closed.
new_repo present 1
printf 'y\n' >> "$repo/code.txt"
git_in commit -qam change
run_hc "$tmp/df-bad"; rc=$?
if [ "$rc" -ne 0 ] && [ -f "$tmp/called" ]; then
  check "erroring agent-team check fails head-checks" ok
else
  check "erroring agent-team check fails head-checks" bad
fi
run_hc "$tmp/df-missing"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "missing agent-team.sh fails head-checks closed" ok
else
  check "missing agent-team.sh fails head-checks closed" bad
fi
run_hc "$tmp/df-ok"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/called" ]; then
  check "passing agent-team check lets head-checks pass" ok
else
  check "passing agent-team check lets head-checks pass" bad
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
