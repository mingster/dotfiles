#!/usr/bin/env bash
# Tests for sync-pstack-template-skills.sh against a fake plugins repo.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
U="$tmp/up"
D="$tmp/dotfiles"
P="$U/harness/pstack/claude-code"
C="$U/cursor-team-kit"
T="$D/templates/agent-team"
mkdir -p "$P/skills/poteto-mode/playbooks" "$P/skills/poteto-mode/scripts" "$P/skills/tdd" "$P/agents" "$P/docs/harness" \
  "$C/skills/deslop" "$C/rules" "$C/agents" "$U/dyl-stack/skills/principle-the-algorithm" "$U/dyl-stack/skills/dyl-mode" \
  "$D/script" "$D/.agents/skills/tdd" "$D/.agents/skills/grilling" \
  "$T/.agents/skills/poteto-mode" "$T/.agents/skills/gone" "$T/.agents/skills/orca-adapter" "$T/.agents/skills/elon"
printf 'upstream poteto\n' >"$P/skills/poteto-mode/SKILL.md"
printf 'orchestrate\n' >"$P/skills/poteto-mode/playbooks/orchestrate.md"
printf '#!/bin/sh\n' >"$P/skills/poteto-mode/scripts/worktree-audit.sh"
printf 'pstack tdd\n' >"$P/skills/tdd/SKILL.md"
printf 'agent\n' >"$P/agents/poteto-agent.md"
printf 'harness\n' >"$P/docs/harness/claude-code.md"
printf 'MIT\n' >"$P/LICENSE"
printf 'deslop\n' >"$C/skills/deslop/SKILL.md"
printf 'rule\n' >"$C/rules/no-inline-imports.mdc"
printf 'ci\n' >"$C/agents/ci-watcher.md"
printf 'MIT\n' >"$C/LICENSE"
printf 'algorithm\n' >"$U/dyl-stack/skills/principle-the-algorithm/SKILL.md"
printf 'not pulled\n' >"$U/dyl-stack/skills/dyl-mode/SKILL.md"
git -C "$U" init -q
git -C "$U" add -A
git -C "$U" -c user.name=t -c user.email=t@t commit -qm init
cp "$here/sync-pstack-template-skills.sh" "$D/script/"
chmod +x "$D/script/sync-pstack-template-skills.sh"
printf 'old poteto\n' >"$T/.agents/skills/poteto-mode/SKILL.md"
printf 'stale\n' >"$T/.agents/skills/poteto-mode/stale.md"
printf 'gone\n' >"$T/.agents/skills/gone/SKILL.md"
printf 'orca adapter\n' >"$T/.agents/skills/orca-adapter/ORCA-ADAPTER.md"
printf 'elon\n' >"$T/.agents/skills/elon/SKILL.md"
printf 'tier1 tdd\n' >"$D/.agents/skills/tdd/SKILL.md"
printf 'grilling\n' >"$D/.agents/skills/grilling/SKILL.md"
printf 'sha=abc\nskills=grilling tdd wizard\n' >"$D/.agents/skills/.mattpocock-upstream"
cat >"$D/script/.pstack-template-upstream" <<'EOF'
sha=old
tree=harness/pstack/claude-code .agents
tree=cursor-team-kit vendor/cursor-team-kit
skill=dyl-stack/skills/principle-the-algorithm
skills=gone poteto-mode
EOF
git -C "$D" init -q

pass=0
fail=0
t() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }
sync() { DOTFILES="$D" PLUGINS_REPO="$U" "$D/script/sync-pstack-template-skills.sh" "$@" 2>&1; }

out=$(sync)
code=$?
t "exits 0" '[ "$code" = 0 ]'
t "pstack skills are exact copies" 'diff -r "$P/skills/poteto-mode" "$T/.agents/skills/poteto-mode" >/dev/null && diff -r "$P/skills/tdd" "$T/.agents/skills/tdd" >/dev/null'
t "pstack files outside skills land under .agents" 'diff -r -x skills "$P" "$T/.agents" >/dev/null'
t "cursor-team-kit skills land in .agents/skills" 'diff -r "$C/skills/deslop" "$T/.agents/skills/deslop" >/dev/null'
t "cursor-team-kit rest lands in vendor" 'diff -r -x skills "$C" "$T/vendor/cursor-team-kit" >/dev/null'
t "single skill entry is copied" 'diff -r "$U/dyl-stack/skills/principle-the-algorithm" "$T/.agents/skills/principle-the-algorithm" >/dev/null'
t "other dyl-stack skills are not pulled" '[ ! -e "$T/.agents/skills/dyl-mode" ]'
t "skill gone upstream is removed" '[ ! -e "$T/.agents/skills/gone" ]'
t "local template skills are untouched" 'grep -q "orca adapter" "$T/.agents/skills/orca-adapter/ORCA-ADAPTER.md" && grep -q elon "$T/.agents/skills/elon/SKILL.md"'
t "upstream replaces a Tier 1 skill of the same name" '[ ! -e "$D/.agents/skills/tdd" ] && grep -q grilling "$D/.agents/skills/grilling/SKILL.md"'
t "replaced Tier 1 skill leaves the Matt Pocock list" 'grep -qx "skills=grilling wizard" "$D/.agents/skills/.mattpocock-upstream"'
t "records the new sha" 'grep -q "^sha=$(git -C "$U" rev-parse HEAD)$" "$D/script/.pstack-template-upstream"'
t "records the vendored skill names" 'grep -qx "skills=deslop poteto-mode principle-the-algorithm tdd" "$D/script/.pstack-template-upstream"'
t "keeps the hand edited entries" '[ "$(grep -c "^tree=" "$D/script/.pstack-template-upstream")" = 2 ]'

git -C "$D" add -A
git -C "$D" -c user.name=t -c user.email=t@t commit -qm synced
out=$(sync)
t "second run on the same sha changes nothing" '[ -z "$(git -C "$D" status --porcelain)" ]'

mkdir -p "$U/cursor-team-kit/skills/elon"
printf 'upstream elon\n' >"$U/cursor-team-kit/skills/elon/SKILL.md"
git -C "$U" add -A
git -C "$U" -c user.name=t -c user.email=t@t commit -qm elon
out=$(sync)
code=$?
t "refuses to replace a local template skill" '[ "$code" != 0 ] && grep -q elon "$T/.agents/skills/elon/SKILL.md" && echo "$out" | grep -q "local template skill"'
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
