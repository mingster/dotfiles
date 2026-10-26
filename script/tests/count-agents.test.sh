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
    /Users/u/.codex/packages/app-server-daemon/releases/0.164.0-x86_64-apple-darwin/bin/codex app-server daemon pid-update-loop
    /Users/u/.codex/packages/app-server-daemon/releases/0.164.0-x86_64-apple-darwin/bin/codex app-server --listen unix:// --analytics-default-enabled --managed-daemon
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex --no-daemon -c ...
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex-code-mode-host
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex --no-daemon -c ...
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex-code-mode-host
    claude --dangerously-skip-permissions --model claude-sonnet-5-5 --effort medium
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex --no-daemon -c ...
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex-code-mode-host
    /Users/u/.local/bin/cursor-agent --use-system-ca ...
    /Users/u/.codex/packages/app-server-daemon/releases/0.164.0-x86_64-apple-darwin/bin/codex app-server daemon
    /Users/u/.node_modules/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex-code-mode-host
    /Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent
    grep -c claude
PS
)
assert_count 'busy process fixture' 5 "$fixture"
assert_count 'empty input' 0 ''
assert_count 'Claude CLI' 1 'claude --dangerously-skip-permissions'
assert_count 'bare Codex executable' 1 'codex --no-daemon -c ...'
assert_count 'Codex without arguments' 1 'codex'
assert_count 'Codex app-server daemons' 0 $'codex app-server daemon\n/usr/bin/codex app-server --listen unix://'
assert_count 'Codex children and similar names' 0 $'codex-code-mode-host\n/usr/bin/codex-code-mode-host\n/usr/bin/not-codex --no-daemon'
assert_count 'Cursor CLI' 1 '/Users/u/.local/bin/cursor-agent --use-system-ca'
assert_count 'Cursor IDE helper' 0 '/Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent'
assert_count 'other executables and embedded command text' 0 $'grep -c claude\n/bin/sh -c codex --no-daemon\n/usr/bin/cursor-agent\nclaude-helper --dangerously-skip-permissions'
assert_count 'leading whitespace' 3 $'  claude --model example\n\t/usr/bin/codex --no-daemon\n   /Users/u/.local/bin/cursor-agent'
assert_count 'app-server in session configuration' 1 'codex --no-daemon -c app-server'

printf 'PASS: %s tests\n' "$tests"
