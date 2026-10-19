#!/usr/bin/env bash
# Asserts the release guard rules (issue mingster/projb#563) are in the release-manager role file and the deploy skill.
# Text assertions only: the guard hooks are not driven here. Run: bash THIS [<root>]
set -u
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$ROOT/.claude/agents/release-manager.md" ] || ROOT="$ROOT/templates/agent-team"
ROLE="$ROOT/.claude/agents/release-manager.md"; SKILL="$ROOT/.agents/skills/deploy/SKILL.md"
fail=0; n=0
has() { n=$((n+1)); if grep -qF -- "$3" "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
for f in "$ROLE" "$SKILL"; do
  b="$(basename "$(dirname "$f")")/$(basename "$f")"
  has "$f" "$b: bans owner-approve status/help/version" 'Never invoke `bin/owner-approve.sh` in any form'
  has "$f" "$b: names status, help, version" 'version'
  has "$f" "$b: bans writing the approval file" 'approval file'
  has "$f" "$b: denial is terminal stop-and-report" 'terminal stop-and-report'
  has "$f" "$b: no reformulate or retry" 'reformulate'
  has "$f" "$b: owner scope grants no discretion" 'discretion'
  has "$f" "$b: literal component and SHA, no variables" '$S'
  has "$f" "$b: backup + RESTORE VERIFYONLY" 'RESTORE VERIFYONLY'
  has "$f" "$b: once-only ledger" 'once-only ledger'
  has "$f" "$b: approval file integrity" 'integrity'
  has "$f" "$b: host SHA, HTTP, mobile evidence" 'HTTP and mobile evidence'
done
has "$SKILL" "deploy skill: release brief rules section" '## Release brief rules'
has "$SKILL" "deploy skill: brief tells Elon and TL to copy rules" 'Elon and the Tech Lead copy these into every release dispatch brief'
echo "$n checks"; exit $fail
