#!/usr/bin/env bash
# Every skill the account synced mattpocock-skills plugin offers has a dotfiles folder, and no skill
# name sits in both .agents/skills and templates/agent-team/.agents/skills (#1801).
here=$(cd "$(dirname "$0")/../.." && pwd)
T1="$here/.agents/skills"
TM="$here/templates/agent-team/.agents/skills"
pass=0; fail=0
t() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

for n in diagnosing-bugs tdd prototype research domain-modeling codebase-design code-review \
  resolving-merge-conflicts wizard grilling writing-for-agents; do
  t "plugin skill $n has a dotfiles folder" '[ -f "$T1/$n/SKILL.md" ] || [ -f "$TM/$n/SKILL.md" ]'
done

clash=$(comm -12 <(ls "$T1" | sort) <(ls "$TM" | sort))
t "no skill name in both trees" '[ -z "$clash" ]'
[ -z "$clash" ] || echo "     clash: $clash"

t "tdd is the upstream red green loop (Tier 1)" '[ -f "$T1/tdd/SKILL.md" ] && [ -f "$T1/tdd/tests.md" ] && [ -f "$T1/tdd/mocking.md" ] && [ -d "$T1/tdd/agents" ]'
t "tdd is not the pstack bug fix skill" '[ ! -e "$TM/tdd" ]'
t "pstack bug fix skill is tdd-bugfix" 'grep -qx "name: tdd-bugfix" "$TM/tdd-bugfix/SKILL.md"'
t "tdd name matches its folder" 'grep -qx "name: tdd" "$T1/tdd/SKILL.md"'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
