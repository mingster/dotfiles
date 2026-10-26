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
has "$T/.claude/agents/tech-lead.md" 'Cursor worker start' "tech-lead points at the cursor worker start rule"
has "$T/docs/agents/deploy-facts.md" 'Host preflight' "host preflight lives in deploy-facts"
has "$T/docs/agents/deploy-facts.md" 'Production job order' "production job order lives in deploy-facts"
has "$T/.claude/agents/release-manager.md" 'Production job order' "release-manager points at the production job order"
has "$T/docs/agents/coordinator-operations.md" 'Small task method' "small task method lives in coordinator-operations"
has "$T/.claude/agents/release-manager.md" 'Host preflight' "release-manager still names host preflight"

# Rules that must survive the trim.
has "$T/.claude/agents/release-manager.md" 'Never roll back production without owner authorization' "rm keeps rollback guard"
has "$T/.claude/agents/release-manager.md" 'Never invoke `bin/owner-approve.sh`' "rm keeps owner-approve guard"
has "$T/.claude/agents/release-manager.md" 'Never stop a process by name' "rm keeps kill guard"
has "$T/.claude/agents/tech-lead.md" 'lead-merge.sh' "tl keeps lead-merge rule"
has "$T/.claude/agents/tech-lead.md" 'One writer per branch' "tl keeps one writer rule"
has "$T/.claude/agents/tech-lead.md" 'never pass 200 calls' "tl keeps handoff cap" 
has "$T/.claude/agents/elon.md" 'Owner-Reserved' "elon keeps owner-reserved list"
has "$T/.claude/agents/elon.md" 'Traditional Chinese' "elon keeps owner language rule"
has "$T/.claude/agents/elon.md" 'team-grill-backlog' "elon keeps backlog sweep"

# Every docs/agents/<file>.md named in a role file exists.
for f in "$T"/.claude/agents/*.md; do
  for p in $(grep -oE 'docs/agents/[a-z0-9-]+\.md' "$f" | sort -u); do
    [ -f "$T/$p" ] || [ -f "$here/$p" ] || bad "$(basename "$f") names missing $p"
  done
done

# Adoption installs every template doc a role names, even when the project already has deploy-facts.md.
A=$(mktemp -d); trap 'rm -rf "$A"' EXIT
mkdir -p "$A/proj/docs/agents"; echo "# project owned" > "$A/proj/docs/agents/deploy-facts.md"
DOTFILES="$here" bash "$here/script/adopt-agent-team.sh" --project-name acme "$A/proj" >/dev/null 2>&1
for f in "$T"/.claude/agents/*.md; do
  for p in $(grep -oE 'docs/agents/[a-z0-9-]+\.md' "$f" | sort -u); do
    [ -f "$T/$p" ] || continue
    case "$p" in */team.md|*/team-facts.md|*/deploy-facts.md) continue ;; esac
    [ -f "$A/proj/$p" ] && ok "adoption installs $p" || bad "$(basename "$f") names $p but adoption does not install it"
  done
done
# Rules that moved behind a pointer must be in an always installed page, not the project owned deploy-facts.
has "$A/proj/docs/agents/coordinator-operations.md" 'Production job order' "adopted coordinator-operations holds the production job order"
has "$T/.claude/agents/release-manager.md" 'coordinator-operations.md`, Production job order' "release-manager points the job order at coordinator-operations"
has "$T/.claude/agents/tech-lead.md" 'even a new spec no worker could run' "tech-lead keeps rerun of a new spec"
has "$T/docs/agents/coordinator-operations.md" '{{PROJECT_NAME}}/<lane>' "small task method keeps the project placeholder"
has "$A/proj/docs/agents/coordinator-operations.md" 'workspaces/acme/<lane>' "adopted small task method renders the project name"

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
