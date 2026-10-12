#!/usr/bin/env bash
# Tests for sync-mattpocock-skills.sh against a fake upstream git repo.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
U="$tmp/up" D="$tmp/dotfiles"
mkdir -p "$U/skills/engineering/tdd" "$U/skills/engineering/domain-modeling" "$D/script" "$D/.agents/skills/tdd" "$D/.agents/skills/mine"
printf 'new tdd\n' > "$U/skills/engineering/tdd/SKILL.md"
printf 'see GLOSSARY.md\n' > "$U/skills/engineering/domain-modeling/SKILL.md"
printf 'format\n' > "$U/skills/engineering/domain-modeling/GLOSSARY-FORMAT.md"
git -C "$U" init -q && git -C "$U" add -A && git -C "$U" -c user.name=t -c user.email=t@t commit -qm init
cp "$here/sync-mattpocock-skills.sh" "$D/script/"
printf 'old tdd\n' > "$D/.agents/skills/tdd/SKILL.md"; printf 'mine\n' > "$D/.agents/skills/mine/SKILL.md"
printf 'sha=old\nskills=tdd domain-modeling gone\n' > "$D/.agents/skills/.mattpocock-upstream"
git -C "$D" init -q

pass=0; fail=0
t() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
out=$(DOTFILES="$D" MP_REPO="$U" "$D/script/sync-mattpocock-skills.sh" 2>&1); code=$?
t "exits 0" '[ "$code" = 0 ]'
t "copies upstream content" 'grep -q "new tdd" "$D/.agents/skills/tdd/SKILL.md"'
t "keeps CONTEXT naming" 'grep -q "CONTEXT.md" "$D/.agents/skills/domain-modeling/SKILL.md" && [ -f "$D/.agents/skills/domain-modeling/CONTEXT-FORMAT.md" ]'
t "never touches a local only skill" 'grep -q mine "$D/.agents/skills/mine/SKILL.md"'
t "records the new sha" 'grep -q "^sha=$(git -C "$U" rev-parse HEAD)" "$D/.agents/skills/.mattpocock-upstream"'
t "warns on a skill gone upstream" 'echo "$out" | grep -q "WARN gone"'
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
