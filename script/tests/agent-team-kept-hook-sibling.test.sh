#!/usr/bin/env bash
# agent-team.sh project must not remove a managed hook file (guard-bash.py) that a kept project hook
# or a kept settings hook command still loads by name (#786). The plan prints why it keeps the file.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkproj() {
  local p="$1"
  mkdir -p "$p/.claude/hooks"
  printf '# Agents\n' > "$p/AGENTS.md"
  printf 'import sys\nsys.exit(0)\n' > "$p/.claude/hooks/guard-bash.py"
  git -C "$p" init -q -b main
}

# 1. A kept hook loads guard-bash.py as a sibling.
P1="$TMP/sibling"
mkproj "$P1"
cat > "$P1/.claude/hooks/project-guard.py" <<'PY'
import runpy
from pathlib import Path

runpy.run_path(str(Path(__file__).with_name("guard-bash.py")))
PY
git -C "$P1" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$P1" -c user.email=t@example.invalid -c user.name=t commit -qm init

out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P1" --project-name x --dry-run 2>&1)"
if grep -qF "keep .claude/hooks/guard-bash.py (loaded by .claude/hooks/project-guard.py" <<<"$out" \
  && ! grep -qF "would remove .claude/hooks/guard-bash.py" <<<"$out"; then
  ok "dry run reports the kept file"
else
  bad "dry run reports the kept file (out: $(tail -5 <<<"$out"))"
fi

if out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P1" --project-name x 2>&1)"; then
  ok "migration runs"
else
  bad "migration runs (out: $(tail -5 <<<"$out"))"
fi
if [ -f "$P1/.claude/hooks/guard-bash.py" ]; then ok "guard-bash.py kept"; else bad "guard-bash.py kept"; fi
if echo '{"tool_input":{"command":"ls"}}' | python3 "$P1/.claude/hooks/project-guard.py" >/dev/null 2>&1; then
  ok "kept hook still exits 0"
else
  bad "kept hook still exits 0"
fi

# 2. A kept settings hook command names the project copy.
P2="$TMP/settings"
mkproj "$P2"
cat > "$P2/.claude/settings.project.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-bash.py\""}]}]}}
JSON
git -C "$P2" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$P2" -c user.email=t@example.invalid -c user.name=t commit -qm init
timeout 300 bash "$ROOT/script/agent-team.sh" project "$P2" --project-name x >/dev/null 2>&1
if [ -f "$P2/.claude/hooks/guard-bash.py" ]; then ok "settings reference keeps the file"; else bad "settings reference keeps the file"; fi

# 3. Nothing references it: still removed (the template's $HOME/.claude/hooks command does not count).
P3="$TMP/plain"
mkproj "$P3"
git -C "$P3" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$P3" -c user.email=t@example.invalid -c user.name=t commit -qm init
out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P3" --project-name x 2>&1)"
if [ ! -e "$P3/.claude/hooks/guard-bash.py" ]; then ok "unreferenced file still removed"; else bad "unreferenced file still removed (out: $(tail -5 <<<"$out"))"; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
