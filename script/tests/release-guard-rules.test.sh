#!/usr/bin/env bash
# Release guard rules (mingster/pstv#563): the templates carry them, and sync-team-skills.sh keeps them in a project.
# Text assertions only; the guard hooks are not driven. Run: bash script/tests/release-guard-rules.test.sh
set -u
D="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
bash "$D/script/tests/release-guard-rules.sh" "$D/templates/agent-team" >/dev/null || { echo "FAIL templates miss a rule"; fail=1; }
git -C "$T" init -q
mkdir -p "$T/.claude/agents"; cp "$D/templates/agent-team/.claude/agents/release-manager.md" "$T/.claude/agents/"
DOTFILES="$D" bash "$D/script/sync-team-skills.sh" "$T" >/dev/null || { echo "FAIL sync"; fail=1; }
bash "$D/script/tests/release-guard-rules.sh" "$T" >/dev/null || { echo "FAIL synced project misses a rule"; fail=1; }
DOTFILES="$D" bash "$D/script/sync-team-skills.sh" --check "$T" >/dev/null || { echo "FAIL sync --check"; fail=1; }
[ $fail -eq 0 ] && echo "ok   templates and synced project carry the release guard rules"
exit $fail
