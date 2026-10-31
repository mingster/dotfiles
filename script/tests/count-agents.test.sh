#!/usr/bin/env bash
# Count sessions from process fixtures without depending on live agents.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tests=0

assert_count() {
  local label=$1 expected=$2 input=$3 actual
  actual=$(printf '%s' "$input" | "$root/script/count-agents.sh" --stdin)
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  tests=$((tests + 1))
}

fixture=$(cat <<'PS'
    claude --dangerously-skip-permissions --model claude-sonnet-5-5 --effort medium
    /Users/u/.local/bin/cursor-agent --use-system-ca ...
    /Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent
    grep -c claude
PS
)
assert_count 'busy process fixture' 2 "$fixture"
assert_count 'empty input' 0 ''
assert_count 'Claude CLI' 1 'claude --dangerously-skip-permissions'
assert_count 'Cursor CLI' 1 '/Users/u/.local/bin/cursor-agent --use-system-ca'
assert_count 'Cursor IDE helper' 0 '/Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent'
assert_count 'other executables and embedded command text' 0 $'grep -c claude\n/bin/sh -c claude --no-daemon\n/usr/bin/cursor-agent\nclaude-helper --dangerously-skip-permissions'
assert_count 'leading whitespace' 2 $'  claude --model example\n\t/usr/bin/other --no-daemon\n   /Users/u/.local/bin/cursor-agent'
assert_count 'app-server in session configuration' 1 'claude --no-daemon -c app-server'

printf 'PASS: %s tests\n' "$tests"
