#!/usr/bin/env bash
# Round 3 findings.
# Part of the agent-team.sh tests, split from agent-team.test.sh so the parts run in parallel (#1325).
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# shellcheck source=script/tests/lib/agent-team-cases.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/agent-team-cases.sh"

# ── 9. Round 3 findings (each red before its fix) ─────────────────────────────
# 9.1 A real .agent/skills directory is project content: only the old symlink goes.
agentdir_repo="$tmp/agentdir-repo"
mkdir -p "$agentdir_repo/.agent/skills"
git -C "$agentdir_repo" init -q
git -C "$agentdir_repo" remote add origin "https://github.com/example-org/agentdir.git"
printf 'keep\n' > "$agentdir_repo/.agent/skills/README.md"
bash "$SCRIPT" project "$agentdir_repo" --project-name agentdir >/dev/null 2>&1
if [ -f "$agentdir_repo/.agent/skills/README.md" ] \
  && bash "$SCRIPT" check "$agentdir_repo" >/dev/null 2>&1; then
  check "round 3 item 1: real .agent/skills directory survives project and passes check" ok
else
  check "round 3 item 1: real .agent/skills directory survives project and passes check" bad
fi

# 9.2 machine backs up real files and directories instead of deleting them, and a second run is a no-op.
export HOME="$tmp/safe-home"
export DOTFILES="$real_dotfiles"
mkdir -p "$HOME/.claude/agents" "$HOME/.claude/skills/team-audit"
printf 'my elon\n' > "$HOME/.claude/agents/elon.md"
printf 'my notes\n' > "$HOME/.claude/skills/team-audit/NOTES.md"
bash "$SCRIPT" machine >/dev/null 2>&1
elon_bak=$(find "$HOME/.claude/agents" -maxdepth 1 -name 'elon.md.bak.*' | head -n 1)
ta_bak=$(find "$HOME/.claude/skills" -maxdepth 1 -name 'team-audit.bak.*' | head -n 1)
if [ -f "$HOME/.claude/agents/elon.md" ] && [ ! -L "$HOME/.claude/agents/elon.md" ] \
  && ! grep -q 'my elon' "$HOME/.claude/agents/elon.md" \
  && [ -n "$elon_bak" ] && [ "$(cat "$elon_bak")" = "my elon" ] \
  && [ -L "$HOME/.claude/skills/team-audit" ] \
  && [ -n "$ta_bak" ] && [ "$(cat "$ta_bak/NOTES.md")" = "my notes" ]; then
  check "round 3 item 2: machine backs up a real role file and a real skill directory" ok
else
  check "round 3 item 2: machine backs up a real role file and a real skill directory" bad
fi
baks_before=$(find "$HOME/.claude" "$HOME/.agents" -name '*.bak.*' | wc -l | tr -d ' ')
second_out=$(bash "$SCRIPT" machine 2>&1)
baks_after=$(find "$HOME/.claude" "$HOME/.agents" -name '*.bak.*' | wc -l | tr -d ' ')
if ! echo "$second_out" | grep -qE '^(linked |agent-team: backed up|merged |wrote )' \
  && [ "$baks_before" = "$baks_after" ]; then
  check "round 3 item 2: a second machine run changes nothing" ok
else
  check "round 3 item 2: a second machine run changes nothing" bad
  echo "$second_out" | grep -E '^(linked |agent-team: backed up|merged |wrote )' | head -n 3 >&2
fi
export HOME="$tmp/home"
export DOTFILES="$tmp/dotfiles"

# 9.3 Old adopt wrote only <role>.md.sha256: an unchanged role must not feed old template lines into team-facts.
sha_repo="$tmp/sha-repo"
mkdir -p "$sha_repo/.claude/agent-team-baseline" "$sha_repo/.claude/agents"
git -C "$sha_repo" init -q
git -C "$sha_repo" remote add origin "https://github.com/example-org/sha.git"
printf '# old\n- elon old line\n' > "$sha_repo/.claude/agents/elon.md"
shasum -a 256 < "$sha_repo/.claude/agents/elon.md" | cut -d' ' -f1 > "$sha_repo/.claude/agent-team-baseline/elon.md.sha256"
printf '# old\n- fs old line\n' | shasum -a 256 | cut -d' ' -f1 > "$sha_repo/.claude/agent-team-baseline/fullstack-dev.md.sha256"
printf '# old\n- fs old line\n- my fullstack rule\n' > "$sha_repo/.claude/agents/fullstack-dev.md"
bash "$SCRIPT" project "$sha_repo" --project-name sha >/dev/null 2>&1
if grep -q 'my fullstack rule' "$sha_repo/docs/agents/team-facts.md" \
  && ! grep -q 'elon old line' "$sha_repo/docs/agents/team-facts.md"; then
  check "round 3 item 3: sha256 baseline skips an unchanged role, keeps a customized one" ok
else
  check "round 3 item 3: sha256 baseline skips an unchanged role, keeps a customized one" bad
fi

# 9.5 An existing team-facts.md missing headings gets them appended, content kept, and check passes.
heads_repo="$tmp/heads-repo"
mkdir -p "$heads_repo/docs/agents"
git -C "$heads_repo" init -q
git -C "$heads_repo" remote add origin "https://github.com/example-org/heads.git"
printf '# Team facts\n\n## Repository\n\n* mine: keep-this-line\n' > "$heads_repo/docs/agents/team-facts.md"
bash "$SCRIPT" project "$heads_repo" --project-name heads >/dev/null 2>&1
if grep -q 'keep-this-line' "$heads_repo/docs/agents/team-facts.md" \
  && grep -q '^## Terminal shortcut' "$heads_repo/docs/agents/team-facts.md" \
  && grep -q '^## Role facts' "$heads_repo/docs/agents/team-facts.md" \
  && bash "$SCRIPT" check "$heads_repo" >/dev/null 2>&1; then
  check "round 3 item 5: project appends missing team-facts headings and check passes" ok
else
  check "round 3 item 5: project appends missing team-facts headings and check passes" bad
fi

# 9.6 Non-template files inside a Tier 2 skill dir: dry-run warns per path, project backs them up first.
t2_repo="$tmp/t2-repo"
mkdir -p "$t2_repo/.agents/skills/team-audit/notes"
git -C "$t2_repo" init -q
git -C "$t2_repo" remote add origin "https://github.com/example-org/t2.git"
printf 'custom\n' > "$t2_repo/.agents/skills/team-audit/CUSTOM.md"
printf 'deep\n' > "$t2_repo/.agents/skills/team-audit/notes/deep.md"
dry_out=$(bash "$SCRIPT" project "$t2_repo" --project-name t2 --dry-run 2>&1)
if echo "$dry_out" | grep -q 'CUSTOM.md' && echo "$dry_out" | grep -q 'notes/deep.md' \
  && [ -f "$t2_repo/.agents/skills/team-audit/CUSTOM.md" ]; then
  check "round 3 item 6: project --dry-run warns about each non-template file in a Tier 2 skill dir" ok
else
  check "round 3 item 6: project --dry-run warns about each non-template file in a Tier 2 skill dir" bad
fi
bash "$SCRIPT" project "$t2_repo" --project-name t2 >/dev/null 2>&1
if [ ! -e "$t2_repo/.agents/skills/team-audit" ] \
  && bash "$SCRIPT" check "$t2_repo" >/dev/null 2>&1 \
  && [ "$(find "$t2_repo" -path "$t2_repo/.git" -prune -o -type f -name CUSTOM.md -print | head -n 1 | xargs cat 2>/dev/null)" = "custom" ] \
  && [ "$(find "$t2_repo" -path "$t2_repo/.git" -prune -o -type f -name deep.md -print | head -n 1 | xargs cat 2>/dev/null)" = "deep" ]; then
  check "round 3 item 6: project backs up non-template files before removing the Tier 2 skill dir" ok
else
  check "round 3 item 6: project backs up non-template files before removing the Tier 2 skill dir" bad
fi

# 9.7 The 02:29 incident: machine keeps every key it does not own and backs settings.json up first.
export HOME="$tmp/settings-home"
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "model": "my-model",
  "env": {"MY_VAR": "é1"},
  "apiKeyHelper": "/bin/my-helper",
  "statusLine": {"type": "command", "command": "my-status"},
  "enabledPlugins": {"mine@market": true},
  "deniedMcpServers": [{"serverName": "mine-only"}],
  "mcpServers": {"x": {"command": "x"}},
  "includeCoAuthoredBy": false,
  "cleanupPeriodDays": 9,
  "someKeyMachineHasNeverSeen": {"nested": [1, {"deep": null}]},
  "permissions": {
    "defaultMode": "default",
    "allow": ["Bash(mine:*)"],
    "additionalDirectories": ["/my/dir"]
  },
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "my-stop"}]}]}
}
JSON
cp "$HOME/.claude/settings.json" "$tmp/settings-original.json"
bash "$SCRIPT" machine >/dev/null 2>&1
if python3 - "$tmp/settings-original.json" "$HOME/.claude/settings.json" <<'PY'
import glob, json, os, sys
orig = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
for key, value in orig.items():
    if key in ("permissions", "hooks"):
        continue
    assert new.get(key) == value, key
assert set(new) == set(orig) | {"hooks", "permissions"}, sorted(set(new) ^ set(orig))
assert new["permissions"]["additionalDirectories"] == ["/my/dir"]
assert "Bash(mine:*)" in new["permissions"]["allow"]
assert new["hooks"]["Stop"][0]["hooks"][0]["command"] == "my-stop"
backups = glob.glob(os.path.expanduser("~/.claude/settings.json.bak.*"))
assert len(backups) == 1, backups
assert json.load(open(backups[0])) == orig
PY
then
  check "round 3 settings: machine keeps unowned keys exactly and backs settings.json up" ok
else
  check "round 3 settings: machine keeps unowned keys exactly and backs settings.json up" bad
fi
bash "$SCRIPT" machine >/dev/null 2>&1
if [ "$(find "$HOME/.claude" -maxdepth 1 -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "1" ]; then
  check "round 3 settings: a no-op machine run makes no new settings backup" ok
else
  check "round 3 settings: a no-op machine run makes no new settings backup" bad
fi

# 9.8 #797: a dangling settings.json link is backed up as a link, never written through.
export HOME="$tmp/dangling-home"
mkdir -p "$HOME/.claude" "$tmp/gone"
ln -s "$tmp/gone/settings.json" "$HOME/.claude/settings.json"
dry_out=$(bash "$SCRIPT" machine --dry-run 2>&1)
bash "$SCRIPT" machine >/dev/null 2>&1
backups=("$HOME/.claude"/settings.json.bak.*)
if grep -q "would back up $HOME/.claude/settings.json, then write $HOME/.claude/settings.json" <<<"$dry_out" \
  && [ ! -e "$tmp/gone/settings.json" ] \
  && [ -f "$HOME/.claude/settings.json" ] && [ ! -L "$HOME/.claude/settings.json" ] \
  && [ "${#backups[@]}" = 1 ] && [ "$(readlink "${backups[0]}")" = "$tmp/gone/settings.json" ]; then
  check "#797: machine backs up a dangling settings.json link and writes a real file" ok
else
  check "#797: machine backs up a dangling settings.json link and writes a real file" bad
fi
export HOME="$tmp/home"


agent_team_cases_done
