#!/usr/bin/env bash
# setup-claude-code.sh removes ~/.cursor/skills only when it is a symlink (#1556).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tests=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
# Stub dotfiles: setup-agent-skills.sh would itself migrate a linked ~/.claude/skills, so
# replace it and test only the cursor/claude block.
df="$tmp/dotfiles"
mkdir -p "$df/.agents/claude" "$df/.agents/skills" "$df/script/lib"
touch "$df/.agents/claude/CLAUDE.md"
cp "$root/script/setup-claude-code.sh" "$df/script/"
cp "$root/script/lib/dotfiles-source.sh" "$df/script/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$df/script/setup-agent-skills.sh"
run() { DOTFILES="$df" bash "$df/script/setup-claude-code.sh" 2>&1; }
reset() { rm -rf "$HOME"; mkdir -p "$HOME/.cursor"; }

# Direction 1: ~/.cursor/skills is the link to a real ~/.claude/skills. The link goes.
reset
mkdir -p "$HOME/.claude/skills/keep"
ln -s "$HOME/.claude/skills" "$HOME/.cursor/skills"
run >/dev/null || fail 'direction 1 exited non-zero'
[ ! -e "$HOME/.cursor/skills" ] && [ ! -L "$HOME/.cursor/skills" ] || fail 'cursor link was not removed'
[ -d "$HOME/.claude/skills/keep" ] || fail 'real claude skills dir was damaged'
tests=$((tests + 1))

# Direction 2: ~/.claude/skills is the link to a real ~/.cursor/skills. The real dir stays.
reset
mkdir -p "$HOME/.cursor/skills/keep" "$HOME/.claude"
touch "$HOME/.cursor/skills/keep/SKILL.md"
ln -s "$HOME/.cursor/skills" "$HOME/.claude/skills"
out=$(run) || fail "direction 2 exited non-zero: $out"
[ -f "$HOME/.cursor/skills/keep/SKILL.md" ] || fail 'real ~/.cursor/skills was deleted'
[[ "$out" == *"not removing"* ]] || fail "no warning printed: $out"
tests=$((tests + 1))

printf 'ok: %d setup-claude-code cursor skills cases\n' "$tests"
