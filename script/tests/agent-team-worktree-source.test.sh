#!/usr/bin/env bash
# #761: machine and setup-agent-skills.sh wire HOME only from the main dotfiles checkout, and
# check flags a machine link into a git worktree. Every HOME here is a temp dir; the refusal
# cases point TMPDIR elsewhere so that HOME no longer counts as a test home.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/agent-team.sh"
SKILLS_SCRIPT="$ROOT/script/setup-agent-skills.sh"

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# A main checkout, a linked worktree of it and a plain copy that is not ~/dotfiles.
main="$TMP/main"
wt="$TMP/worker"
other="$TMP/other"
git init -q "$main"
mkdir -p "$main/skill" "$other"
printf 'x\n' >"$main/skill/SKILL.md"
printf 'x\n' >"$main/hook.py"
git -C "$main" add -A
git -C "$main" -c user.email=t@example.com -c user.name=t commit -qm seed
git -C "$main" worktree add -q "$wt" -b worker

# Not a test home: HOME lives outside TMPDIR.
real_home="$TMP/real-home"
elsewhere="$TMP/elsewhere"
mkdir -p "$real_home" "$elsewhere"
ln -s "$main" "$real_home/dotfiles"

refused() { # <label> <script> <source> [args...]
  local label=$1 script=$2 src=$3 out rc
  shift 3
  out=$(HOME="$real_home" TMPDIR="$elsewhere" PATH=/usr/bin:/bin DOTFILES="$src" bash "$script" "$@" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    && grep -q "run it from the main checkout $main\$" <<<"$out" \
    && [ "$(find "$real_home" -mindepth 1 -maxdepth 1 ! -name dotfiles | wc -l | tr -d ' ')" = 0 ]; then
    ok "$label"
  else
    bad "$label (rc=$rc): $out"
  fi
}

refused "machine from a worktree with a real HOME is refused in one line naming the main checkout" "$SCRIPT" "$wt" machine
refused "machine --dry-run from a worktree is refused too" "$SCRIPT" "$wt" machine --dry-run
refused "machine from a path other than ~/dotfiles is refused" "$SCRIPT" "$other" machine
refused "setup-agent-skills.sh from a worktree with a real HOME is refused" "$SKILLS_SCRIPT" "$wt"
refused "setup-agent-skills.sh from a path other than ~/dotfiles is refused" "$SKILLS_SCRIPT" "$other"

# ~/dotfiles itself pointing into a worktree is still a worktree.
ln -sfn "$wt" "$real_home/dotfiles"
refused "setup-agent-skills.sh refuses when ~/dotfiles points at a worktree" "$SKILLS_SCRIPT" "$wt"
ln -sfn "$main" "$real_home/dotfiles"

# The main checkout passes the guard (PATH without orca, so nothing outside HOME runs).
if HOME="$real_home" TMPDIR="$elsewhere" PATH=/usr/bin:/bin DOTFILES="$main" bash "$SKILLS_SCRIPT" >/dev/null 2>&1 \
  && [ -d "$real_home/.claude/skills" ]; then
  ok "setup-agent-skills.sh runs from the main checkout"
else
  bad "setup-agent-skills.sh runs from the main checkout"
fi

# A temp HOME is a test home: the worktree source is allowed.
test_home="$TMP/test-home"
mkdir -p "$test_home"
if HOME="$test_home" TMPDIR="$TMP" PATH=/usr/bin:/bin DOTFILES="$wt" bash "$SKILLS_SCRIPT" >/dev/null 2>&1; then
  ok "setup-agent-skills.sh allows a worktree source under a temp HOME"
else
  bad "setup-agent-skills.sh allows a worktree source under a temp HOME"
fi

# check flags machine links into the worktree and leaves links into the main checkout alone.
check_home="$TMP/check-home"
mkdir -p "$check_home/.claude/hooks" "$check_home/.agents/skills"
ln -s "$wt/hook.py" "$check_home/.claude/hooks/guard-bash.py"
ln -s "$wt/skill" "$check_home/.agents/skills/wt-skill"
ln -s "$main/skill" "$check_home/.agents/skills/main-skill"
project="$TMP/project"
git init -q "$project"
out=$(cd "$project" && HOME="$check_home" bash "$SCRIPT" check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] \
  && grep -q "machine link $check_home/.claude/hooks/guard-bash.py points into worktree $wt; rerun machine from the main checkout $main" <<<"$out" \
  && grep -q "machine link $check_home/.agents/skills/wt-skill points into worktree $wt" <<<"$out" \
  && ! grep -q "main-skill" <<<"$out"; then
  ok "check flags machine links into a worktree and fails"
else
  bad "check flags machine links into a worktree and fails (rc=$rc): $out"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
