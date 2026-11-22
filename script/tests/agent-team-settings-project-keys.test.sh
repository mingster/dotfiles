#!/usr/bin/env bash
# agent-team.sh project merges enabledPlugins and skillOverrides from .claude/settings.project.json
# into the compiled .claude/settings.json (project values win), and a project without them renders
# exactly the template values (#1403).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="$ROOT/templates/agent-team/.claude/settings.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkproj() {
  mkdir -p "$1/.claude"
  printf '# Agents\n' > "$1/AGENTS.md"
  git -C "$1" init -q -b main
}
run_project() { timeout 300 bash "$ROOT/script/agent-team.sh" project "$1" --project-name x 2>&1; }

# 1. Both keys land, project value wins over the template, template entries stay.
P1="$TMP/with"
mkproj "$P1"
cat > "$P1/.claude/settings.project.json" <<'JSON'
{
  "permissions": {"allow": [], "deny": []},
  "hooks": {},
  "enabledPlugins": {"prisma@synced": false, "pdf-viewer@synced": true},
  "skillOverrides": {"fix-merge-conflicts": "off", "orca-emulator": "off"}
}
JSON
if out="$(run_project "$P1")"; then ok "project with keys runs"; else bad "project with keys runs (out: $(tail -5 <<<"$out"))"; fi
res="$(python3 - "$P1/.claude/settings.json" "$TPL" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); t = json.load(open(sys.argv[2]))
p = s.get("enabledPlugins", {})
o = s.get("skillOverrides", {})
good = (
    p.get("prisma@synced") is False
    and p.get("pdf-viewer@synced") is True
    and p.get("design@synced") is t["enabledPlugins"]["design@synced"]
    and o == {"fix-merge-conflicts": "off", "orca-emulator": "off"}
)
print("yes" if good else f"no {p} {o}")
PY
)"
if [ "$res" = yes ]; then ok "both keys merged, project wins"; else bad "both keys merged ($res)"; fi
if out="$(timeout 300 bash "$ROOT/script/agent-team.sh" check "$P1" 2>&1)"; then ok "check sees no drift"; else bad "check sees no drift (out: $(tail -5 <<<"$out"))"; fi

# 2. A project without the keys renders the template values unchanged.
P2="$TMP/without"
mkproj "$P2"
if out="$(run_project "$P2")"; then ok "project without keys runs"; else bad "project without keys runs (out: $(tail -5 <<<"$out"))"; fi
res="$(python3 - "$P2/.claude/settings.json" "$TPL" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); t = json.load(open(sys.argv[2]))
same = s.get("enabledPlugins") == t.get("enabledPlugins") and s.get("skillOverrides") == t.get("skillOverrides")
print("yes" if same else "no")
PY
)"
if [ "$res" = yes ]; then ok "no keys leaves template values"; else bad "no keys leaves template values"; fi

# 3. A wrong type is refused.
P3="$TMP/bad"
mkproj "$P3"
printf '{"permissions":{"allow":[],"deny":[]},"hooks":{},"skillOverrides":["x"]}\n' > "$P3/.claude/settings.project.json"
if out="$(run_project "$P3")"; then bad "bad skillOverrides refused"; else
  if grep -q "skillOverrides" <<<"$out"; then ok "bad skillOverrides refused"; else bad "bad skillOverrides refused (out: $(tail -3 <<<"$out"))"; fi
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
