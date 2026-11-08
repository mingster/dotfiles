#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
_real_home=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
if [ -L "$_real_home/dotfiles" ]; then
  _real_dotfiles=$(readlink "$_real_home/dotfiles")
elif [ -e "$_real_home/dotfiles" ]; then
  _real_dotfiles=__exists_not_symlink__
else
  _real_dotfiles=__missing__
fi
assert_real_dotfiles_unchanged() {
  local cur
  if [ -L "$_real_home/dotfiles" ]; then cur=$(readlink "$_real_home/dotfiles")
  elif [ -e "$_real_home/dotfiles" ]; then cur=__exists_not_symlink__
  else cur=__missing__
  fi
  [ "$cur" = "$_real_dotfiles" ] || {
    echo "FAIL: install-skills.test.sh repointed the account ~/dotfiles (was $_real_dotfiles, now $cur)" >&2
    exit 1
  }
}
cleanup() { assert_real_dotfiles_unchanged; rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
# Never run the installer against the real home: it repoints ~/dotfiles and every home link.
case "$HOME" in "$TEST_ROOT"/*) ;; *) echo "FAIL: HOME is not a temp dir: $HOME"; exit 1 ;; esac

# A linked worktree's installer refuses when HOME matches DOTFILES_REAL_HOME (the account home under test).
wt="$TEST_ROOT/wt"
git -C "$ROOT" worktree add -q --detach "$wt" HEAD
cp "$ROOT/install.sh" "$wt/install.sh"
rc=0
HOME="$TEST_ROOT/home" DOTFILES_REAL_HOME="$TEST_ROOT/home" DOTFILES_SKIP_SYSTEM_SETUP=1 \
  bash "$wt/install.sh" >"$TEST_ROOT/wt.log" 2>&1 || rc=$?
assert_real_dotfiles_unchanged
git -C "$ROOT" worktree remove --force "$wt"
[ "$rc" = 1 ] && grep -q 'linked worktree' "$TEST_ROOT/wt.log" && [ ! -e "$HOME/dotfiles" ] || { echo "FAIL: worktree install touched the real home"; cat "$TEST_ROOT/wt.log"; exit 1; }
echo 'PASS: linked worktree refuses the real home'
# install.sh ends with setup-check.sh, which exits 1 when host tooling is missing (clean HOME).
# Tolerate that readiness report only; any other failure still fails the test.
run_install() {
  local log=$1 rc=0 h=$HOME
  case "$h" in "$TEST_ROOT"/*) ;; *) echo "FAIL: run_install HOME outside TEST_ROOT: $h"; exit 1 ;; esac
  DOTFILES_SKIP_SYSTEM_SETUP=1 HOME="$h" bash "$ROOT/install.sh" >"$log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && grep -q '^\(OK\|MISSING\) ' "$log"; }
  assert_real_dotfiles_unchanged
}
for pass in 1 2; do
  run_install "$TEST_ROOT/install-$pass.log"
  for dir in "$HOME/.agents" "$HOME/.agents/skills" "$HOME/.claude/skills"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "FAIL: real directory required: $dir"; exit 1; }
  done
  [ "$(readlink "$HOME/.agents/skills/tdd")" = "$ROOT/.agents/skills/tdd" ]
  [ "$(readlink "$HOME/.claude/skills/tdd")" = "$ROOT/.agents/skills/tdd" ]
done
echo 'PASS: installer twice in temp HOME'

# Legacy tree aliases contain both shipped skills and ignored tool data.
export HOME="$TEST_ROOT/legacy-home"
legacy="$TEST_ROOT/legacy-tree/.agents"
mkdir -p "$HOME/.claude" "$legacy/skills/tdd" "$legacy/skills/code-review" "$legacy/skills/orchestration" "$legacy/skills/synced/plugin"
printf 'untracked tool skill\n' > "$legacy/skills/code-review/SKILL.md"
printf 'shipped\n' > "$legacy/skills/tdd/SKILL.md"
printf 'official sentinel\n' > "$legacy/skills/orchestration/SKILL.md"
printf 'plugin sentinel\n' > "$legacy/skills/synced/plugin/SKILL.md"
printf '{"version":3,"skills":{}}\n' > "$legacy/.skill-lock.json"
touch "$TEST_ROOT/legacy-tree/install.sh"
git -C "$TEST_ROOT/legacy-tree" init -q
git -C "$TEST_ROOT/legacy-tree" add .agents/skills/tdd/SKILL.md
ln -s "$legacy" "$HOME/.agents"
ln -s "$legacy/skills" "$HOME/.claude/skills"
for pass in 1 2; do
  run_install "$TEST_ROOT/migrate-$pass.log"
  for dst in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
    [ ! -L "$dst" ]
    [ ! -L "$dst/orchestration" ]
    [ ! -L "$dst/code-review" ]
    [ "$(cat "$dst/code-review/SKILL.md")" = 'untracked tool skill' ]
    [ "$(cat "$dst/orchestration/SKILL.md")" = 'official sentinel' ]
    [ "$(cat "$dst/synced/plugin/SKILL.md")" = 'plugin sentinel' ]
    [ "$(readlink "$dst/tdd")" = "$ROOT/.agents/skills/tdd" ]
  done
  cmp "$legacy/.skill-lock.json" "$HOME/.agents/.skill-lock.json"
  [ "$(cat "$legacy/skills/orchestration/SKILL.md")" = 'official sentinel' ]
done
grep -q 'migrated' "$TEST_ROOT/migrate-1.log"
echo 'PASS: legacy migration preserves ignored skills, plugins, lock and source'

# Real home skill directories and foreign symlinks win over same-name dotfiles skills.
export HOME="$TEST_ROOT/conflict-home"
mkdir -p "$HOME/.agents/skills/tdd" "$HOME/.claude/skills" "$TEST_ROOT/foreign"
printf 'tool owned\n' > "$HOME/.agents/skills/tdd/SKILL.md"
printf 'foreign\n' > "$TEST_ROOT/foreign/SKILL.md"
ln -s "$TEST_ROOT/foreign" "$HOME/.claude/skills/tdd"
for pass in 1 2; do
  run_install "$TEST_ROOT/conflict-$pass.log"
  [ ! -L "$HOME/.agents/skills/tdd" ]
  [ "$(cat "$HOME/.agents/skills/tdd/SKILL.md")" = 'tool owned' ]
  [ "$(readlink "$HOME/.claude/skills/tdd")" = "$TEST_ROOT/foreign" ]
done
echo 'PASS: same-name tool folders and foreign symlinks retained'
for pass in 1 2; do
  DOTFILES="$ROOT" bash "$ROOT/script/setup-claude-code.sh" >"$TEST_ROOT/claude-$pass.log" 2>&1
  [ ! -L "$HOME/.claude/skills" ]
  [ "$(readlink "$HOME/.claude/skills/tdd")" = "$TEST_ROOT/foreign" ]
done
echo 'PASS: Claude setup twice preserves tool skills'

