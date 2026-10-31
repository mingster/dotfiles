#!/usr/bin/env bash
# shellcheck source=tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/lib/asdf-pin.sh"
# Public CLI tests. All project writes and installer effects stay in a temp tree.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export DOTFILES=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() {
  if [ "$2" = ok ]; then pass=$((pass+1)); echo "ok   $1";
  else fail=$((fail+1)); echo "FAIL $1"; fi
}
mkdir "$tmp/dry"
out=$(bash "$here/adopt-agent-team.sh" --dry-run "$tmp/dry" 2>&1)
[ -z "$(ls -A "$tmp/dry")" ] && check "adoption preview writes nothing" ok || check "adoption preview writes nothing" bad
mkdir -p "$tmp/tools"
cat > "$tmp/tools/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = label ]; then echo label >> "$TEST_LABELS"; exit 0; fi
exit 1
SH
chmod +x "$tmp/tools/gh"
export PATH="$tmp/tools:$PATH" TEST_LABELS="$tmp/labels"
# Exercise composition with the real default 800-word role budget.
# The negative fixture below sets its own deliberately smaller budget.
unset ROLE_WORD_BUDGET
git init -q "$tmp/new project"
git -C "$tmp/new project" remote add origin https://github.com/mingster/synthetic.git
out=$(bash "$here/agent-team.sh" project "$tmp/new project" --project-name acme 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -f "$tmp/new project/docs/agents/issue-tracker.md" ] &&
  [ -f "$tmp/new project/.claude/hooks/worker-budget.py" ] &&
  [ -f "$tmp/new project/.claude/bin/env-peek.py" ] &&
  [ -f "$tmp/new project/.claude/agents/support-csm.md" ] &&
  grep -q 'on acme' "$tmp/new project/.claude/agents/fullstack-dev.md" &&
  [ "$(wc -l < "$TEST_LABELS" | tr -d ' ')" = 5 ] &&
  echo "$out" | grep -q 'team-audit: clean' &&
  echo "$out" | grep -q 'deploy-facts.md'; } && check "new project installs a complete audited team and labels" ok || { check "new project installs a complete audited team and labels" bad; echo "$out" | tail -12; }
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid add .
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
before=$(git -C "$tmp/new project" rev-parse HEAD)
out=$(bash "$here/agent-team.sh" reset "$tmp/new project" 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -z "$(git -C "$tmp/new project" status --porcelain)" ] &&
  echo "$out" | grep -q 'preview'; } && check "reset defaults to a read-only preview" ok || { check "reset defaults to a read-only preview" bad; echo "$out" | tail -5; }
printf '\nProject role text\n' >> "$tmp/new project/.claude/agents/fullstack-dev.md"
echo 'product facts' > "$tmp/new project/docs/agents/deploy-facts.md"
echo 'domain facts' > "$tmp/new project/docs/agents/domain.md"
echo 'domain context' > "$tmp/new project/CONTEXT.md"
echo stale > "$tmp/new project/.claude/hooks/worker-budget.py"
printf '\nstale generated copy\n' >> "$tmp/new project/.agents/skills/crew/SKILL.md"
git -C "$tmp/new project" add .
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid commit -qm customization
before=$(git -C "$tmp/new project" rev-parse HEAD)
out=$(bash "$here/agent-team.sh" reset "$tmp/new project" --apply 2>&1); rc=$?
{ [ "$rc" = 0 ] && echo "$out" | grep -q 'CONFLICT .claude/agents/fullstack-dev.md' &&
  echo "$out" | grep -q 'lines only in project' &&
  grep -q 'Project role text' "$tmp/new project/.claude/agents/fullstack-dev.md" &&
  [ "$(cat "$tmp/new project/docs/agents/deploy-facts.md")" = 'product facts' ] &&
  [ "$(cat "$tmp/new project/docs/agents/domain.md")" = 'domain facts' ] &&
  [ "$(cat "$tmp/new project/CONTEXT.md")" = 'domain context' ] &&
  cmp -s "$tmp/new project/.claude/hooks/worker-budget.py" "$DOTFILES/templates/agent-team/.claude/hooks/worker-budget.py" &&
  ! grep -q 'stale generated copy' "$tmp/new project/.agents/skills/crew/SKILL.md" &&
  [ "$(git -C "$tmp/new project" rev-parse HEAD)" = "$before" ]; } && check "reset restores generated files and preserves customized roles and facts without commits" ok || { check "reset restores generated files and preserves customized roles and facts without commits" bad; echo "$out" | tail -6; }
out=$(bash "$here/agent-team.sh" reset "$tmp/new project" --apply 2>&1); rc=$?
{ [ "$rc" != 0 ] && echo "$out" | grep -q 'clean working tree'; } && check "reset refuses dirty tree" ok || check "reset refuses dirty tree" bad
git init -q "$tmp/linked"
mkdir "$tmp/outside"
ln -s "$tmp/outside" "$tmp/linked/.claude"
git -C "$tmp/linked" add .
git -C "$tmp/linked" -c user.name=Test -c user.email=test@example.invalid commit -qm symlink
out=$(bash "$here/agent-team.sh" reset "$tmp/linked" --apply 2>&1); rc=$?
{ [ "$rc" != 0 ] && [ -z "$(ls -A "$tmp/outside")" ]; } && check "reset refuses symlinked managed destinations before writing" ok || check "reset refuses symlinked managed destinations before writing" bad
mkdir -p "$tmp/machine/script" "$tmp/machine-home/.orca" "$tmp/machine/.orca"
echo old > "$tmp/machine-home/.orca/presets.json"
echo template > "$tmp/machine/.orca/presets.json"
for setup in install-agent-clis setup-agent-skills setup-claude-code setup-cursor setup-antigravity setup-orca setup-agent-hooks; do
  cat > "$tmp/machine/script/$setup.sh" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0")" >> "$TEST_SETUP_LOG"
if [ "$(basename "$0")" = setup-orca.sh ]; then
  cp "$DOTFILES/.orca/presets.json" "$HOME/.orca/presets.json"
fi
SH
done
export TEST_SETUP_LOG="$tmp/setup-log"
out=$(HOME="$tmp/machine-home" DOTFILES="$tmp/machine" bash "$here/agent-team.sh" machine 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$tmp/machine-home/.orca/presets.json")" = template ] &&
  grep -q old "$tmp/machine-home/.orca/presets.json".bak.* &&
  [ "$(wc -l < "$TEST_SETUP_LOG" | tr -d ' ')" = 7 ] &&
  echo "$out" | grep -q 'login needed'; } && check "machine composes installers and setup, backs up settings, reports owner login" ok || { check "machine composes installers and setup, backs up settings, reports owner login" bad; echo "$out" | tail -5; }
mkdir -p "$tmp/install-bin" "$tmp/install-home"
cat > "$tmp/install-bin/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$TEST_INSTALL_LOG"
case "$*" in *claude.ai*) tool=claude ;; *cursor.com*) tool=agent ;; *antigravity.google*) tool=agy ;; *) exit 1 ;; esac
printf 'printf "#!/bin/sh\\nexit 0\\n" > "$TEST_BIN/%s"; chmod +x "$TEST_BIN/%s"\n' "$tool" "$tool"
SH
chmod +x "$tmp/install-bin/"*
export TEST_BIN="$tmp/install-bin" TEST_INSTALL_LOG="$tmp/install-log"
out=$(HOME="$tmp/install-home" PATH="$TEST_BIN:/usr/bin:/bin" bash "$here/install-agent-clis.sh" 2>&1); rc=$?
out2=$(HOME="$tmp/install-home" PATH="$TEST_BIN:/usr/bin:/bin" bash "$here/install-agent-clis.sh" 2>&1); rc2=$?
{ [ "$rc$rc2" = 00 ] && [ "$(wc -l < "$TEST_INSTALL_LOG" 2>/dev/null | tr -d ' ')" = 3 ] &&
  [ -x "$TEST_BIN/claude" ] && [ -x "$TEST_BIN/agent" ] && [ -x "$TEST_BIN/agy" ]; } && check "missing provider CLIs install once through stubbed official installers" ok || { check "missing provider CLIs install once through stubbed official installers" bad; echo "$out"; echo "$out2"; }
mkdir -p "$tmp/hook-home/.claude"
printf '{"custom":true,"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"true"}]}]}}\n' > "$tmp/hook-home/.claude/settings.json"
out=$(HOME="$tmp/hook-home" bash "$here/setup-agent-hooks.sh" 2>&1); rc=$?
out2=$(HOME="$tmp/hook-home" bash "$here/setup-agent-hooks.sh" 2>&1); rc2=$?
HOME="$tmp/hook-home" python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / '.claude/settings.json'
d = json.loads(p.read_text())
assert d['custom'] is True
assert len(d['hooks']['PreToolUse']) == 3
assert len(d['hooks']['PostToolUse']) == 1
assert len(list(p.parent.glob('settings.json.bak.*'))) == 1
assert 'usage-gate-hook.py' in p.read_text() and 'worker-budget.py' in p.read_text()
PY
{ [ "$rc$rc2$?" = 000 ]; } && check "hook setup merges once and backs up changed settings" ok || { check "hook setup merges once and backs up changed settings" bad; echo "$out"; echo "$out2"; }
# all must validate the project before any machine mutation, then select reset.
rm -f "$TEST_SETUP_LOG"
out=$(HOME="$tmp/machine-home" DOTFILES="$tmp/machine" bash "$here/agent-team.sh" all "$tmp/new project" --apply 2>&1); rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$TEST_SETUP_LOG" ] && echo "$out" | grep -q 'clean working tree'; } && check "all rejects dirty reset before machine setup" ok || check "all rejects dirty reset before machine setup" bad
out=$(bash "$here/agent-team.sh" project "$tmp/new project" 2>&1); rc=$?
{ [ "$rc" != 0 ] && echo "$out" | grep -q 'use reset'; } && check "project refuses an existing team" ok || check "project refuses an existing team" bad
git -C "$tmp/new project" add .
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid commit -qm refreshed
out=$(bash "$here/agent-team.sh" all "$tmp/new project" --dry-run 2>&1); rc=$?
{ [ "$rc" = 0 ] && echo "$out" | grep -q 'reset preview' && echo "$out" | grep -q 'machine: install-agent-clis.sh' &&
  [ -z "$(git -C "$tmp/new project" status --porcelain)" ]; } && check "all previews machine and automatically resets existing team" ok || check "all previews machine and automatically resets existing team" bad
printf '\n## Token budget\n\nstale budget\n\n## Product policy\n\nkeep product policy\n' > "$tmp/new project/AGENTS.md"
git -C "$tmp/new project" add .
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid commit -qm budget
out=$(bash "$here/agent-team.sh" reset "$tmp/new project" --apply 2>&1); rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'stale budget' "$tmp/new project/AGENTS.md" &&
  grep -q 'keep product policy' "$tmp/new project/AGENTS.md"; } && check "reset refreshes the managed budget and keeps other agent instructions" ok || check "reset refreshes the managed budget and keeps other agent instructions" bad
mkdir -p "$tmp/claude-home/.claude"
echo '{"preserve":true}' > "$tmp/claude-home/.claude/settings.json"
out=$(HOME="$tmp/claude-home" bash "$here/setup-claude-code.sh" --keep-settings 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q preserve "$tmp/claude-home/.claude/settings.json"; } && check "Claude setup can retain composed settings" ok || check "Claude setup can retain composed settings" bad
chmod -x "$tmp/new project/bin/changelog-compile.sh"
git -C "$tmp/new project" add .
git -C "$tmp/new project" -c user.name=Test -c user.email=test@example.invalid commit -qm permissions
out=$(bash "$here/agent-team.sh" reset "$tmp/new project" --apply 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -x "$tmp/new project/bin/changelog-compile.sh" ]; } && check "reset repairs template executable permissions" ok || check "reset repairs template executable permissions" bad
mkdir -p "$tmp/machine/.agents/claude" "$tmp/machine/templates/agent-team/.claude" "$tmp/machine-home/.claude"
echo '{}' > "$tmp/machine/.agents/claude/settings.json"
cp "$DOTFILES/templates/agent-team/.claude/settings.json" "$tmp/machine/templates/agent-team/.claude/settings.json"
cp "$here/setup-agent-hooks.sh" "$tmp/machine/script/setup-agent-hooks.sh"
echo '{"old":true}' > "$tmp/machine-home/.claude/settings.json"
out=$(HOME="$tmp/machine-home" DOTFILES="$tmp/machine" bash "$here/agent-team.sh" machine 2>&1); rc=$?
out2=$(HOME="$tmp/machine-home" DOTFILES="$tmp/machine" bash "$here/agent-team.sh" machine 2>&1); rc2=$?
{ [ "$rc$rc2" = 00 ] && grep -q 'worker-budget.py' "$tmp/machine-home/.claude/settings.json" &&
  [ "$(find "$tmp/machine-home/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = 1 ] &&
  [ "$(cat "$tmp/machine/.agents/claude/settings.json")" = '{}' ]; } && check "machine rerun preserves composed hooks without extra backups or source writes" ok || { check "machine rerun preserves composed hooks without extra backups or source writes" bad; echo "$out"; echo "$out2"; }
out=$(HOME="$tmp/ag-home" PATH="$TEST_BIN:$PATH" bash "$here/setup-antigravity.sh" 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -f "$tmp/ag-home/.gemini/antigravity-cli/settings.json" ] && [ -L "$tmp/ag-home/.gemini/antigravity-cli/skills" ]; } && check "Antigravity CLI alone receives configuration" ok || check "Antigravity CLI alone receives configuration" bad
git init -q "$tmp/audit-project"
git -C "$tmp/audit-project" remote add origin https://github.com/mingster/synthetic.git
# A 1-word budget guarantees a finding independently of canonical role sizes.
out=$(ROLE_WORD_BUDGET=1 bash "$here/agent-team.sh" project "$tmp/audit-project" 2>&1); rc=$?
{ [ "$rc" = 1 ] && grep -qE '[0-9]+ words \(budget 1\)' <<< "$out" && grep -q 'Owner or architect' <<< "$out"; } && check "audit findings fail project setup while still printing owner facts" ok || { check "audit findings fail project setup while still printing owner facts" bad; echo "exit=$rc"; tail -6 <<< "$out"; }
mkdir -p "$tmp/legacy-home" "$tmp/legacy-config"
echo '{"legacy":true}' > "$tmp/legacy-config/settings.json"
ln -s "$tmp/legacy-config" "$tmp/legacy-home/.claude"
out=$(HOME="$tmp/legacy-home" DOTFILES="$tmp/machine" bash "$here/agent-team.sh" machine 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ ! -L "$tmp/legacy-home/.claude" ] &&
  [ "$(cat "$tmp/legacy-config/settings.json")" = '{"legacy":true}' ] &&
  [ -L "$(find "$tmp/legacy-home" -maxdepth 1 -name '.claude.bak.*' | head -1)" ]; } && check "machine backs up legacy Claude directory links without changing their source" ok || check "machine backs up legacy Claude directory links without changing their source" bad
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
