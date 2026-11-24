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

# One worker-budget and one guard-bash registration per event and tool (#1797).
dup="$tmp/dup"
mkdir -p "$dup"
wb_abs="python3 $root/templates/agent-team/.claude/hooks/worker-budget.py"
wb_home='python3 "$HOME/.claude/hooks/worker-budget.py"'
gb='python3 "$HOME/.claude/hooks/guard-bash.py"'
jq -n --arg a "$wb_abs" --arg h "$wb_home" --arg g "$gb" '{hooks: {
  PreToolUse: [
    {matcher: "Bash", hooks: [{type: "command", command: $g}]},
    {matcher: "Write|Edit|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $g}]},
    {matcher: "Read|Write|Edit|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $g}]},
    {matcher: ".*", hooks: [{type: "command", command: $a}]},
    {matcher: ".*", hooks: [{type: "command", command: $h}]}],
  PostToolUse: [
    {matcher: ".*", hooks: [{type: "command", command: $a}]},
    {matcher: ".*", hooks: [{type: "command", command: $h}]}]}}' >"$dup/settings.json"
render() { DOTFILES="$root" bash "$root/script/setup-agent-hooks.sh" --render "$1"; }
render "$dup/settings.json" >"$dup/out.json" || bad 'render failed on duplicate hooks'
for event in PreToolUse PostToolUse; do
  n=$(jq --arg e "$event" '[.hooks[$e][]?.hooks[]? | select(.command | contains("worker-budget.py"))] | length' "$dup/out.json")
  [ "$n" -eq 1 ] && ok "$event keeps one worker-budget" || bad "$event has $n worker-budget registrations"
  jq -e --arg e "$event" '[.hooks[$e][]?.hooks[]? | select(.command | contains("worker-budget.py")) | .command] == ["python3 \"$HOME/.claude/hooks/worker-budget.py\""]' "$dup/out.json" >/dev/null \
    && ok "$event keeps the HOME worker-budget form" || bad "$event did not keep the HOME worker-budget form"
done
for tool in Bash Read Write Edit MultiEdit NotebookEdit; do
  n=$(jq --arg t "$tool" '[.hooks.PreToolUse[] | select(.matcher as $m | $t | test("^(" + $m + ")$")) | .hooks[] | select(.command | contains("guard-bash.py"))] | length' "$dup/out.json")
  [ "$n" -eq 1 ] && ok "$tool has one guard-bash registration" || bad "$tool has $n guard-bash registrations"
done
jq '.' "$dup/out.json" >"$dup/second-in.json"
render "$dup/second-in.json" >"$dup/second-out.json" || bad 'second render failed'
cmp -s "$dup/out.json" "$dup/second-out.json" && ok 'second render of deduped hooks changes nothing' || bad 'second render of deduped hooks changed settings'

# A linked worktree must not write its own hook paths into the real home (#1536).
MAIN="$tmp/main" WT="$tmp/wt" REAL="$tmp/real-home"
mkdir -p "$MAIN/script/lib" "$REAL/.claude"
cp "$root/script/setup-agent-hooks.sh" "$MAIN/script/"
cp "$root/script/lib/dotfiles-source.sh" "$MAIN/script/lib/"
git -C "$MAIN" init -q
git -C "$MAIN" add -A
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -qm seed
git -C "$MAIN" worktree add -q "$WT" -b worker
echo '{"model": "sonnet"}' >"$REAL/.claude/settings.json"
cp "$REAL/.claude/settings.json" "$tmp/real-before.json"
mainreal=$(cd "$MAIN" && pwd -P) wtreal=$(cd "$WT" && pwd -P) realhome=$(cd "$REAL" && pwd -P)
rc=0
out=$(env -u DOTFILES HOME="$realhome" DOTFILES_REAL_HOME="$realhome" bash "$WT/script/setup-agent-hooks.sh" 2>&1) || rc=$?
[ "$rc" -eq 1 ] && ok 'worktree with real home exits 1' || bad "worktree exit was $rc"
case "$out" in
  *"setup-agent-hooks: refusing to wire $realhome from $wtreal; run it from the main checkout $mainreal"*) ok 'worktree refusal names the main checkout' ;;
  *) bad "worktree refusal message: $out" ;;
esac
cmp -s "$REAL/.claude/settings.json" "$tmp/real-before.json" && ok 'worktree refusal leaves settings unchanged' || bad 'worktree refusal changed settings'

echo "setup-agent-hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
