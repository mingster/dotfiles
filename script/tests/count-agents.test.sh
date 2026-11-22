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
    /Users/u/.grok/bin/grok chat
    grep -c claude
PS
)
assert_count 'busy process fixture' 2 "$fixture"
assert_count 'empty input' 0 ''
assert_count 'Claude CLI' 1 'claude --dangerously-skip-permissions'
assert_count 'Antigravity CLI' 1 'agy --dangerously-skip-permissions --model gemini-4-argon-medium'
assert_count 'Grok CLI bare' 1 'grok --yolo'
assert_count 'Grok CLI by path' 1 '/Users/u/.grok/bin/grok chat'
assert_count 'Grok mixed with Claude' 3 $'grok --yolo\n/Users/u/.grok/bin/grok chat\nclaude --x'
assert_count 'grep and grok-trust are not Grok sessions' 0 $'grep grok\ngrok-trust.sh --check\n/Users/u/dotfiles/script/grok-trust.sh x'
# Cursor was dropped from the count (#1527): the owner replaced it with Grok (#1264).
assert_count 'Cursor CLI is not counted' 0 '/Users/u/.local/bin/cursor-agent --use-system-ca'
assert_count 'other executables and embedded command text' 0 $'grep -c claude\n/bin/sh -c claude --no-daemon\n/usr/bin/cursor-agent\nclaude-helper --dangerously-skip-permissions'
assert_count 'leading whitespace' 2 $'  claude --model example\n\t/usr/bin/other --no-daemon\n   /Users/u/.grok/bin/grok chat'
assert_count 'app-server in session configuration' 1 'claude --no-daemon -c app-server'
# Deliberate refuse (#1074): Codex is not an agent session.
assert_count 'Codex CLI is not counted' 0 'codex --full-auto'

printf 'PASS: %s tests\n' "$tests"
