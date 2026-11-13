#!/usr/bin/env bash
# Tests for user-level agent team hooks, helpers, Tier 2 skills, and template settings.json (refs #731).
# shellcheck disable=SC1091,SC2015,SC2016
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$here/lib/asdf-pin.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Stub orca so tests never mutate real host state or depend on host orca installation.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/orca" <<'EOS'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "skills list") printf 'orca-cli: Bundled orca cli skill.\n' ;;
  "skills install") exit 0 ;;
esac
exit 0
EOS
chmod +x "$stub_bin/orca"

# 1. setup-claude-code.sh --keep-settings links 3 hooks, 2 bin helpers, and preserves unrelated user files + settings.json
home1="$tmp/home1"
mkdir -p "$home1/.claude/hooks" "$home1/.claude/bin" "$home1/.agents/skills/orca-cli"
printf 'custom hook\n' >"$home1/.claude/hooks/unrelated-user.py"
printf 'custom helper\n' >"$home1/.claude/bin/unrelated-helper.sh"
printf '{"keep_me":true}\n' >"$home1/.claude/settings.json"
printf 'rendered copy\n' >"$home1/.claude/hooks/session-start.md"
printf 'orca bundled\n' >"$home1/.agents/skills/orca-cli/SKILL.md"

set +e
out1=$(HOME="$home1" PATH="$stub_bin:/usr/bin:/bin" DOTFILES="$root" bash "$root/script/setup-claude-code.sh" --keep-settings 2>&1)
ec1=$?
set -e
[ "$ec1" -eq 0 ] && ok "setup-claude-code.sh --keep-settings exits 0" || bad "setup-claude-code.sh exited $ec1: $out1"

for h in guard-bash.py strikes.py worker-budget.py; do
  target="$home1/.claude/hooks/$h"
  expected="$root/templates/agent-team/.claude/hooks/$h"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$expected" ] && [ -f "$target" ]; then
    ok "linked ~/.claude/hooks/$h"
  else
    bad "missing or wrong symlink ~/.claude/hooks/$h (got $(readlink "$target" 2>/dev/null || echo none), want $expected)"
  fi
done

# session-start.md belongs to agent-team.sh machine (rendered copy); setup must leave it alone.
if [ -f "$home1/.claude/hooks/session-start.md" ] && [ ! -L "$home1/.claude/hooks/session-start.md" ] &&
   [ "$(cat "$home1/.claude/hooks/session-start.md")" = "rendered copy" ]; then
  ok "setup-claude-code.sh leaves the rendered session-start.md copy alone"
else
  bad "setup-claude-code.sh replaced ~/.claude/hooks/session-start.md"
fi

for b in env-peek.py state-of-play.sh; do
  target="$home1/.claude/bin/$b"
  expected="$root/templates/agent-team/.claude/bin/$b"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$expected" ] && [ -f "$target" ]; then
    ok "linked ~/.claude/bin/$b"
  else
    bad "missing or wrong symlink ~/.claude/bin/$b (got $(readlink "$target" 2>/dev/null || echo none), want $expected)"
  fi
done

if [ -f "$home1/.claude/hooks/unrelated-user.py" ] && [ ! -L "$home1/.claude/hooks/unrelated-user.py" ] &&
   [ "$(cat "$home1/.claude/hooks/unrelated-user.py")" = "custom hook" ] &&
   [ -f "$home1/.claude/bin/unrelated-helper.sh" ] && [ ! -L "$home1/.claude/bin/unrelated-helper.sh" ] &&
   [ "$(cat "$home1/.claude/bin/unrelated-helper.sh")" = "custom helper" ] &&
   grep -q '"keep_me":true' "$home1/.claude/settings.json"; then
  ok "preserves unrelated files in ~/.claude/hooks, ~/.claude/bin, and ~/.claude/settings.json"
else
  bad "overwrote unrelated user files or settings.json"
fi

# 2. setup-agent-skills.sh symlinks all 5 named Tier 2 skills + every Tier 2 skill in templates/agent-team/.agents/skills/
#    into both ~/.agents/skills/<name> and ~/.claude/skills/<name> alongside Tier 1 skills
for s in ceo deploy elon poteto-mode team-audit; do
  if [ -L "$home1/.agents/skills/$s" ] && [ -f "$home1/.agents/skills/$s/SKILL.md" ] &&
     [ -L "$home1/.claude/skills/$s" ] && [ -f "$home1/.claude/skills/$s/SKILL.md" ]; then
    ok "linked Tier 2 skill $s in ~/.agents/skills and ~/.claude/skills"
  else
    bad "missing Tier 2 skill link $s in ~/.agents/skills or ~/.claude/skills"
  fi
done

missing_t2=0
for d in "$root/templates/agent-team/.agents/skills"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  s=$(basename "$d")
  if [ ! -L "$home1/.agents/skills/$s" ] || [ ! -L "$home1/.claude/skills/$s" ]; then
    missing_t2=$((missing_t2 + 1))
  fi
done
[ "$missing_t2" -eq 0 ] && ok "every Tier 2 directory under templates/agent-team/.agents/skills/ is linked" || bad "$missing_t2 Tier 2 skill directories not linked"

if [ -L "$home1/.agents/skills/orca-adapter" ] && [ -f "$home1/.agents/skills/orca-adapter/ORCA-ADAPTER.md" ] &&
   [ -L "$home1/.claude/skills/orca-adapter" ] && [ -f "$home1/.claude/skills/orca-adapter/ORCA-ADAPTER.md" ]; then
  ok "orca-adapter is linked into ~/.agents/skills and ~/.claude/skills"
else
  bad "orca-adapter link missing"
fi

if [ -L "$home1/.agents/skills/tdd" ] && [ -L "$home1/.claude/skills/tdd" ]; then
  ok "Tier 1 skills (tdd) remain linked alongside Tier 2 skills"
else
  bad "Tier 1 skill tdd missing"
fi

# 3. Preserves existing tool-owned skills and Orca-bundled skills
home2="$tmp/home2"
mkdir -p "$home2/.agents/skills/elon" "$home2/.claude/skills/orca-cli"
printf 'tool owned elon\n' >"$home2/.agents/skills/elon/SKILL.md"
printf 'orca bundled cli\n' >"$home2/.claude/skills/orca-cli/SKILL.md"
set +e
HOME="$home2" PATH="$stub_bin:/usr/bin:/bin" DOTFILES="$root" bash "$root/script/setup-agent-skills.sh" >/dev/null 2>&1
ec2=$?
set -e
if [ "$ec2" -eq 0 ] && [ ! -L "$home2/.agents/skills/elon" ] &&
   [ "$(cat "$home2/.agents/skills/elon/SKILL.md")" = "tool owned elon" ] &&
   [ ! -L "$home2/.claude/skills/orca-cli" ] &&
   [ "$(cat "$home2/.claude/skills/orca-cli/SKILL.md")" = "orca bundled cli" ]; then
  ok "preserves tool-owned and Orca-bundled skills"
else
  bad "failed to preserve tool-owned or Orca-bundled skills (ec=$ec2)"
fi

# 4. templates/agent-team/.claude/settings.json references $HOME/.claude/ and registers guard-bash.py on Read|Write|Edit|MultiEdit|NotebookEdit
settings_file="$root/templates/agent-team/.claude/settings.json"
proj_refs=$(grep -c 'CLAUDE_PROJECT_DIR/\.claude/\(hooks\|bin\)' "$settings_file" || true)
[ "$proj_refs" -eq 0 ] && ok "no CLAUDE_PROJECT_DIR/.claude/{hooks,bin} references remain in settings.json" || bad "found $proj_refs CLAUDE_PROJECT_DIR/.claude/{hooks,bin} references in settings.json"

if python3 - "$settings_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
raw = json.dumps(data)
required = [
    "$HOME/.claude/hooks/session-start.md",
    "$HOME/.claude/bin/state-of-play.sh",
    "$HOME/.claude/hooks/guard-bash.py",
    "$HOME/.claude/hooks/strikes.py",
    "$HOME/.claude/hooks/worker-budget.py",
]
for r in required:
    if r not in raw:
        sys.exit(f"missing {r}")
pre = data.get("hooks", {}).get("PreToolUse", [])
write_match = [
    g for g in pre
    if g.get("matcher") == "Read|Write|Edit|MultiEdit|NotebookEdit"
    and any(h.get("command") == 'python3 "$HOME/.claude/hooks/guard-bash.py"' for h in g.get("hooks", []))
]
if not write_match:
    sys.exit("missing PreToolUse Read|Write|Edit|MultiEdit|NotebookEdit guard-bash.py entry")
PY
then
  ok "templates/agent-team/.claude/settings.json invokes \$HOME/.claude/{hooks,bin} and PreToolUse Read|Write|Edit|MultiEdit|NotebookEdit guard-bash.py"
else
  bad "templates/agent-team/.claude/settings.json failed hook path or matcher check"
fi

# 4. ~/.claude/agents is a real directory: agent-team.sh machine writes rendered role files there,
#    and a link into the repo would drop them into the dotfiles checkout as untracked files.
agents_src="$root/.agents/claude/agents"
for case in fresh legacy rendered; do
  home4="$tmp/home4-$case"
  mkdir -p "$home4/.claude" "$home4/.agents/skills/orca-cli"
  printf 'orca bundled\n' >"$home4/.agents/skills/orca-cli/SKILL.md"
  case "$case" in
    legacy) ln -s "$agents_src" "$home4/.claude/agents" ;;
    rendered) mkdir -p "$home4/.claude/agents" && printf 'rendered role\n' >"$home4/.claude/agents/elon.md" ;;
  esac
  HOME="$home4" PATH="$stub_bin:/usr/bin:/bin" DOTFILES="$root" bash "$root/script/setup-claude-code.sh" --keep-settings >/dev/null 2>&1
  if [ -d "$home4/.claude/agents" ] && [ ! -L "$home4/.claude/agents" ]; then
    ok "$case: ~/.claude/agents is a real directory"
  else
    bad "$case: ~/.claude/agents is $(readlink "$home4/.claude/agents" 2>/dev/null || echo missing), want a real directory"
    continue
  fi
  linked=1
  while IFS= read -r f; do
    n=$(basename "$f")
    [ "$(readlink "$home4/.claude/agents/$n")" = "$agents_src/$n" ] || linked=0
  done < <(git -C "$root" ls-files .agents/claude/agents)
  [ "$linked" -eq 1 ] && ok "$case: each tracked agent is linked into ~/.claude/agents" || bad "$case: tracked agent links missing"
done
if [ "$(cat "$tmp/home4-rendered/.claude/agents/elon.md" 2>/dev/null)" = "rendered role" ]; then
  ok "rendered: setup leaves a rendered role file alone"
else
  bad "rendered: rendered role file was replaced or removed"
fi

echo "setup-user-level-team: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
