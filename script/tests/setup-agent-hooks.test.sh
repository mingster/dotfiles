#!/usr/bin/env bash
# Tests for script/setup-agent-hooks.sh: the tracked Claude settings reach a kept settings.json
# as fleet defaults, and the machine's own env and secrets survive (#1395).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"
tracked="$root/.agents/claude/settings.json"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

jq -e 'type == "object"' "$tracked" >/dev/null && ok 'tracked settings parse' || bad 'tracked settings do not parse'
for key in env mcpServers feedbackDrafts; do
  if jq -e --arg k "$key" 'has($k) and (.[$k] | length > 0)' "$tracked" >/dev/null; then
    bad "tracked settings carry $key values"
  else
    ok "tracked settings carry no $key values"
  fi
done
if grep -q '/Users/' "$tracked"; then bad 'tracked settings carry a host path'; else ok 'tracked settings carry no host path'; fi

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
settings="$HOME/.claude/settings.json"
cat >"$settings" <<'JSON'
{
  "env": {"FIXTURE_TOKEN": "host-only-value"},
  "mcpServers": {"fixture": {"command": "x", "headers": {"Authorization": "host-only-header"}}},
  "feedbackDrafts": [{"id": "host-draft"}],
  "model": "sonnet",
  "effortLevel": "low",
  "skillOverrides": {"fixture-skill": "on"},
  "permissions": {"allow": ["Bash(host-only:*)"], "defaultMode": "bypassPermissions"},
  "hostOnlyKey": 7
}
JSON

run_setup() { DOTFILES="$root" bash "$root/script/setup-agent-hooks.sh" >"$tmp/out" 2>&1; }
run_setup || { bad 'setup failed'; cat "$tmp/out"; }

check() {
  local label=$1 filter=$2
  if jq -e "$filter" "$settings" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
check 'host env survives' '.env.FIXTURE_TOKEN == "host-only-value"'
check 'host mcpServers headers survive' '.mcpServers.fixture.headers.Authorization == "host-only-header"'
check 'host feedbackDrafts survive' '.feedbackDrafts[0].id == "host-draft"'
check 'host-only key survives' '.hostOnlyKey == 7'
tracked_model=$(jq -r .model "$tracked")
tracked_effort=$(jq -r .effortLevel "$tracked")
check 'tracked model wins' ".model == \"$tracked_model\""
check 'tracked effortLevel wins' ".effortLevel == \"$tracked_effort\""
for key in outputStyle advisorModel statusLine autoMode enabledPlugins; do
  if jq -e --arg k "$key" 'has($k)' "$tracked" >/dev/null; then
    want=$(jq -cS --arg k "$key" '.[$k]' "$tracked")
    got=$(jq -cS --arg k "$key" '.[$k]' "$settings")
    [ "$want" = "$got" ] && ok "tracked $key reaches the host" || bad "tracked $key did not reach the host"
  fi
done
check 'host skillOverrides key wins' '.skillOverrides["fixture-skill"] == "on"'
n=$(jq '.skillOverrides | length' "$tracked")
check 'tracked skillOverrides added' "(.skillOverrides | length) == ($n + 1)"
check 'host permission kept' '.permissions.allow | index("Bash(host-only:*)")'
first=$(jq -r '.permissions.deny[0] // empty' "$tracked")
[ -z "$first" ] || check 'tracked deny rule added' ".permissions.deny | index(\"$first\")"
check 'defaultMode left to the team template' '.permissions.defaultMode == "bypassPermissions"'
check 'tracked hooks not copied into the host' '[.hooks[]?[]?.hooks[]?.command | select(test("ORCA_AGENT_HOOK"))] | length == 0'

cp "$settings" "$tmp/first.json"
run_setup || bad 'second setup failed'
cmp -s "$settings" "$tmp/first.json" && ok 'second run changes nothing' || bad 'second run changed settings'

echo "setup-agent-hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
