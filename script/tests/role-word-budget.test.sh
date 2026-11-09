#!/usr/bin/env bash
# Every template role file stays within the team-audit word budget, keeps its key rules,
# and each docs/agents pointer it names exists in the template.
here=$(cd "$(dirname "$0")/../.." && pwd)
T="$here/templates/agent-team"
BUDGET="${ROLE_WORD_BUDGET:-800}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

for f in "$T"/.claude/agents/*.md; do
  n=$(wc -w < "$f" | tr -d ' ')
  if [ "$n" -le "$BUDGET" ]; then ok "$(basename "$f") within budget ($n)"; else bad "$(basename "$f") $n words (budget $BUDGET)"; fi
done

# Moved detail must still be reachable: role file names the doc, the doc holds the detail.
has() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3"; }
has "$T/docs/agents/coordinator-operations.md" 'workspace-trusted' "cursor trust marker lives in coordinator-operations"
has "$T/docs/agents/deploy-facts.md" 'Host preflight' "host preflight lives in deploy-facts"
has "$T/docs/agents/release-manager-work.md" 'Production job order' "release-manager-work holds the production job order pointer"
has "$T/docs/agents/coordinator-operations.md" 'Small task method' "small task method lives in coordinator-operations"
has "$T/docs/agents/release-manager-work.md" 'Host preflight' "release-manager-work still names host preflight"

# Rules that must survive the trim.
has "$T/.claude/agents/release-manager.md" 'Never roll back production without owner authorization' "rm keeps rollback guard"
has "$T/.claude/agents/release-manager.md" 'Never invoke `bin/owner-approve.sh`' "rm keeps owner-approve guard"
has "$T/.claude/agents/release-manager.md" 'Never stop a process by name' "rm keeps kill guard"
has "$T/.claude/agents/elon.md" 'lead-merge.sh' "elon keeps lead-merge rule"
has "$T/docs/agents/engineering-integration.md" 'One writer per branch' "merge rules keep one writer rule"
has "$T/.claude/agents/elon.md" 'Owner-Reserved' "elon keeps owner-reserved list"
has "$T/.claude/agents/elon.md" 'Traditional Chinese' "elon keeps owner language rule"
has "$T/.claude/agents/elon.md" 'team-grill-backlog' "elon keeps backlog sweep"

# Every docs/agents/<file>.md named in a role file exists, and team docs point at ~/dotfiles/templates/agent-team/docs/agents/.
for f in "$T"/.claude/agents/*.md; do
  for p in $(grep -oE '(~/dotfiles/(templates/agent-team/)?)?docs/agents/[a-z0-9-]+\.md' "$f" | sort -u); do
    rel=${p#"~/dotfiles/templates/agent-team/"}
    rel=${rel#"~/dotfiles/"}
    [ -f "$T/$rel" ] || [ -f "$here/$rel" ] || bad "$(basename "$f") names missing $rel"
    case "$rel" in
      docs/agents/issue-tracker.md|docs/agents/triage-labels.md|docs/agents/domain.md|docs/agents/team-facts.md|docs/agents/deploy-facts.md)
        [ "$p" = "$rel" ] && ok "$(basename "$f") keeps project path $rel" || bad "$(basename "$f") must keep project path $rel (got $p)" ;;
      *)
        # Dotfiles' own docs/agents files (not part of the template) keep the ~/dotfiles/ path.
        if [ "$p" = "~/dotfiles/$rel" ] && [ ! -f "$T/$rel" ] && [ -f "$here/$rel" ]; then ok "$(basename "$f") points at dotfiles $rel"; continue; fi
        [ "$p" = "~/dotfiles/templates/agent-team/$rel" ] && ok "$(basename "$f") points at template $rel" || bad "$(basename "$f") points at project $p instead of ~/dotfiles/templates/agent-team/$rel" ;;
    esac
  done
done

# Every skill in templates/agent-team/.agents/skills/ points at ~/dotfiles/templates/agent-team/docs/agents/<file> for the 9 team docs.
if grep -rnE '(^|[^/])docs/agents/(team|coordinator-operations|engineering-integration|architect-pm-work|elon-dispatch|qa-sdet-execution|release-manager-work|persistent-memory-protocol|pstack-attribution)\.md' "$T/.agents/skills" >/dev/null; then
  bad "template skills still point at project copies of team docs"
else
  ok "template skills point at ~/dotfiles/templates/agent-team/docs/agents/ for team docs"
fi

# Adoption seeds only team-facts.md and deploy-facts.md under docs/agents/ (preserving existing files) and copies no team docs.
A=$(mktemp -d); trap 'rm -rf "$A"' EXIT
mkdir -p "$A/proj/docs/agents"; echo "# project owned" > "$A/proj/docs/agents/deploy-facts.md"
git -C "$A/proj" init -q
DOTFILES="$here" bash "$here/script/agent-team.sh" project "$A/proj" --project-name acme >/dev/null 2>&1
[ -f "$A/proj/docs/agents/team-facts.md" ] && [ "$(cat "$A/proj/docs/agents/deploy-facts.md")" = "# project owned" ] \
  && ok "adoption seeds team-facts.md and preserves deploy-facts.md" \
  || bad "adoption failed to seed team-facts.md or preserve deploy-facts.md"
# agent-team.sh syncs team.md, elon-dispatch.md and release-manager-work.md into projects (TEMPLATE_SYNC_FILES); the rest stay in the template.
for d in coordinator-operations.md engineering-integration.md architect-pm-work.md qa-sdet-execution.md persistent-memory-protocol.md pstack-attribution.md; do
  [ ! -e "$A/proj/docs/agents/$d" ] && ok "adoption does not copy $d" || bad "adoption still copies $d into project docs/agents/"
done
has "$T/docs/agents/coordinator-operations.md" 'Production job order' "template coordinator-operations holds the production job order"
has "$T/docs/agents/release-manager-work.md" 'coordinator-operations.md`, Production job order' "release-manager-work points the job order at coordinator-operations"
has "$T/.claude/agents/release-manager.md" '~/dotfiles/templates/agent-team/docs/agents/release-manager-work.md' "release-manager role file points at template release-manager-work"
has "$T/.claude/agents/qa-sdet.md" '~/dotfiles/templates/agent-team/docs/agents/qa-sdet-execution.md' "qa-sdet role file points at template qa-sdet-execution"
has "$T/docs/agents/engineering-integration.md" 'even a new spec no worker could run' "merge rules keep rerun of a new spec"
has "$T/docs/agents/coordinator-operations.md" '{{PROJECT_NAME}}/<lane>' "small task method keeps the project placeholder"
has "$T/docs/agents/team.md" 'team-facts.md` only' "template team.md says project differences go in team-facts.md only"
has "$T/docs/agents/team-facts.md" 'team-facts.md` only' "template team-facts.md says project differences go in team-facts.md only"

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
