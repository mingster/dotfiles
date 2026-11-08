#!/usr/bin/env bash
# agent-team.sh project closes the three gaps the #738 dry run found (#782):
# 1. a forked model pin in .claude/model-routing.md moves to .orca/presets.project.json and the
#    team-facts ## Model routing section before the file is rewritten, idempotently, while a row
#    copied from an older template is not taken for a pin;
# 2. template files the project owns (team docs, .agent/skills) print "skip (project owned)" and
#    are left alone;
# 3. an extracted allow rule naming a file the same run removes is dropped with a printed line.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/script/tests/fixtures/agent-team-project-gaps"
TPL="$ROOT/templates/agent-team"
SCRIPT="$ROOT/script/agent-team.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# A project from before the redesign: forked elon row, project owned team docs, a .agent/skills
# link, a project copy of env-peek.py and a settings.json allow rule that runs that copy.
make_project() {
  local p=$1 doc
  mkdir -p "$p/.claude/bin" "$p/.orca" "$p/docs/agents" "$p/.agent"
  awk -v row="$(cat "$FIXTURE/elon-row.md")" -v old="$OLD_ROW" \
    '/^\| elon \|/ { print row; next } /^\| fullstack-dev \|/ { print old; next } { print }' \
    "$TPL/.claude/model-routing.md" > "$p/.claude/model-routing.md"
  cp "$FIXTURE/presets.project.json" "$p/.orca/presets.project.json"
  for doc in team.md elon-dispatch.md release-manager-work.md; do
    cp "$FIXTURE/project-doc.md" "$p/docs/agents/$doc"
  done
  ln -s ../.agents/skills "$p/.agent/skills"
  cp "$TPL/.claude/bin/env-peek.py" "$p/.claude/bin/env-peek.py"
  python3 - "$TPL/.claude/settings.json" "$FIXTURE/extra-allow.json" "$p/.claude/settings.json" <<'PY'
import json, sys
tpl = json.load(open(sys.argv[1]))
tpl["permissions"]["allow"].extend(json.load(open(sys.argv[2])))
json.dump(tpl, open(sys.argv[3], "w"), indent=2)
PY
  printf '# Agents\n' > "$p/AGENTS.md"
  git -C "$p" init -q -b main
  git -C "$p" remote add origin "https://github.com/example-org/gaps.git"
}

# A fullstack-dev row from an older committed template: a stale copy, not a pin.
OLD_ROW="$(git -C "$ROOT" log --format=%H -- templates/agent-team/.claude/model-routing.md | while read -r h; do
  git -C "$ROOT" show "${h}:templates/agent-team/.claude/model-routing.md" 2>/dev/null | grep -m1 '^| fullstack-dev |'
done | grep -vxF "$(grep -m1 '^| fullstack-dev |' "$TPL/.claude/model-routing.md")" | head -1)"
[ -n "$OLD_ROW" ] || { echo "FAIL no older fullstack-dev template row in git history"; exit 1; }

PROJ="$TMP/proj"
make_project "$PROJ"

# Dry run on a scratch copy: shows the pin extraction, the skip lines and the dropped rule, writes nothing.
SCRATCH="$TMP/scratch"
make_project "$SCRATCH"
before="$(cd "$SCRATCH" && find . -path ./.git -prune -o -print | sort | xargs shasum 2>/dev/null)"
dry="$(timeout 300 bash "$SCRIPT" project "$SCRATCH" --project-name gaps --dry-run 2>&1)"
after="$(cd "$SCRATCH" && find . -path ./.git -prune -o -print | sort | xargs shasum 2>/dev/null)"
echo "$dry" | grep -E '^(extract \.orca|extract docs/agents/team-facts.md \(## Model|skip \(project owned\)|drop )'
if grep -qF 'extract .orca/presets.project.json roles.elon: claude claude-opus-5-5 high' <<<"$dry" \
  && grep -qF 'skip (project owned): docs/agents/team.md' <<<"$dry" \
  && grep -qF 'drop .claude/settings.project.json permissions.allow: Bash(.claude/bin/env-peek.py *)' <<<"$dry" \
  && [ "$before" = "$after" ]; then
  ok "dry run shows pin extraction, skip lines and the dropped rule, and writes nothing"
else
  bad "dry run shows pin extraction, skip lines and the dropped rule, and writes nothing"
fi

out="$(timeout 300 bash "$SCRIPT" project "$PROJ" --project-name gaps 2>&1)" || bad "project run exits 0 ($(tail -3 <<<"$out"))"

# Gap 1: the forked elon pin survives the model-routing.md rewrite, once.
if python3 - "$PROJ/.orca/presets.project.json" <<'PY'
import json, sys
roles = json.load(open(sys.argv[1]))["roles"]
assert roles["elon"] == {"provider": "claude", "model": "claude-opus-5-5", "effort": "high"}, roles
assert roles["qa-sdet"] == {"provider": "antigravity", "model": "gemini-4-argon-high"}, roles
assert "fullstack-dev" not in roles, roles
PY
then
  pins_ok=1
else
  pins_ok=0
fi
facts="$PROJ/docs/agents/team-facts.md"
cp "$PROJ/.orca/presets.project.json" "$TMP/presets.1"
cp "$facts" "$TMP/facts.1"
again="$(timeout 300 bash "$SCRIPT" project "$PROJ" --project-name gaps 2>&1)"
# shellcheck disable=SC2016 # the backticks are literal markdown
if [ "$pins_ok" -eq 1 ] \
  && cmp -s "$TPL/.claude/model-routing.md" "$PROJ/.claude/model-routing.md" \
  && grep -qx '## Model routing' "$facts" \
  && grep -qxF 'note: .claude/model-routing.md row for fullstack-dev matches an older template, not a pin' <<<"$out" \
  && ! grep -qF -- '- `fullstack-dev`' "$facts" \
  && grep -qF -- '- `elon`: Claude, pinned by this project; `--agent claude --model claude-opus-5-5 --effort high`; no fallback.' "$facts" \
  && [ "$(grep -c '^## Model routing' "$facts")" = 1 ] \
  && cmp -s "$TMP/presets.1" "$PROJ/.orca/presets.project.json" \
  && cmp -s "$TMP/facts.1" "$facts" \
  && ! grep -q '^extract' <<<"$again"; then
  ok "gap 1: forked elon pin moves to presets.project.json and team-facts, a second run changes nothing"
else
  bad "gap 1: forked elon pin moves to presets.project.json and team-facts, a second run changes nothing"
fi

# Gap 2: project owned template files are skipped, unchanged and still pass check.
skips_ok=1
for doc in team.md elon-dispatch.md release-manager-work.md; do
  grep -qxF "skip (project owned): docs/agents/$doc" <<<"$out" || skips_ok=0
  cmp -s "$FIXTURE/project-doc.md" "$PROJ/docs/agents/$doc" || skips_ok=0
done
if [ "$skips_ok" -eq 1 ] \
  && grep -qxF 'skip (project owned): .agent/skills' <<<"$out" \
  && [ "$(readlink "$PROJ/.agent/skills")" = ../.agents/skills ] \
  && timeout 300 bash "$SCRIPT" check "$PROJ" >/dev/null 2>&1; then
  ok "gap 2: project owned docs and .agent/skills print skip lines, stay unchanged, and check passes"
else
  bad "gap 2: project owned docs and .agent/skills print skip lines, stay unchanged, and check passes"
fi

# Gap 3: no allow rule names the removed project env-peek.py; the shared and unrelated rules stay.
if [ ! -e "$PROJ/.claude/bin/env-peek.py" ] \
  && grep -qF 'drop .claude/settings.project.json permissions.allow: Bash(${CLAUDE_PROJECT_DIR}/.claude/bin/env-peek.py *) (names' <<<"$out" \
  && grep -qF 'drop .claude/settings.project.json permissions.allow: Bash($CLAUDE_PROJECT_DIR/.claude/bin/env-peek.py *) (names' <<<"$out" \
  && grep -qF 'drop .claude/settings.project.json permissions.allow: Bash(.claude/bin/env-peek.py *) (names .claude/bin/env-peek.py, which this run removes)' <<<"$out" \
  && python3 - "$PROJ/.claude/settings.project.json" "$PROJ/.claude/settings.json" <<'PY'
import json, sys
proj = json.load(open(sys.argv[1]))["permissions"]["allow"]
compiled = json.load(open(sys.argv[2]))["permissions"]["allow"]
for allow in (proj, compiled):
    for form in (".claude/bin", "$CLAUDE_PROJECT_DIR/.claude/bin", "${CLAUDE_PROJECT_DIR}/.claude/bin"):
        assert f"Bash({form}/env-peek.py *)" not in allow, (form, allow)
    assert 'Bash(python3 "$HOME/.claude/bin/env-peek.py" *)' in allow, allow
    assert "Bash(./bin/project-check.sh*)" in allow, allow
PY
then
  ok "gap 3: allow rules (plain, \$CLAUDE_PROJECT_DIR, \${CLAUDE_PROJECT_DIR}) for the removed env-peek.py copy are dropped with a printed line"
else
  bad "gap 3: allow rules (plain, \$CLAUDE_PROJECT_DIR, \${CLAUDE_PROJECT_DIR}) for the removed env-peek.py copy are dropped with a printed line"
fi

# The changelog scripts and README stay template managed: a stale copy is refreshed, not skipped.
managed_ok=1
for rel in bin/changelog-compile.sh bin/changelog-compile.test.sh changelog.d/README.md; do
  echo "stale" >> "$PROJ/$rel"
done
out2="$(timeout 300 bash "$SCRIPT" project "$PROJ" --project-name gaps 2>&1)"
for rel in bin/changelog-compile.sh bin/changelog-compile.test.sh changelog.d/README.md; do
  cmp -s "$TPL/$rel" "$PROJ/$rel" || managed_ok=0
  grep -qxF "skip (project owned): $rel" <<<"$out2" && managed_ok=0
done
if [ "$managed_ok" -eq 1 ]; then
  ok "changelog scripts and README stay template managed, a stale copy is refreshed"
else
  bad "changelog scripts and README stay template managed, a stale copy is refreshed"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
