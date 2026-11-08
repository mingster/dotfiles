#!/usr/bin/env bash
# shellcheck source=tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/tests/lib/asdf-pin.sh"
# Tests for script/agent-team.sh (machine, project, sync, check, all).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
real_dotfiles=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export DOTFILES="$tmp/dotfiles"
mkdir "$DOTFILES"
for entry in "$real_dotfiles"/* "$real_dotfiles"/.[!.]*; do
  [ "$(basename "$entry")" = .git ] || ln -s "$entry" "$DOTFILES/"
done

pass=0
fail=0
check() {
  if [ "$2" = ok ]; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
  fi
}

SCRIPT="$here/agent-team.sh"

# ── 1. Retired scripts moved to _outdated/ and wired callers ──────────────────
if [ ! -e "$real_dotfiles/script/adopt-agent-team.sh" ] \
  && [ ! -e "$real_dotfiles/script/init-agent-project.sh" ] \
  && [ ! -e "$real_dotfiles/script/sync-team-skills.sh" ] \
  && [ ! -e "$real_dotfiles/script/agent-project-autoinit.sh" ] \
  && [ ! -e "$real_dotfiles/script/agent-project-autoinit.test.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/adopt-agent-team.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/init-agent-project.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/sync-team-skills.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/agent-project-autoinit.sh" ] \
  && [ -f "$real_dotfiles/_outdated/script/agent-project-autoinit.test.sh" ]; then
  check "retired adoption scripts and autoinit test moved to _outdated/" ok
else
  check "retired adoption scripts and autoinit test moved to _outdated/" bad
fi

if grep -q 'script/agent-team.sh" check' "$real_dotfiles/script/head-checks.sh" \
  && grep -q 'script/agent-team.sh" check' "$real_dotfiles/script/lead-merge.sh"; then
  check "head-checks.sh and lead-merge.sh call script/agent-team.sh check" ok
else
  check "head-checks.sh and lead-merge.sh call script/agent-team.sh check" bad
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
if [ "$rc" -eq 0 ] && [ ! -e "$HOME/.claude" ] && echo "$out" | grep -q "would link"; then
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
  && [ -L "$HOME/.claude/agents/elon.md" ] \
  && [ -L "$HOME/.claude/agents/release-manager.md" ] \
  && [ -L "$HOME/.claude/hooks/guard-bash.py" ] \
  && [ -L "$HOME/.claude/bin/state-of-play.sh" ] \
  && [ -L "$HOME/.claude/model-routing.md" ] \
  && [ -L "$HOME/.agents/skills/tdd" ] \
  && [ -L "$HOME/.agents/skills/elon" ] \
  && [ -L "$HOME/.claude/skills/elon" ] \
  && [ -L "$HOME/.cursor/skills/elon" ] \
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
  check "machine mode links roles, hooks, bins, Tier 1+2 skills and merges settings" ok
else
  check "machine mode links roles, hooks, bins, Tier 1+2 skills and merges settings" bad
fi

printf '{broken json\n' > "$HOME/.claude/settings.json"
if ! bash "$SCRIPT" machine >/dev/null 2>&1; then
  check "machine mode refuses invalid JSON in ~/.claude/settings.json" ok
else
  check "machine mode refuses invalid JSON in ~/.claude/settings.json" bad
fi
rm -f "$HOME/.claude/settings.json"
bash "$SCRIPT" machine >/dev/null 2>&1

# ── 3. AC 1: project <dir> --project-name <name> on an empty temp git repo ───
empty_repo="$tmp/empty-repo"
mkdir -p "$empty_repo"
git -C "$empty_repo" init -q
git -C "$empty_repo" remote add origin "https://github.com/example-org/alpha-widget.git"

# Stub gh for --labels test
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$GH_LABELS_LOG"
exit 0
EOS
chmod +x "$tmp/bin/gh"
export GH_LABELS_LOG="$tmp/gh-labels.log"

if PATH="$tmp/bin:$PATH" bash "$SCRIPT" project "$empty_repo" --project-name alpha-widget --labels >/dev/null 2>&1; then
  check "project on empty git repo exits 0" ok
else
  check "project on empty git repo exits 0" bad
fi

if [ -f "$empty_repo/AGENTS.md" ] \
  && [ -f "$empty_repo/CLAUDE.md" ] \
  && [ "$(cat "$empty_repo/CLAUDE.md")" = "@AGENTS.md" ] \
  && [ -f "$empty_repo/docs/agents/issue-tracker.md" ] \
  && [ -f "$empty_repo/docs/agents/triage-labels.md" ] \
  && [ -f "$empty_repo/docs/agents/domain.md" ] \
  && [ -f "$empty_repo/docs/agents/team-facts.md" ] \
  && [ -f "$empty_repo/docs/agents/deploy-facts.md" ] \
  && [ -f "$empty_repo/docs/agents/team.md" ] \
  && [ -f "$empty_repo/docs/agents/elon-dispatch.md" ] \
  && [ -f "$empty_repo/docs/agents/release-manager-work.md" ] \
  && [ -f "$empty_repo/.claude/hooks/guard-config.json" ] \
  && [ -f "$empty_repo/.claude/settings.project.json" ] \
  && [ -f "$empty_repo/.claude/settings.json" ] \
  && [ -f "$empty_repo/.claude/model-routing.md" ] \
  && [ -f "$empty_repo/.cursor/changelog-hook.json" ] \
  && [ -x "$empty_repo/bin/changelog-compile.sh" ] \
  && [ -x "$empty_repo/bin/changelog-compile.test.sh" ] \
  && [ -f "$empty_repo/changelog.d/README.md" ] \
  && grep -q "alpha-widget" "$empty_repo/docs/agents/team-facts.md" \
  && grep -q "alpha-widget" "$empty_repo/docs/agents/deploy-facts.md" \
  && [ "$(wc -l < "$GH_LABELS_LOG" | tr -d ' ')" -eq 5 ]; then
  check "project on empty repo seeds layout, renders project name, compiles settings, and creates 5 labels" ok
else
  check "project on empty repo seeds layout, renders project name, compiles settings, and creates 5 labels" bad
fi

if [ ! -e "$empty_repo/.claude/agents" ] \
  && [ ! -e "$empty_repo/.claude/hooks/guard-bash.py" ] \
  && [ ! -e "$empty_repo/.claude/hooks/strikes.py" ] \
  && [ ! -e "$empty_repo/.claude/hooks/worker-budget.py" ] \
  && [ ! -e "$empty_repo/.claude/hooks/session-start.md" ] \
  && [ ! -e "$empty_repo/.claude/bin" ] \
  && [ ! -e "$empty_repo/.agents/skills" ] \
  && [ ! -e "$empty_repo/.claude/skills" ] \
  && [ ! -e "$empty_repo/.cursor/skills" ]; then
  check "project on empty repo creates zero canonical role, shared hook, or Tier 2 skill copies/links" ok
else
  check "project on empty repo creates zero canonical role, shared hook, or Tier 2 skill copies/links" bad
fi

# ── 4. AC 2 & AC 3: Drifted fixture repo (--dry-run first, then migration) ───
drifted="$tmp/drifted-repo"
mkdir -p "$drifted/.claude/agents" "$drifted/.claude/hooks" "$drifted/.claude/bin" \
  "$drifted/.claude/agent-team-baseline/.claude/agents" \
  "$drifted/.agents/skills/elon" "$drifted/.agents/skills/crew" "$drifted/.agents/skills/deploy" \
  "$drifted/.agents/skills/custom-tier3" \
  "$drifted/.claude/skills" "$drifted/.cursor/skills" "$drifted/bin"
git -C "$drifted" init -q
git -C "$drifted" config user.name "Test"
git -C "$drifted" config user.email "test@example.invalid"

# Populate canonical roles with project-specific lines + stale transition clause
for r in elon architect-pm fullstack-dev qa-sdet secops-finops release-manager sales-marketing support-csm; do
  sed 's/{{PROJECT_NAME}}/beta-service/g' "$real_dotfiles/templates/agent-team/.claude/agents/$r.md" \
    > "$drifted/.claude/agents/$r.md"
  cp "$drifted/.claude/agents/$r.md" "$drifted/.claude/agent-team-baseline/.claude/agents/$r.md"
done
printf '\n- Always run ./bin/beta-preflight.sh before opening a PR.\n' >> "$drifted/.claude/agents/fullstack-dev.md"
printf '\n- Verify smoke check on port 4199 after staging deploy.\n' >> "$drifted/.claude/agents/release-manager.md"

# Non-canonical project role (must be preserved)
cat > "$drifted/.claude/agents/stream-health.md" <<'MD'
---
name: stream-health
description: Project-specific stream health specialist.
---
# Stream Health Role
Monitor stream pipelines.
MD

# Forked guard-bash.py with # PROJECT CONFIG constants + production-hosts.txt
cat > "$drifted/.claude/hooks/guard-bash.py" <<'PY'
#!/usr/bin/env python3
# ── PROJECT CONFIG ────────────────────────────────────────────────────────────
PRODUCTION_HOSTS = {"prod-alpha.example.invalid"}
STAGE_BRANCHES = ("stage", "staging", "preview")
STAGE_BRANCH_COMPONENTS = ("web", "worker")
PROMOTE_RULES = [
    ("bin/promote-staging.sh", "staging", False),
    ("bin/promote-prod.sh", "main", True),
]
ROLLBACK_SCRIPTS = ("bin/rollback-prod.sh",)
APPLY_SCRIPTS = ("bin/apply-sql.sh",)
APPROVAL_NAMESPACE = "beta-service"
APPROVAL_FILE = "/tmp/beta-service-owner-approved"
BLOCKED_SCRIPTS = ("bin/reprovision-node.sh",)
PY
printf '# Production hosts\nprod-beta.example.invalid\n' > "$drifted/.claude/hooks/production-hosts.txt"
cp "$real_dotfiles/templates/agent-team/.claude/hooks/strikes.py" "$drifted/.claude/hooks/strikes.py"
cp "$real_dotfiles/templates/agent-team/.claude/hooks/worker-budget.py" "$drifted/.claude/hooks/worker-budget.py"
cp "$real_dotfiles/templates/agent-team/.claude/hooks/session-start.md" "$drifted/.claude/hooks/session-start.md"

# Standalone project hook (must be preserved)
cat > "$drifted/.claude/hooks/warn-elon-fullstack.py" <<'PY'
#!/usr/bin/env python3
import sys
sys.exit(0)
PY

# Shared .claude/bin copies (must be removed)
cp "$real_dotfiles/templates/agent-team/.claude/bin/env-peek.py" "$drifted/.claude/bin/env-peek.py"
cp "$real_dotfiles/templates/agent-team/.claude/bin/state-of-play.sh" "$drifted/.claude/bin/state-of-play.sh"

# Tier 2 skill copies + links (must be removed) and Tier 3 skill (must be preserved)
printf -- '---\nname: elon\n---\n' > "$drifted/.agents/skills/elon/SKILL.md"
printf -- '---\nname: crew\n---\n' > "$drifted/.agents/skills/crew/SKILL.md"
printf -- '---\nname: deploy\n---\n' > "$drifted/.agents/skills/deploy/SKILL.md"
ln -s "../../.agents/skills/elon" "$drifted/.claude/skills/elon"
ln -s "../../.agents/skills/elon" "$drifted/.cursor/skills/elon"
ln -s "../../.agents/skills/crew" "$drifted/.claude/skills/crew"
ln -s "../../.agents/skills/deploy" "$drifted/.cursor/skills/deploy"
printf -- '---\nname: custom-tier3\ndescription: Custom project skill.\n---\n# Custom Tier 3\n' \
  > "$drifted/.agents/skills/custom-tier3/SKILL.md"

# Per-project bin/team-audit-metrics.ts (must be removed)
printf 'export const metrics = true;\n' > "$drifted/bin/team-audit-metrics.ts"

# Drifted .claude/settings.json with extra allow, deny, and standalone project hook
python3 - "$real_dotfiles/templates/agent-team/.claude/settings.json" "$drifted/.claude/settings.json" <<'PY'
import json, sys
tpl = json.load(open(sys.argv[1]))
tpl["permissions"]["allow"].append("Bash(./bin/beta-preflight.sh*)")
tpl["permissions"]["deny"].append("Bash(bin/reprovision-node.sh*)")
tpl["hooks"]["PreToolUse"].append({
    "matcher": "Edit|Write",
    "hooks": [{"type": "command", "command": "python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/warn-elon-fullstack.py\""}]
})
with open(sys.argv[2], "w") as f:
    json.dump(tpl, f, indent=2)
    f.write("\n")
PY

git -C "$drifted" add -A
git -C "$drifted" commit -qm "initial drifted state"

# AC 3: --dry-run before migration lists planned removals and extracted facts while leaving git status unchanged
dry_out=$(bash "$SCRIPT" project "$drifted" --project-name beta-service --dry-run 2>&1)
dry_rc=$?
porcelain_after_dry=$(git -C "$drifted" status --porcelain)
if [ "$dry_rc" -eq 0 ] \
  && [ -z "$porcelain_after_dry" ] \
  && echo "$dry_out" | grep -Fq "extract .claude/hooks/guard-config.json: production_hosts=" \
  && echo "$dry_out" | grep -Fq "extract .claude/hooks/guard-config.json: promote_scripts=" \
  && echo "$dry_out" | grep -Fq "extract .claude/settings.project.json permissions.allow: Bash(./bin/beta-preflight.sh*)" \
  && echo "$dry_out" | grep -Fq "extract .claude/settings.project.json permissions.deny: Bash(bin/reprovision-node.sh*)" \
  && echo "$dry_out" | grep -Fq "extract .claude/settings.project.json hooks.PreToolUse:" \
  && echo "$dry_out" | grep -Fq "warn-elon-fullstack.py" \
  && echo "$dry_out" | grep -Fq "extract docs/agents/team-facts.md (## Role facts / ### fullstack-dev):" \
  && echo "$dry_out" | grep -Fq "would remove .claude/agents/fullstack-dev.md" \
  && echo "$dry_out" | grep -Fq "would remove .claude/hooks/guard-bash.py" \
  && echo "$dry_out" | grep -Fq "would remove .claude/bin/state-of-play.sh" \
  && echo "$dry_out" | grep -Fq "would remove .agents/skills/elon" \
  && echo "$dry_out" | grep -Fq "would remove bin/team-audit-metrics.ts"; then
  check "project --dry-run lists every planned removal and extracted fact and leaves git status clean" ok
else
  echo "DRY_RC=$dry_rc PORCELAIN=$porcelain_after_dry" >&2
  echo "$dry_out" >&2
  check "project --dry-run lists every planned removal and extracted fact and leaves git status clean" bad
fi

# AC 2: Run migration on drifted fixture repo
if bash "$SCRIPT" project "$drifted" --project-name beta-service >/dev/null 2>&1; then
  check "project migration on drifted fixture repo exits 0" ok
else
  check "project migration on drifted fixture repo exits 0" bad
fi

# Verify extracted guard-config.json, settings.project.json, and team-facts.md Role facts
if python3 - "$drifted" <<'PY'
import json, os, sys
root = sys.argv[1]
g = json.load(open(os.path.join(root, ".claude/hooks/guard-config.json")))
assert set(g["production_hosts"]) == {"prod-alpha.example.invalid", "prod-beta.example.invalid"}, g
assert g["stage_branches"] == ["stage", "staging", "preview"], g
assert g["stage_branch_components"] == ["web", "worker"], g
assert len(g["promote_scripts"]) == 2, g
assert g["rollback_scripts"] == ["bin/rollback-prod.sh"], g
assert g["apply_scripts"] == ["bin/apply-sql.sh"], g
assert g["approval_namespace"] == "beta-service", g
assert g["approval_file"] == "/tmp/beta-service-owner-approved", g
assert g["blocked_scripts"] == ["bin/reprovision-node.sh"], g

sp = json.load(open(os.path.join(root, ".claude/settings.project.json")))
assert "Bash(./bin/beta-preflight.sh*)" in sp["permissions"]["allow"], sp
assert "Bash(bin/reprovision-node.sh*)" in sp["permissions"]["deny"], sp
assert any("warn-elon-fullstack.py" in h.get("command", "") for grp in sp["hooks"].get("PreToolUse", []) for h in grp.get("hooks", [])), sp

tf = open(os.path.join(root, "docs/agents/team-facts.md")).read()
assert "## Role facts" in tf, tf
assert "### fullstack-dev" in tf and "./bin/beta-preflight.sh" in tf, tf
assert "### release-manager" in tf and "port 4199" in tf, tf
PY
then
  check "migration extracts guard-config.json, settings.project.json, and team-facts.md Role facts" ok
else
  check "migration extracts guard-config.json, settings.project.json, and team-facts.md Role facts" bad
fi

# Verify removals and preserved project extensions
if [ ! -e "$drifted/.claude/agents/elon.md" ] \
  && [ ! -e "$drifted/.claude/agents/fullstack-dev.md" ] \
  && [ ! -e "$drifted/.claude/agents/release-manager.md" ] \
  && [ ! -e "$drifted/.claude/agent-team-baseline" ] \
  && [ ! -e "$drifted/.claude/hooks/guard-bash.py" ] \
  && [ ! -e "$drifted/.claude/hooks/strikes.py" ] \
  && [ ! -e "$drifted/.claude/hooks/worker-budget.py" ] \
  && [ ! -e "$drifted/.claude/hooks/session-start.md" ] \
  && [ ! -e "$drifted/.claude/hooks/production-hosts.txt" ] \
  && [ ! -e "$drifted/.claude/bin" ] \
  && [ ! -e "$drifted/.agents/skills/elon" ] \
  && [ ! -e "$drifted/.agents/skills/crew" ] \
  && [ ! -e "$drifted/.agents/skills/deploy" ] \
  && [ ! -L "$drifted/.claude/skills/elon" ] \
  && [ ! -L "$drifted/.cursor/skills/elon" ] \
  && [ ! -e "$drifted/bin/team-audit-metrics.ts" ] \
  && [ -f "$drifted/.claude/agents/stream-health.md" ] \
  && [ -f "$drifted/.claude/hooks/warn-elon-fullstack.py" ] \
  && [ -f "$drifted/.agents/skills/custom-tier3/SKILL.md" ]; then
  check "migration removes canonical roles, shared hooks/bins, Tier 2 skills, and metrics script while preserving non-canonical role, standalone hook, and Tier 3 skill" ok
else
  check "migration removes canonical roles, shared hooks/bins, Tier 2 skills, and metrics script while preserving non-canonical role, standalone hook, and Tier 3 skill" bad
fi

# ── 5. AC 4: Second run is a no-op and check exits 0 on both repos ───────────
git -C "$empty_repo" add -A && git -C "$empty_repo" -c user.name=t -c user.email=t@t commit -qm "seeded"
git -C "$drifted" add -A && git -C "$drifted" commit -qm "migrated"

out_empty_2=$(bash "$SCRIPT" project "$empty_repo" --project-name alpha-widget 2>&1)
rc_empty_2=$?
out_drifted_2=$(bash "$SCRIPT" sync "$drifted" --project-name beta-service 2>&1)
rc_drifted_2=$?

if [ "$rc_empty_2" -eq 0 ] \
  && [ "$rc_drifted_2" -eq 0 ] \
  && [ -z "$(git -C "$empty_repo" status --porcelain)" ] \
  && [ -z "$(git -C "$drifted" status --porcelain)" ] \
  && [ -z "$out_empty_2" ] \
  && [ -z "$out_drifted_2" ] \
  && bash "$SCRIPT" check "$empty_repo" "$drifted" >/dev/null 2>&1; then
  check "second project/sync run is a no-op and check exits 0 on both repos" ok
else
  check "second project/sync run is a no-op and check exits 0 on both repos" bad
fi

# ── 6. AC 5: check <dir> failure conditions ──────────────────────────────────
# 6a. Canonical role file placed in <dir>/.claude/agents/
mkdir -p "$empty_repo/.claude/agents"
printf '# drifted role\n' > "$empty_repo/.claude/agents/elon.md"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "check exits 1 when a canonical role file is placed in .claude/agents/" ok
else
  check "check exits 1 when a canonical role file is placed in .claude/agents/" bad
fi
rm -rf "$empty_repo/.claude/agents"

# 6b. settings.project.json weakens a template deny entry
cp "$empty_repo/.claude/settings.project.json" "$tmp/sp.bak"
cat > "$empty_repo/.claude/settings.project.json" <<'JSON'
{
  "permissions": {
    "allow": ["Read(.env)"],
    "deny": []
  },
  "hooks": {}
}
JSON
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1 \
  && ! bash "$SCRIPT" project "$empty_repo" >/dev/null 2>&1; then
  check "check and project exit 1 when settings.project.json weakens a template deny entry" ok
else
  check "check and project exit 1 when settings.project.json weakens a template deny entry" bad
fi

# 6c. settings.project.json weakens or overrides a template hook entry
cat > "$empty_repo/.claude/settings.project.json" <<'JSON'
{
  "permissions": {
    "allow": [],
    "deny": []
  },
  "hooks": {
    "PreToolUse": []
  }
}
JSON
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "check exits 1 when settings.project.json weakens a template hook entry" ok
else
  check "check exits 1 when settings.project.json weakens a template hook entry" bad
fi
cp "$tmp/sp.bak" "$empty_repo/.claude/settings.project.json"

# 6d. .claude/settings.json differs from compiled merge
cp "$empty_repo/.claude/settings.json" "$tmp/s.bak"
printf '{\n  "permissions": {}\n}\n' > "$empty_repo/.claude/settings.json"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "check exits 1 when .claude/settings.json differs from compiled merge" ok
else
  check "check exits 1 when .claude/settings.json differs from compiled merge" bad
fi
cp "$tmp/s.bak" "$empty_repo/.claude/settings.json"

# 6e. Hand-edited template-managed file fails check, and sync restores it
echo "drift" >> "$empty_repo/docs/agents/team.md"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1 \
  && bash "$SCRIPT" sync "$empty_repo" >/dev/null 2>&1 \
  && bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "hand-edited template doc fails check and sync restores it" ok
else
  check "hand-edited template doc fails check and sync restores it" bad
fi

# 6f. Tier 3 skill colliding with Tier 1/2 skill fails check
mkdir -p "$empty_repo/.agents/skills/tdd"
printf -- '---\nname: tdd\n---\n' > "$empty_repo/.agents/skills/tdd/SKILL.md"
if ! bash "$SCRIPT" check "$empty_repo" >/dev/null 2>&1; then
  check "check exits 1 when a project skill collides with a central skill" ok
else
  check "check exits 1 when a project skill collides with a central skill" bad
fi
rm -rf "$empty_repo/.agents"

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

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
