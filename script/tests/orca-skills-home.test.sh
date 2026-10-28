#!/usr/bin/env bash
# Optional network integration proof; needs Orca, npx and GitHub access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then
    for log in "$TEST_ROOT"/install-*.log "$TEST_ROOT"/orca-*.log; do
      [ ! -f "$log" ] || { echo "--- $log" >&2; cat "$log" >&2; }
    done
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
# Pin first, or asdf has no version to resolve with.
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
# Resolve asdf's executable before HOME changes; its shim otherwise loses installs.
if command -v asdf >/dev/null 2>&1; then
  npx_path=$(asdf which npx 2>&1) || { echo "FAIL: asdf cannot resolve npx: $npx_path" >&2; exit 1; }
  export PATH="$(dirname "$npx_path"):$PATH"
fi
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export npm_config_cache="$HOME/.npm"
mkdir -p "$HOME"
cd "$TEST_ROOT"
for pass in 1 2; do
  DOTFILES_SKIP_SYSTEM_SETUP=1 DOTFILES_SKIP_SETUP_CHECK=1 bash "$ROOT/install.sh" >"$TEST_ROOT/install-$pass.log" 2>&1
done
orca skills install --skill orchestration --agent universal,claude-code >"$TEST_ROOT/orca-install.log" 2>&1
orca skills update --skill orchestration >"$TEST_ROOT/orca-update.log" 2>&1
if grep -i 'Skipped' "$TEST_ROOT/orca-install.log" "$TEST_ROOT/orca-update.log"; then
  exit 1
fi
[ -f "$HOME/.agents/skills/orchestration/SKILL.md" ]
[ ! -L "$HOME/.agents/skills/orchestration" ]
[ -f "$HOME/.claude/skills/orchestration/SKILL.md" ]
[ "$(cd "$HOME/.agents/skills/orchestration" && pwd -P)" = "$(cd "$HOME" && pwd -P)/.agents/skills/orchestration" ]
echo 'PASS: official Orca orchestration install and update in temp HOME, no Skipped entry'
