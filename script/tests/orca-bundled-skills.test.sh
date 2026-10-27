#!/usr/bin/env bash
# Orca owns its bundled skills: setup installs them through orca, the collision check rejects copies.
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
has() { grep -q -- "$1" "$2"; }
lacks() { ! grep -q -- "$1" "$2"; }

# Fake orca: `skills list` prints bundled names, `skills install` logs its arguments.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  "skills list") printf 'orca-cli: Operate worktrees.\nbundled-one: Something.\n' ;;
  "skills install") echo "$*" >> "$ORCA_LOG" ;;
esac
EOS
chmod +x "$tmp/bin/orca"
# PATH without any real orca, with only the tools the scripts need.
base_path="/usr/bin:/bin"
export ORCA_LOG="$tmp/orca.log"

# Fixture dotfiles tree: one tracked skill, one untracked skill named like an Orca bundled one.
D="$tmp/dotfiles"
mkdir -p "$D/.agents/skills/tdd" "$D/.agents/skills/bundled-one"
echo tdd > "$D/.agents/skills/tdd/SKILL.md"
echo shadow > "$D/.agents/skills/bundled-one/SKILL.md"
git -C "$D" init -q
git -C "$D" add -f .agents/skills/tdd/SKILL.md .agents/skills/bundled-one/SKILL.md

# 1. setup with orca: install --all runs, bundled names never linked.
export HOME="$tmp/home1"; mkdir -p "$HOME"
PATH="$tmp/bin:$base_path" DOTFILES="$D" bash "$ROOT/script/setup-agent-skills.sh" > "$tmp/setup1.out" 2>&1
check "setup runs orca skills install --all" has 'skills install --all' "$ORCA_LOG"
check "setup links dotfiles skill" test -L "$HOME/.claude/skills/tdd"
check "setup never links a bundled name" test ! -e "$HOME/.claude/skills/bundled-one"

# 2. setup without orca: one line, still links, exit 0.
export HOME="$tmp/home2"; mkdir -p "$HOME"
PATH="$base_path" DOTFILES="$D" bash "$ROOT/script/setup-agent-skills.sh" > "$tmp/setup2.out" 2>&1
check "setup without orca exits 0 and links" test -L "$HOME/.claude/skills/tdd"
check "setup without orca prints one line" test "$(grep -c 'orca not found' "$tmp/setup2.out")" -eq 1

# 3. collision check: dotfiles set holding a bundled name fails.
out="$tmp/coll1.out"
PATH="$tmp/bin:$base_path" DOTFILES="$D" bash "$ROOT/script/check-skill-collisions.sh" "$tmp/noroot" > "$out" 2>&1; rc=$?
check "collision check fails on bundled name in dotfiles" test "$rc" -eq 1
check "collision output names the skill" has 'bundled-one' "$out"

# 4. project skill set holding a bundled name fails.
rm -rf "$D/.agents/skills/bundled-one"
P="$tmp/proj"; mkdir -p "$P/.claude/skills/orca-cli"; echo x > "$P/.claude/skills/orca-cli/SKILL.md"
out="$tmp/coll2.out"
PATH="$tmp/bin:$base_path" DOTFILES="$D" bash "$ROOT/script/check-skill-collisions.sh" "$P" > "$out" 2>&1; rc=$?
check "collision check fails on bundled name in project" test "$rc" -eq 1
check "project failure mentions orca bundles it" has 'bundled by orca' "$out"

# 5. clean sets pass.
rm -rf "$P/.claude/skills/orca-cli"; mkdir -p "$P/.claude/skills/mine"; echo x > "$P/.claude/skills/mine/SKILL.md"
out="$tmp/coll3.out"
PATH="$tmp/bin:$base_path" DOTFILES="$D" bash "$ROOT/script/check-skill-collisions.sh" "$P" > "$out" 2>&1; rc=$?
check "clean sets pass" test "$rc" -eq 0

# 6. orca missing: WARN, rule skipped, exit 0.
out="$tmp/coll4.out"
PATH="$base_path" DOTFILES="$D" bash "$ROOT/script/check-skill-collisions.sh" "$P" > "$out" 2>&1; rc=$?
check "missing orca warns and passes" test "$rc" -eq 0
check "missing orca prints WARN" has 'WARN.*orca' "$out"

# 7. orca only at $HOME/.orca/cli/bin/orca (not on PATH): both scripts use it.
export HOME="$tmp/home3"; mkdir -p "$HOME/.orca/cli/bin"
cp "$tmp/bin/orca" "$HOME/.orca/cli/bin/orca"
: > "$ORCA_LOG"
PATH="$base_path" DOTFILES="$D" bash "$ROOT/script/setup-agent-skills.sh" > "$tmp/setup3.out" 2>&1
check "setup uses orca from home cli dir" has 'skills install --all' "$ORCA_LOG"
check "setup with home cli orca prints no missing line" lacks 'orca not found' "$tmp/setup3.out"
mkdir -p "$P/.claude/skills/orca-cli"; echo x > "$P/.claude/skills/orca-cli/SKILL.md"
out="$tmp/coll5.out"
PATH="$base_path" DOTFILES="$D" bash "$ROOT/script/check-skill-collisions.sh" "$P" > "$out" 2>&1; rc=$?
check "collision check uses orca from home cli dir" test "$rc" -eq 1
check "home cli orca collision names bundling" has 'bundled by orca' "$out"

[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails failure(s)"; exit 1; }
