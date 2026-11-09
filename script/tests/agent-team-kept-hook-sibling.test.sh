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

commit_all() {
  git -C "$1" -c user.email=t@example.invalid -c user.name=t add -A
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -qm init
}

keep_lines() { grep '^keep ' <<<"$1" | sort; }

# 4. Dry run and real run agree: both scan the settings the run ends with, so legacy
#    $CLAUDE_PROJECT_DIR commands the run replaces keep nothing.
P4="$TMP/projB"
mkproj "$P4"
for f in strikes.py worker-budget.py; do printf 'import sys\nsys.exit(0)\n' > "$P4/.claude/hooks/$f"; done
printf '# Session\n' > "$P4/.claude/hooks/session-start.md"
cat > "$P4/.claude/hooks/warn.py" <<'PY'
import runpy
from pathlib import Path

runpy.run_path(str(Path(__file__).with_name("guard-bash.py")))
PY
cat > "$P4/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/strikes.py\""},{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/worker-budget.py\""}]}],"SessionStart":[{"hooks":[{"type":"command","command":"cat \"$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.md\""}]}]}}
JSON
commit_all "$P4"
dry_out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P4" --project-name x --dry-run 2>&1)"
real_out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P4" --project-name x 2>&1)"
if [ -n "$(keep_lines "$dry_out")" ] && [ "$(keep_lines "$dry_out")" = "$(keep_lines "$real_out")" ]; then
  ok "dry run keep list equals real run keep list"
else
  bad "dry run keep list equals real run keep list (dry: $(keep_lines "$dry_out" | tr '\n' '|') real: $(keep_lines "$real_out" | tr '\n' '|'))"
fi
gone=1
for f in strikes.py worker-budget.py session-start.md; do
  [ -e "$P4/.claude/hooks/$f" ] && gone=0
  grep -qF "keep .claude/hooks/$f" <<<"$dry_out" && gone=0
done
if [ "$gone" -eq 1 ]; then ok "replaced settings commands keep strikes, worker-budget, session-start in neither run"; else bad "replaced settings commands keep strikes, worker-budget, session-start in neither run"; fi

# 5. Python imports keep the file.
P5="$TMP/import"
mkproj "$P5"
printf 'import sys\nsys.exit(0)\n' > "$P5/.claude/hooks/strikes.py"
printf 'x = 1\n' > "$P5/.claude/hooks/worker-budget.py"
printf 'import os, strikes\n' > "$P5/.claude/hooks/uses-import.py"
commit_all "$P5"
timeout 300 bash "$ROOT/script/agent-team.sh" project "$P5" --project-name x >/dev/null 2>&1
if [ -f "$P5/.claude/hooks/strikes.py" ]; then ok "import <stem> keeps the file"; else bad "import <stem> keeps the file"; fi
if [ ! -e "$P5/.claude/hooks/worker-budget.py" ]; then ok "unrelated import does not keep a file"; else bad "unrelated import does not keep a file"; fi
P5B="$TMP/from-import"
mkproj "$P5B"
printf 'x = 1\n' > "$P5B/.claude/hooks/strikes.py"
printf 'from strikes import x\n' > "$P5B/.claude/hooks/uses-from.py"
commit_all "$P5B"
timeout 300 bash "$ROOT/script/agent-team.sh" project "$P5B" --project-name x >/dev/null 2>&1
if [ -f "$P5B/.claude/hooks/strikes.py" ]; then ok "from <stem> import keeps the file"; else bad "from <stem> import keeps the file"; fi

# 6. Transitive: a kept hook loads guard-bash.py, which names production-hosts.txt.
P6="$TMP/transitive"
mkproj "$P6"
printf 'from pathlib import Path\nHOSTS = Path(__file__).with_name("production-hosts.txt")\n' > "$P6/.claude/hooks/guard-bash.py"
printf 'example.com\n' > "$P6/.claude/hooks/production-hosts.txt"
printf 'x = 1\n' > "$P6/.claude/hooks/strikes.py"
cat > "$P6/.claude/hooks/project-guard.py" <<'PY'
import runpy
from pathlib import Path

runpy.run_path(str(Path(__file__).with_name("guard-bash.py")))
PY
commit_all "$P6"
out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P6" --project-name x 2>&1)"
if [ -f "$P6/.claude/hooks/guard-bash.py" ] && [ -f "$P6/.claude/hooks/production-hosts.txt" ]; then
  ok "transitive: guard-bash.py and production-hosts.txt both stay"
else
  bad "transitive: guard-bash.py and production-hosts.txt both stay (out: $(tail -5 <<<"$out"))"
fi
if [ ! -e "$P6/.claude/hooks/strikes.py" ]; then ok "transitive: unrelated file still removed"; else bad "transitive: unrelated file still removed"; fi

# 7. .claude/hooks/tests/ is not scanned, and the plan says so.
P7="$TMP/tests-dir"
mkproj "$P7"
mkdir -p "$P7/.claude/hooks/tests"
printf 'import guard-bash\nrunpy.run_path("guard-bash.py")\n' > "$P7/.claude/hooks/tests/test_guard.py"
commit_all "$P7"
out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P7" --project-name x --dry-run 2>&1)"
if grep -qF "would remove .claude/hooks/guard-bash.py" <<<"$out" \
  && [ "$(grep -cF '.claude/hooks/tests/ is not scanned' <<<"$out")" -eq 1 ]; then
  ok "hooks/tests/ is not scanned and the plan says so once"
else
  bad "hooks/tests/ is not scanned and the plan says so once (out: $(tail -6 <<<"$out"))"
fi

# 8. check agrees with project (#808): the files project keeps for a kept hook are not drift,
#    and a shared hook copy that nothing kept loads still is.
P8="$TMP/check"
mkproj "$P8"
printf 'from pathlib import Path\nHOSTS = Path(__file__).with_name("production-hosts.txt")\n' > "$P8/.claude/hooks/guard-bash.py"
printf 'example.com\n' > "$P8/.claude/hooks/production-hosts.txt"
cat > "$P8/.claude/hooks/warn-elon-fullstack.py" <<'PY'
import runpy
from pathlib import Path

runpy.run_path(str(Path(__file__).with_name("guard-bash.py")))
PY
commit_all "$P8"
out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$P8" --project-name x 2>&1)"
if [ -f "$P8/.claude/hooks/guard-bash.py" ] && [ -f "$P8/.claude/hooks/production-hosts.txt" ] \
  && out="$(timeout 300 bash "$ROOT/script/agent-team.sh" check "$P8" 2>&1)"; then
  ok "check after project passes with kept siblings"
else
  bad "check after project passes with kept siblings (out: $(tail -5 <<<"$out"))"
fi
printf 'x = 1\n' > "$P8/.claude/hooks/strikes.py"
out="$(timeout 300 bash "$ROOT/script/agent-team.sh" check "$P8" 2>&1)"
if grep -qF "shared hook copy or link in project: .claude/hooks/strikes.py" <<<"$out" \
  && ! grep -qF ".claude/hooks/guard-bash.py" <<<"$out" \
  && ! grep -qF ".claude/hooks/production-hosts.txt" <<<"$out"; then
  ok "check still flags an unneeded shared hook copy, and only that"
else
  bad "check still flags an unneeded shared hook copy, and only that (out: $(tail -5 <<<"$out"))"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
