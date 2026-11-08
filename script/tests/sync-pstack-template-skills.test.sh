#!/usr/bin/env bash
# Tests for sync-pstack-template-skills.sh against a fake plugins repo.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
U="$tmp/up"
D="$tmp/dotfiles"
subpath="harness/pstack/claude-code"
mkdir -p "$U/$subpath/skills/benchmark-checklist" \
  "$U/$subpath/skills/poteto-mode" \
  "$D/script" \
  "$D/templates/agent-team/.agents/skills/benchmark-checklist" \
  "$D/templates/agent-team/.agents/skills/poteto-mode"
printf 'upstream benchmark\n' >"$U/$subpath/skills/benchmark-checklist/SKILL.md"
printf 'upstream poteto\n' >"$U/$subpath/skills/poteto-mode/SKILL.md"
git -C "$U" init -q
git -C "$U" add -A
git -C "$U" -c user.name=t -c user.email=t@t commit -qm init
cp "$here/sync-pstack-template-skills.sh" "$D/script/"
chmod +x "$D/script/sync-pstack-template-skills.sh"
printf 'local bench\n' >"$D/templates/agent-team/.agents/skills/benchmark-checklist/SKILL.md"
printf 'orca adapter\n' >"$D/templates/agent-team/.agents/skills/poteto-mode/ORCA-ADAPTER.md"
printf 'old poteto\n' >"$D/templates/agent-team/.agents/skills/poteto-mode/SKILL.md"
printf 'sha=old\nsubpath=%s\nskills=benchmark-checklist poteto-mode\n' "$subpath" \
  >"$D/script/.pstack-template-upstream"
git -C "$D" init -q

pass=0
fail=0
t() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

out=$(DOTFILES="$D" PLUGINS_REPO="$U" "$D/script/sync-pstack-template-skills.sh" 2>&1)
code=$?
t "exits 0" '[ "$code" = 0 ]'
t "copies benchmark-checklist" 'grep -q "upstream benchmark" "$D/templates/agent-team/.agents/skills/benchmark-checklist/SKILL.md"'
t "benchmark-checklist SKILL.md exists" '[ -f "$D/templates/agent-team/.agents/skills/benchmark-checklist/SKILL.md" ]'
t "keeps local ORCA-ADAPTER.md" 'grep -q "orca adapter" "$D/templates/agent-team/.agents/skills/poteto-mode/ORCA-ADAPTER.md"'
t "records the new sha" 'grep -q "^sha=$(git -C "$U" rev-parse HEAD)" "$D/script/.pstack-template-upstream"'
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
