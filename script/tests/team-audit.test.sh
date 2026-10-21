#!/usr/bin/env bash
# Tests for team-audit.sh against a fake dotfiles tree and a fake project.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
D="$tmp/dotfiles" P="$tmp/proj"

setup() { # a clean dotfiles tree and a project synced from it
  rm -rf "$D" "$P"
  mkdir -p "$D/script" "$D/templates/agent-team/.claude/agents" "$D/templates/agent-team/.agents/skills/crew" \
           "$D/.agents/skills/orca-team" "$P/.claude/agents" "$P/docs/agents"
  cp "$here/sync-team-skills.sh" "$D/script/"
  printf -- '---\nname: crew\ndescription: Crew protocol.\n---\n\nThe Tech Lead pushes and merges.\n' > "$D/templates/agent-team/.agents/skills/crew/SKILL.md"
  printf -- '---\nname: orca-team\ndescription: Orca workers.\n---\n' > "$D/.agents/skills/orca-team/SKILL.md"
  for h in worker-panes.sh worker-pane.sh worker-pane-close.sh worker-pane-retry.sh worker-watch.sh role-colors.tsv; do
    touch "$D/.agents/skills/orca-team/$h"
  done
  printf '{"version": 3, "skills": {"orca-cli": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
  printf -- '---\nname: tech-lead\n---\nYou integrate branches and report to Elon.\n' > "$P/.claude/agents/tech-lead.md"
  printf 'The Tech Lead merges every PR.\n' > "$P/docs/agents/team.md"
  DOTFILES="$D" "$D/script/sync-team-skills.sh" "$P" >/dev/null 2>&1
  mkdir -p "$D/.agents/skills/tdd"; printf -- '---\nname: tdd\ndescription: Test first.\n---\n' > "$D/.agents/skills/tdd/SKILL.md"
  printf 'sha=aaa1111\nskills=tdd research\n' > "$D/.agents/skills/.mattpocock-upstream"
  GH_LATEST=aaa1111 GH_FILES="" GH_FAIL=""
}

# Fake gh on PATH: commits/main prints $GH_LATEST, compare prints $GH_FILES, GH_FAIL makes both fail.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
[ -n "$GH_FAIL" ] && exit 1
case "$2" in
  */commits/main) echo "$GH_LATEST" ;;
  */compare/*) printf '%s' "$GH_FILES" ;;
esac
EOS
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

pass=0; fail=0
check() { # name expected_exit output_regex
  out=$(DOTFILES="$D" "$here/team-audit.sh" "$P" 2>&1); code=$?
  if [ "$code" = "$2" ] && echo "$out" | grep -qE "$3"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1 (exit $code)"; echo "$out"; fi
}

setup
check "clean tree passes" 0 'team-audit: clean'

setup; echo 'When a review passes, the Tech Lead merges it.' >> "$P/docs/agents/team.md"
check "lead merging is allowed" 0 'team-audit: clean'

setup; echo 'sales pushes its branch.' >> "$P/docs/agents/team.md"
check "sales pushing is banned" 1 'FINDING wording: .*team.md'

setup; echo 'Then release-manager opens the PR.' >> "$P/.claude/agents/tech-lead.md"
check "a role opening a PR is banned" 1 'FINDING wording: .*tech-lead.md'

setup; echo 'fullstack-dev merges `main` into the branch.' >> "$P/docs/agents/team.md"
check "merging main into a branch is allowed" 0 'team-audit: clean'

setup; echo 'Keep task_plan.md current.' >> "$P/docs/agents/team.md"
check "task_plan ledger is banned" 1 'FINDING wording: .*task_plan'

setup; echo 'Run orca claude-teams for panes.' >> "$P/docs/agents/team.md"
check "old pane layout is banned" 1 'FINDING wording: .*claude-teams'

setup; echo 'Light tier: codex gpt-6-luna low.' >> "$P/.claude/model-routing.md"
check "retired luna model is banned" 1 'FINDING wording: .*model-routing.md'

setup; echo 'Wait with `check --wait --types worker_done,escalation --timeout-ms 900000`.' >> "$P/docs/agents/team.md"
check "a wait filter without status is banned" 1 'FINDING wording: .*team.md'

setup; echo 'Wait with `check --wait --types worker_done,escalation,status --timeout-ms 900000`.' >> "$P/docs/agents/team.md"
check "a wait filter with status is allowed" 0 'team-audit: clean'

setup; echo 'The lead merges it. <!-- team-audit: allow -->' >> "$P/docs/agents/team.md"
check "allow comment opts a line out" 0 'team-audit: clean'

setup; echo 'hand edit' >> "$P/.agents/skills/crew/SKILL.md"
check "hand edited team skill fails the sync check" 1 'FINDING sync: '

setup; yes word | head -900 | tr '\n' ' ' >> "$P/.claude/agents/tech-lead.md"
check "role file over budget" 1 'FINDING budget: .*tech-lead.md: 9[0-9][0-9] words'

setup; mkdir -p "$D/.agents/skills/bare"; printf -- '---\nname: bare\n---\n' > "$D/.agents/skills/bare/SKILL.md"
check "skill without description" 1 'FINDING skill: .*bare/SKILL.md: no description'

setup; printf '{"version": 3, "skills": {"orchestration": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
check "official orchestration may be tracked" 0 'team-audit: clean'

setup; printf '{"version": 3, "skills": {"orca-team": {"source": "stablyai/orca"}}}\n' > "$D/.agents/.skill-lock.json"
check "lock tracking our orca-team" 1 'FINDING lock: .*tracks orca-team'

setup; rm "$D/.agents/skills/orca-team/worker-panes.sh"
check "missing orca-team helper" 1 'FINDING helpers: missing .*worker-panes.sh'

setup; rm "$D/.agents/skills/orca-team/worker-pane-retry.sh"
check "missing pane retry helper" 1 'FINDING helpers: missing .*worker-pane-retry.sh'

setup; GH_LATEST=bbb2222 GH_FILES=$'skills/engineering/tdd/SKILL.md\nREADME.md\n'; export GH_LATEST GH_FILES
check "upstream changed a vendored skill" 1 'FINDING mp-upstream: aaa1111 behind bbb2222: tdd'

setup; GH_LATEST=bbb2222 GH_FILES=$'skills/engineering/triage/SKILL.md\nREADME.md\n'; export GH_LATEST GH_FILES
check "upstream changed only other skills" 0 'team-audit: clean'

setup; GH_FAIL=1; export GH_FAIL
check "gh failure is a warning only" 0 'WARN mp-upstream'
unset GH_FAIL GH_LATEST GH_FILES

setup; rm "$D/.agents/skills/tdd/SKILL.md"; printf -- '---\nname: dev\nskills: [tdd, orchestration]\n---\nbody\n' > "$D/templates/agent-team/.claude/agents/dev.md"
check "role names a missing Matt Pocock skill" 1 'FINDING mp-upstream: .*dev.md: skills: names tdd'

setup; printf -- '---\nname: dev\nskills: [tdd, orchestration]\n---\nbody\n' > "$D/templates/agent-team/.claude/agents/dev.md"
check "role skills all present" 0 'team-audit: clean'

setup; mkdir -p "$P/docs/intent/2026-10-21-tier"; echo spec > "$P/docs/intent/2026-10-21-tier/spec.md"
check "spec without intent.md" 1 'FINDING sdlc: .*2026-10-21-tier/spec.md: no intent.md'

setup; mkdir -p "$P/docs/intent/2026-10-21-tier"; printf 'spec\n\n## Test plan\n1. case\n' > "$P/docs/intent/2026-10-21-tier/spec.md"; echo intent > "$P/docs/intent/2026-10-21-tier/intent.md"
check "spec beside its intent.md" 0 'team-audit: clean'

setup; mkdir -p "$P/docs/intent/2026-10-22-tier"; echo spec > "$P/docs/intent/2026-10-22-tier/spec.md"; echo intent > "$P/docs/intent/2026-10-22-tier/intent.md"
check "new spec without a Test plan" 1 'FINDING sdlc: .*2026-10-22-tier/spec.md: no ## Test plan'

setup; mkdir -p "$P/docs/intent/2026-10-09-old"; echo spec > "$P/docs/intent/2026-10-09-old/spec.md"
( cd "$P" && git init -q && git add -A && GIT_AUTHOR_DATE=2026-10-09T00:00:00Z GIT_COMMITTER_DATE=2026-10-09T00:00:00Z git -c user.name=t -c user.email=t@t commit -qm old )
check "spec committed before the rule is grandfathered" 0 'team-audit: clean'

setup; rm "$D/.agents/skills/.mattpocock-upstream"
check "missing upstream record" 1 'FINDING mp-upstream: missing'

setup
out=$(DOTFILES="$D" "$here/team-audit.sh" --bogus 2>&1); code=$?
if [ "$code" = 2 ]; then pass=$((pass+1)); echo "ok   unknown flag is a usage error"; else fail=$((fail+1)); echo "FAIL unknown flag (exit $code)"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
