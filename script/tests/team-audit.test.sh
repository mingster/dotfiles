#!/usr/bin/env bash
# Tests for team-audit.sh against a fake dotfiles tree and a fake project.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
D="$tmp/dotfiles" P="$tmp/proj"

setup() { # a clean dotfiles tree and a project synced from it
  rm -rf "$D" "$P"
  mkdir -p "$D/script" "$D/templates/agent-team/.claude/agents" "$D/templates/agent-team/.agents/skills/crew" \
           "$D/.agents/skills/orchestration" "$P/.claude/agents" "$P/docs/agents"
  cp "$here/sync-team-skills.sh" "$D/script/"
  printf -- '---\nname: crew\ndescription: Crew protocol.\n---\n\nElon pushes and merges.\n' > "$D/templates/agent-team/.agents/skills/crew/SKILL.md"
  printf -- '---\nname: orchestration\ndescription: Orca workers.\n---\n' > "$D/.agents/skills/orchestration/SKILL.md"
  for h in worker-panes.sh worker-pane.sh worker-pane-close.sh worker-watch.sh role-colors.tsv; do
    touch "$D/.agents/skills/orchestration/$h"
  done
  printf '{"version": 3, "skills": {"orca-cli": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
  printf -- '---\nname: lead\n---\nYou integrate branches and report to Elon.\n' > "$P/.claude/agents/tech-lead.md"
  printf 'Elon merges every PR.\n' > "$P/docs/agents/team.md"
  DOTFILES="$D" "$D/script/sync-team-skills.sh" "$P" >/dev/null 2>&1
}

pass=0; fail=0
check() { # name expected_exit output_regex
  out=$(DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1 (exit $code)"; echo "$out"; fi
}

setup
check "clean tree passes" 0 'team-audit: clean'

setup; echo 'When a review passes, the Tech Lead merges it.' >> "$P/docs/agents/team.md"
check "lead merging is banned" 1 'FINDING wording: .*team.md'

setup; echo 'Then release-manager opens the PR.' >> "$P/.claude/agents/tech-lead.md"
check "a role opening a PR is banned" 1 'FINDING wording: .*tech-lead.md'

setup; echo 'fullstack-dev merges `main` into the branch.' >> "$P/docs/agents/team.md"
check "merging main into a branch is allowed" 0 'team-audit: clean'

setup; echo 'Keep task_plan.md current.' >> "$P/docs/agents/team.md"
check "task_plan ledger is banned" 1 'FINDING wording: .*task_plan'

setup; echo 'Run orca claude-teams for panes.' >> "$P/docs/agents/team.md"
check "old pane layout is banned" 1 'FINDING wording: .*claude-teams'

setup; echo 'The lead merges it. <!-- team-audit: allow -->' >> "$P/docs/agents/team.md"
check "allow comment opts a line out" 0 'team-audit: clean'

setup; echo 'hand edit' >> "$P/.agents/skills/crew/SKILL.md"
check "hand edited team skill fails the sync check" 1 'FINDING sync: '

setup; yes word | head -900 | tr '\n' ' ' >> "$P/.claude/agents/tech-lead.md"
check "role file over budget" 1 'FINDING budget: .*tech-lead.md: 9[0-9][0-9] words'

setup; mkdir -p "$D/.agents/skills/bare"; printf -- '---\nname: bare\n---\n' > "$D/.agents/skills/bare/SKILL.md"
check "skill without description" 1 'FINDING skill: .*bare/SKILL.md: no description'

setup; printf '{"version": 3, "skills": {"orchestration": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
check "lock tracking orchestration" 1 'FINDING lock: .*tracks orchestration'

setup; rm "$D/.agents/skills/orchestration/worker-panes.sh"
check "missing orchestration helper" 1 'FINDING helpers: missing .*worker-panes.sh'

setup
out=$(DOTFILES="$D" "$here/team-audit.sh" --bogus 2>&1); code=$?
if [ "$code" = 2 ]; then pass=$((pass+1)); echo "ok   unknown flag is a usage error"; else fail=$((fail+1)); echo "FAIL unknown flag (exit $code)"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
