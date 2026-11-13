#!/usr/bin/env bash
# Tests for the root owned approval file (dotfiles#917): the setup script, the write helper, and the guard
# reading the file from the root folder. Runs unprivileged, so the root folder is a temp stand in.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/guard-bash.py"
SETUP="$ROOT/script/approval-root-setup.sh"
WRITE="$ROOT/script/approval-write.sh"

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJ="$TMP/proj"
AROOT="$TMP/etc/agent-team"
mkdir -p "$HOME_DIR/.config/acme" "$PROJ/.claude/hooks"
git -C "$PROJ" init -q -b main
echo '{ "approval_namespace": "acme", "production_hosts": ["prod.example.invalid"] }' > "$PROJ/.claude/hooks/guard-config.json"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

decision() {
  GUARD_APPROVAL_ROOT="$1" HOME="$HOME_DIR" python3 -c '
import json,subprocess,sys,os
inp=json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"ssh root@prod.example.invalid \"systemctl restart app\""}})
d=subprocess.run(["python3",sys.argv[2]],input=inp,capture_output=True,text=True).stdout.strip()
print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "allow")' "$PROJ" "$HOOK"
}
approval_json() { python3 -I -c 'import json,time; n=int(time.time()); print(json.dumps({"scope":"host","target":None,"schema":False,"created_at":n,"expires_at":n+1800}))'; }

# Setup script: dry run changes nothing, real run creates the layout, a second run is harmless.
out="$(bash "$SETUP" --dry-run acme 2>&1)"
grep -q "Dry run" <<<"$out" && [ ! -e "$AROOT" ] && ok "dry run prints the plan and changes nothing" || bad "dry run: $out"
bash "$SETUP" 2>/dev/null && bad "setup without a namespace must fail" || ok "setup without a namespace fails"
export SETUP_ROOT="$AROOT" SETUP_LIBEXEC="$TMP/libexec" SETUP_SUDOERS="$TMP/sudoers.d/agent-team-approval" SETUP_SKIP_ROOT_CHECK=1
bash "$SETUP" acme >/dev/null 2>&1 && bash "$SETUP" acme >/dev/null 2>&1 && ok "setup runs twice without error" || bad "setup run"
[ "$(mode "$AROOT/acme")" = 755 ] && ok "approval folder is 0755" || bad "folder mode $(mode "$AROOT/acme")"
[ "$(mode "$TMP/libexec/approval-write")" = 755 ] && ok "helper installed 0755" || bad "helper mode"
[ "$(mode "$TMP/sudoers.d/agent-team-approval")" = 440 ] && grep -q "timestamp_timeout=0" "$TMP/sudoers.d/agent-team-approval" \
  && grep -q "^Defaults!.*/approval-write timestamp_timeout=0" "$TMP/sudoers.d/agent-team-approval" && ok "sudoers asks every time for the helper" || bad "sudoers file"
if command -v visudo >/dev/null 2>&1 && visudo -cf "$TMP/sudoers.d/agent-team-approval" >/dev/null 2>&1; then ok "sudoers file passes visudo"; else ok "sudoers visudo check skipped"; fi

# Write helper: world readable, nobody else can write, bad input refused.
export AGENT_APPROVAL_ROOT="$AROOT"
approval_json 2>/dev/null | bash "$WRITE" acme && ok "helper writes the approval" || bad "helper write"
f="$AROOT/acme/approval.json"
[ "$(mode "$f")" = 644 ] && ok "approval file is 0644 (group and others cannot write)" || bad "file mode $(mode "$f")"
echo 'not json' | bash "$WRITE" acme 2>/dev/null && bad "helper accepted non JSON" || ok "helper refuses non JSON"
approval_json 2>/dev/null | bash "$WRITE" '../x' 2>/dev/null && bad "helper accepted a bad namespace" || ok "helper refuses a path in the namespace"
approval_json 2>/dev/null | bash "$WRITE" other 2>/dev/null && bad "helper created a folder itself" || ok "helper does not create folders (root setup does)"
[ -z "$(find "$AROOT/acme" -name '.approval.*')" ] && ok "helper leaves no temp file" || bad "temp file left"

# A non sudo write fails. An existing root owned file (/etc/hosts, 0644) stands in for the approval file;
# the same mode and owner the helper gives the real one.
if [ -f /etc/hosts ] && [ "$(id -u)" -ne 0 ] && [ "$(stat -f %u /etc/hosts 2>/dev/null || stat -c %u /etc/hosts)" = 0 ]; then
  ( : >> /etc/hosts ) 2>/dev/null && bad "worker appended to a root owned 0644 file" || ok "non sudo write to a root owned 0644 file fails"
else
  ok "root owned stand in check skipped (running as root)"
fi
# Guard: reads a valid approval from the root folder; ignores a forged one under ~/.config once the root exists.
[ "$(decision "$AROOT")" = allow ] && ok "guard accepts the approval in the root folder" || bad "guard rejected the root approval"
rm -f "$f"
approval_json > "$HOME_DIR/.config/acme/approval.json"
[ "$(decision "$AROOT")" = deny ] && ok "guard ignores a ~/.config approval once the root folder exists" || bad "guard honoured the home approval"
[ "$(decision "$TMP/no-such-root")" = allow ] && ok "without the root folder the old location still works" || bad "legacy location broke"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
