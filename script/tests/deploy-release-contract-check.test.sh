#!/usr/bin/env bash
# The deploy skill runs a configured release contract check before it asks for the owner's go (#1764).
# Text assertions only: the skill is prose that release-manager follows. Run: bash THIS [<root>]
set -u
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "$ROOT/.agents/skills/deploy/SKILL.md" ] || ROOT="$ROOT/templates/agent-team"
SKILL="$ROOT/.agents/skills/deploy/SKILL.md";
fail=0; n=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
has() { grep -qF -- "$3" "$1"; ok $? "$2"; }
line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

has "$SKILL" "skill names the check heading" '`## Release contract check`'
has "$SKILL" "non-zero exit stops and reports the contract file" 'A non-zero exit stops the flow'
has "$SKILL" "no approval request for a failing release" 'do not ask for the go'
has "$SKILL" "no check configured changes nothing" 'With no such heading or command, skip this step; nothing else changes.'

c=$(line "$SKILL" '- **Release contract check.**'); s=$(line "$SKILL" '- **Production summary**'); g=$(line "$SKILL" '- **User go.**')
[ -n "$c" ] && [ -n "$s" ] && [ -n "$g" ] && [ "$c" -lt "$s" ] && [ "$s" -lt "$g" ]; ok $? "check comes before the summary and the user go"
st=$(line "$SKILL" 'run the production release contract check first, then send')
[ -n "$st" ]; ok $? "staging success message runs the check before asking"
echo "$n checks"; exit $fail
