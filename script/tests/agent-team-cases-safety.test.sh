#!/usr/bin/env bash
# Path safety and Verdict FAIL regressions.
# Part of the agent-team.sh tests, split from agent-team.test.sh so the parts run in parallel (#1325).
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# shellcheck source=script/tests/lib/agent-team-cases.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/agent-team-cases.sh"

empty_repo="$tmp/empty-repo"
mkdir -p "$empty_repo"
git -C "$empty_repo" init -q
git -C "$empty_repo" remote add origin "https://github.com/example-org/alpha-widget.git"

# ── 7. Path safety (refuses DOTFILES, HOME, and symlinked managed paths) ─────
if ! bash "$SCRIPT" project "$DOTFILES" >/dev/null 2>&1 \
  && ! bash "$SCRIPT" project "$HOME" >/dev/null 2>&1 \
  && ! DOTFILES=/nonexistent bash "$SCRIPT" project "$empty_repo" >/dev/null 2>&1; then
  check "project refuses DOTFILES, HOME, and nonexistent DOTFILES" ok
else
  check "project refuses DOTFILES, HOME, and nonexistent DOTFILES" bad
fi

sym_repo="$tmp/sym-repo"
mkdir -p "$sym_repo" "$tmp/outside"
git -C "$sym_repo" init -q
touch "$tmp/outside/AGENTS.md"
ln -s "$tmp/outside/AGENTS.md" "$sym_repo/AGENTS.md"
if ! bash "$SCRIPT" project "$sym_repo" >/dev/null 2>&1 \
  && [ ! -s "$tmp/outside/AGENTS.md" ]; then
  check "project refuses symlinked managed destination before writing" ok
else
  check "project refuses symlinked managed destination before writing" bad
fi

# ── 8. Verdict FAIL regression tests (one per finding) ───────────────────────
subdir_repo="$tmp/subdir-repo"
mkdir -p "$subdir_repo/nested"
git -C "$subdir_repo" init -q
if ! bash "$SCRIPT" project "$subdir_repo/nested" >/dev/null 2>&1; then
  check "finding 4: project refuses a git repo subdirectory" ok
else
  check "finding 4: project refuses a git repo subdirectory" bad
fi

if ! bash "$SCRIPT" project "$DOTFILES/templates/agent-team" >/dev/null 2>&1; then
  check "finding 4: project refuses a path inside dotfiles" ok
else
  check "finding 4: project refuses a path inside dotfiles" bad
fi

guard_refuse="$tmp/guard-refuse"
mkdir -p "$guard_refuse/.claude/hooks"
cat > "$guard_refuse/.claude/hooks/guard-bash.py" <<'PY'
PROMOTE_RULES = unknown_var
PY
git -C "$guard_refuse" init -q
if ! bash "$SCRIPT" project "$guard_refuse" >/dev/null 2>&1 \
  && [ -f "$guard_refuse/.claude/hooks/guard-bash.py" ]; then
  check "finding 1: refusing unconvertible guard config keeps guard-bash.py" ok
else
  check "finding 1: refusing unconvertible guard config keeps guard-bash.py" bad
fi

order_repo="$tmp/order-repo"
mkdir -p "$order_repo/.claude/hooks"
cat > "$order_repo/.claude/hooks/guard-bash.py" <<'PY'
BLOCKED_SCRIPTS = ("bin/x.sh",)
PY
cp "$real_dotfiles/templates/agent-team/.claude/hooks/strikes.py" "$order_repo/.claude/hooks/strikes.py"
git -C "$order_repo" init -q
git -C "$order_repo" remote add origin "https://github.com/example-org/order.git"
cat > "$order_repo/.claude/settings.project.json" <<'JSON'
{
  "permissions": {
    "allow": ["Read(.env)"],
    "deny": []
  },
  "hooks": {}
}
JSON
if ! bash "$SCRIPT" project "$order_repo" >/dev/null 2>&1 \
  && [ -f "$order_repo/.claude/hooks/guard-bash.py" ] \
  && [ -f "$order_repo/.claude/hooks/strikes.py" ]; then
  check "finding 3: settings validation failure leaves legacy guard-bash.py in place" ok
else
  check "finding 3: settings validation failure leaves legacy guard-bash.py in place" bad
fi

facts_repo="$tmp/facts-repo"
mkdir -p "$facts_repo"
git -C "$facts_repo" init -q
git -C "$facts_repo" remote add origin "https://github.com/example-org/facts.git"
printf '# Repo\n\n## Project facts the roles point to\n\nCustom database: shadow-db\n' > "$facts_repo/AGENTS.md"
bash "$SCRIPT" project "$facts_repo" --project-name facts >/dev/null 2>&1
if grep -q 'shadow-db' "$facts_repo/AGENTS.md" \
  && ! grep -q 'Fill these in:' "$facts_repo/AGENTS.md"; then
  check "finding 2: sync preserves customized Project facts in AGENTS.md" ok
else
  check "finding 2: sync preserves customized Project facts in AGENTS.md" bad
fi

machine_skill="$tmp/machine-skill"
mkdir -p "$machine_skill/.agents/skills/custom-local"
printf 'keep me\n' > "$machine_skill/.agents/skills/custom-local/SKILL.md"
export HOME="$machine_skill"
mkdir -p "$HOME/.claude"
bash "$SCRIPT" machine >/dev/null 2>&1
if [ -f "$machine_skill/.agents/skills/custom-local/SKILL.md" ]; then
  check "finding 5: machine keeps a non-dotfiles skill directory" ok
else
  check "finding 5: machine keeps a non-dotfiles skill directory" bad
fi
export HOME="$tmp/home"

legacy_repo="$tmp/legacy-repo"
mkdir -p "$legacy_repo/.claude/agent-team-baseline" "$legacy_repo/.claude/agents" \
  "$legacy_repo/.agent" "$legacy_repo/.agents/skills"
git -C "$legacy_repo" init -q
git -C "$legacy_repo" remote add origin "https://github.com/example-org/legacy.git"
printf '# old\n- legacy line only\n' | shasum -a 256 | cut -d' ' -f1 > "$legacy_repo/.claude/agent-team-baseline/elon.md.sha256"
printf '# current\n- legacy line only\n- custom elon bullet\n' > "$legacy_repo/.claude/agents/elon.md"
ln -s ../.agents/skills "$legacy_repo/.agent/skills"
printf '# Root\n' > "$legacy_repo/CLAUDE.md"
bash "$SCRIPT" project "$legacy_repo" --project-name legacy >/dev/null 2>&1
if grep -q 'custom elon bullet' "$legacy_repo/docs/agents/team-facts.md" \
  && [ "$(cat "$legacy_repo/CLAUDE.md")" = "@AGENTS.md" ] \
  && [ ! -e "$legacy_repo/.agent/skills" ]; then
  check "finding 6: baseline extraction, CLAUDE.md fix, and .agent/skills cleanup" ok
else
  check "finding 6: baseline extraction, CLAUDE.md fix, and .agent/skills cleanup" bad
fi

claude_merge_repo="$tmp/claude-merge-repo"
mkdir -p "$claude_merge_repo"
git -C "$claude_merge_repo" init -q
git -C "$claude_merge_repo" remote add origin "https://github.com/example-org/claude-merge.git"
printf '# Root agents\n' > "$claude_merge_repo/AGENTS.md"
printf '# Legacy instructions\n\nKeep this tribal knowledge.\n' > "$claude_merge_repo/CLAUDE.md"
merge_out=$(bash "$SCRIPT" project "$claude_merge_repo" --project-name claude-merge 2>&1)
if grep -q 'Keep this tribal knowledge' "$claude_merge_repo/AGENTS.md" \
  && grep -q 'Project notes from CLAUDE.md' "$claude_merge_repo/AGENTS.md" \
  && [ "$(cat "$claude_merge_repo/CLAUDE.md")" = "@AGENTS.md" ] \
  && echo "$merge_out" | grep -q 'moved CLAUDE.md content into AGENTS.md'; then
  check "finding 8: project preserves CLAUDE.md body in AGENTS.md before pointer rewrite" ok
else
  check "finding 8: project preserves CLAUDE.md body in AGENTS.md before pointer rewrite" bad
fi

cursor_keep_home="$tmp/cursor-keep-home"
export HOME="$cursor_keep_home"
mkdir -p "$HOME/.claude"
bash "$SCRIPT" machine >/dev/null 2>&1
mkdir -p "$HOME/.cursor/skills/elon"
printf 'user-written cursor skill\n' > "$HOME/.cursor/skills/elon/USER.md"
bash "$SCRIPT" machine >/dev/null 2>&1
if [ -f "$HOME/.cursor/skills/elon/USER.md" ] \
  && grep -q 'user-written cursor skill' "$HOME/.cursor/skills/elon/USER.md"; then
  check "finding 9: machine keeps real ~/.cursor/skills dir when Claude has symlink" ok
else
  check "finding 9: machine keeps real ~/.cursor/skills dir when Claude has symlink" bad
fi
export HOME="$tmp/home"

bash "$SCRIPT" project "$empty_repo" >/dev/null 2>&1
rm -f "$empty_repo/docs/agents/team.md"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "finding 7 (sync case 6): check fails on missing managed template copy" ok
else
  check "finding 7 (sync case 6): check fails on missing managed template copy" bad
fi
bash "$SCRIPT" sync "$empty_repo" >/dev/null 2>&1

cp "$real_dotfiles/templates/agent-team/.claude/hooks/strikes.py" "$empty_repo/.claude/hooks/strikes.py"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "finding 7: check fails when a shared hook copy exists in the project" ok
else
  check "finding 7: check fails when a shared hook copy exists in the project" bad
fi
rm -f "$empty_repo/.claude/hooks/strikes.py"

retired_skill="$tmp/retired-skill"
mkdir -p "$retired_skill/.agents/skills/beta"
git -C "$retired_skill" init -q
git -C "$retired_skill" remote add origin "https://github.com/example-org/retired.git"
cat > "$retired_skill/.agents/skills/beta/SKILL.md" <<'MD'
---
name: beta
---
<!-- Generated from dotfiles templates/agent-team/.agents/skills/beta by script/sync-team-skills.sh, do not edit. -->
MD
retired_out=$(bash "$SCRIPT" check "$retired_skill" 2>&1)
retired_rc=$?
if [ "$retired_rc" -ne 0 ] \
  && echo "$retired_out" | grep -q '.agents/skills/beta' \
  && bash "$SCRIPT" project "$retired_skill" --project-name retired >/dev/null 2>&1 \
  && [ ! -e "$retired_skill/.agents/skills/beta" ]; then
  check "finding 7 (case 15): check flags stale generated Tier 2 skill copy" ok
else
  check "finding 7 (case 15): check flags stale generated Tier 2 skill copy" bad
fi

scratch="$tmp/scratch-adoption"
mkdir -p "$scratch/.claude/hooks" "$scratch/.agents/skills/local-only" "$scratch/docs/agents"
git -C "$scratch" init -q
git -C "$scratch" remote add origin "https://github.com/example-org/scratch.git"
cat > "$scratch/.claude/hooks/guard-bash.py" <<'PY'
import re
STAGE_BRANCHES = ("dev",)
STAGE_BRANCH_COMPONENTS = {"dev": "web"}
PROMOTE_RULES = {"promote.sh": {"free_stages": {"staging"}, "component": 1, "sha": 2}}
PROMOTE_SCRIPTS = ("bin/go.sh",)
SECRETS_DIR = re.compile(r"(?:^|[/\s='\"<(])\.secrets(?:/|$|[\s'\"\)])")
SECRETS_STDIN_OK = [re.compile(r"pass")]
PY
printf '## Project facts the roles point to\n\nScratch DB: keep-me\n' > "$scratch/AGENTS.md"
printf '---\nname: local-only\n---\n' > "$scratch/.agents/skills/local-only/SKILL.md"
before=$(cd "$scratch" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)
bash "$SCRIPT" project "$scratch" --project-name scratch >/dev/null 2>&1
bash "$SCRIPT" sync "$scratch" >/dev/null 2>&1
bash "$SCRIPT" check "$scratch" >/dev/null 2>&1
after=$(cd "$scratch" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)
if grep -q 'keep-me' "$scratch/AGENTS.md" \
  && [ -f "$scratch/.agents/skills/local-only/SKILL.md" ] \
  && python3 - "$scratch" <<'PY'
import json, os, sys
g = json.load(open(os.path.join(sys.argv[1], ".claude/hooks/guard-config.json")))
assert g.get("secrets_dir") == ".secrets"
assert "promote.sh" in g.get("promote_scripts", {})
assert g.get("stage_branches") == {"dev": "web"}
PY
then
  check "acceptance: scratch adoption preserves project-owned values across project, sync, check" ok
  echo "scratch before files:" >&2
  echo "$before" >&2
  echo "scratch after files:" >&2
  echo "$after" >&2
else
  check "acceptance: scratch adoption preserves project-owned values across project, sync, check" bad
fi


agent_team_cases_done
