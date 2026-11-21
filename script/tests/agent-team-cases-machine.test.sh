#!/usr/bin/env bash
# Retired scripts and machine mode.
# Part of the agent-team.sh tests, split from agent-team.test.sh so the parts run in parallel (#1325).
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# shellcheck source=script/tests/lib/agent-team-cases.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/agent-team-cases.sh"

# ── 1. Retired scripts moved to _outdated/ and wired callers ──────────────────
retired_ok=1
for n in adopt-agent-team init-agent-project sync-team-skills agent-project-autoinit; do
  [ ! -e "$real_dotfiles/script/$n.sh" ] && [ -f "$real_dotfiles/_outdated/script/$n.sh" ] || retired_ok=0
done
[ ! -e "$real_dotfiles/script/agent-project-autoinit.test.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/agent-project-autoinit.test.sh" ] || retired_ok=0
if [ "$retired_ok" -eq 1 ]; then
  check "retired adoption scripts and autoinit test moved to _outdated/" ok
else
  check "retired adoption scripts and autoinit test moved to _outdated/" bad
fi

if grep -q 'script/agent-team.sh" check' "$real_dotfiles/script/head-checks.sh" \
  && grep -q 'script/agent-team.sh" check' "$real_dotfiles/script/ship.sh"; then
  check "head-checks.sh and ship.sh call script/agent-team.sh check" ok
else
  check "head-checks.sh and ship.sh call script/agent-team.sh check" bad
fi

if ! bash "$SCRIPT" reset "$tmp" >/dev/null 2>&1; then
  check "removed reset subcommand is rejected" ok
else
  check "removed reset subcommand is rejected" bad
fi

# ── 2. machine mode ───────────────────────────────────────────────────────────
export HOME="$tmp/home"
mkdir -p "$HOME"

out=$(bash "$SCRIPT" machine --dry-run 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$HOME/.claude" ] && grep -q "would link" <<<"$out"; then
  check "machine --dry-run prints planned links without mutating HOME" ok
else
  check "machine --dry-run prints planned links without mutating HOME" bad
fi


mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "env": {"CUSTOM_VAR": "1"},
  "permissions": {
    "defaultMode": "default",
    "allow": ["Bash(custom-allow:*)"],
    "deny": ["Bash(custom-deny:*)"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "CustomMatcher",
        "hooks": [{"type": "command", "command": "echo custom"}]
      }
    ]
  }
}
JSON

if bash "$SCRIPT" machine >/dev/null 2>&1 \
  && [ -f "$HOME/.claude/agents/elon.md" ] && [ ! -L "$HOME/.claude/agents/elon.md" ] \
  && [ -f "$HOME/.claude/agents/release-manager.md" ] && [ ! -L "$HOME/.claude/agents/release-manager.md" ] \
  && ! grep -q '{{PROJECT_NAME}}' "$HOME/.claude/agents/elon.md" \
  && [ -f "$HOME/.claude/hooks/session-start.md" ] && [ ! -L "$HOME/.claude/hooks/session-start.md" ] \
  && ! grep -q '{{PROJECT_NAME}}' "$HOME/.claude/hooks/session-start.md" \
  && [ -L "$HOME/.claude/hooks/guard-bash.py" ] \
  && [ -L "$HOME/.claude/bin/state-of-play.sh" ] \
  && [ -L "$HOME/.claude/model-routing.md" ] \
  && [ -L "$HOME/.agents/skills/tdd" ] \
  && [ -L "$HOME/.agents/skills/elon" ] \
  && [ -L "$HOME/.claude/skills/elon" ] \
  && [ ! -e "$HOME/.cursor/skills" ] \
  && python3 - <<'PY'
import json, os
s = json.load(open(os.path.expanduser("~/.claude/settings.json")))
assert s["env"]["CUSTOM_VAR"] == "1"
assert s["permissions"]["defaultMode"] == "bypassPermissions"
assert "Bash(custom-allow:*)" in s["permissions"]["allow"]
assert "Bash(custom-deny:*)" in s["permissions"]["deny"]
assert any(g.get("matcher") == "CustomMatcher" for g in s["hooks"]["PreToolUse"])
assert any("$HOME/.claude/hooks/guard-bash.py" in h.get("command", "") for g in s["hooks"]["PreToolUse"] for h in g.get("hooks", []))
PY
then
  check "machine mode writes rendered roles and session-start, links hooks, bins, Tier 1+2 skills and merges settings" ok
else
  check "machine mode writes rendered roles and session-start, links hooks, bins, Tier 1+2 skills and merges settings" bad
fi

printf '{broken json\n' > "$HOME/.claude/settings.json"
if ! bash "$SCRIPT" machine >/dev/null 2>&1; then
  check "machine mode refuses invalid JSON in ~/.claude/settings.json" ok
else
  check "machine mode refuses invalid JSON in ~/.claude/settings.json" bad
fi
rm -f "$HOME/.claude/settings.json"
bash "$SCRIPT" machine >/dev/null 2>&1


# 1324: machine seeds an empty grok_hosts into an existing fleet config and keeps keys already set.
seed_state="$tmp/seed-state"
mkdir -p "$seed_state"
printf '{"hosts":["box"],"repos":["~/r"]}\n' >"$seed_state/fleet-config.json"
AGENT_STATE_DIR="$seed_state" bash "$SCRIPT" machine >/dev/null 2>&1
if jq -e '.grok_hosts == [] and .hosts == ["box"]' "$seed_state/fleet-config.json" >/dev/null 2>&1; then
  printf '{"hosts":["box"],"grok_hosts":["box"]}\n' >"$seed_state/fleet-config.json"
  AGENT_STATE_DIR="$seed_state" bash "$SCRIPT" machine >/dev/null 2>&1
  if jq -e '.grok_hosts == ["box"]' "$seed_state/fleet-config.json" >/dev/null 2>&1; then
    check "machine seeds grok_hosts into the fleet config and never overwrites it" ok
  else
    check "machine seeds grok_hosts into the fleet config and never overwrites it" bad
  fi
else
  check "machine seeds grok_hosts into the fleet config and never overwrites it" bad
fi

agent_team_cases_done
