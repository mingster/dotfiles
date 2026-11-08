#!/usr/bin/env bash
# agent-team.sh project migrates a project guard-bash.py whose PROJECT CONFIG block builds its values
# from helper constants (#780): f-strings, a list comprehension, os.path.join, host deploy commands and
# remote read only patterns. The migrated guard (template + guard-config.json) must give the same
# allow or deny as the old project guard.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/script/tests/fixtures/guard-config-migration"
NEW_HOOK="$ROOT/templates/agent-team/.claude/hooks/guard-bash.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
PROJ="$TMP/proj"
OLD_DIR="$TMP/old-hooks"
mkdir -p "$HOME" "$PROJ/.claude/hooks" "$PROJ/docs/agents" "$OLD_DIR"
cp "$FIXTURE/old-guard-bash.py" "$OLD_DIR/guard-bash.py"
cp "$FIXTURE/production-hosts.txt" "$OLD_DIR/production-hosts.txt"
cp "$FIXTURE/old-guard-bash.py" "$PROJ/.claude/hooks/guard-bash.py"
cp "$FIXTURE/production-hosts.txt" "$PROJ/.claude/hooks/production-hosts.txt"
printf '# Agents\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=t commit -qm init

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# 1. The dry run accepts the block and writes nothing.
if out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$PROJ" --project-name x --dry-run 2>&1)"; then
  ok "dry run passes"
else
  bad "dry run passes (out: $(tail -5 <<<"$out"))"
fi
if [ ! -e "$PROJ/.claude/hooks/guard-config.json" ]; then ok "dry run writes nothing"; else bad "dry run writes nothing"; fi

# A guard constant the evaluator cannot read still refuses the migration.
BAD="$TMP/bad"
mkdir -p "$BAD/.claude/hooks"
printf 'import os\nAPPROVAL_FILE = os.environ.get("X")\n' > "$BAD/.claude/hooks/guard-bash.py"
git -C "$BAD" init -q -b main
if out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$BAD" --project-name x --dry-run 2>&1)"; then
  bad "unsupported call still fails closed"
elif grep -qF "unsupported call in APPROVAL_FILE" <<<"$out"; then
  ok "unsupported call still fails closed"
else
  bad "unsupported call still fails closed (out: $(tail -3 <<<"$out"))"
fi

# 2. The real run writes every production guard fact into guard-config.json.
if out="$(timeout 300 bash "$ROOT/script/agent-team.sh" project "$PROJ" --project-name x 2>&1)"; then
  ok "migration runs"
else
  bad "migration runs (out: $(tail -5 <<<"$out"))"
fi
CFG="$PROJ/.claude/hooks/guard-config.json"
if facts="$(python3 - "$CFG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
app = "/var/www/example.app"
bundle = (f"PROD_APP_DIR={app} BUNDLE_ROOT={app}-bundle PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin "
          f"sh {app}/bin/deploy.sh bundle SHA40 build-artifacts:/")
want = {
    "host_deploy_commands": {"root@prod.example.net": [
        f"git -C {app} fetch --quiet origin && git -C {app} checkout --quiet --detach SHA40",
        bundle, f"SKIP_DB_PUSH=1 {bundle}"]},
    "production_hosts": ["prod", "prod.example.net", "192.0.2.10", "store.example.app", "pay.example.app"],
    "production_branches": ["production"],
    "approval_namespace": "exampleapp",
    "approval_file": "~/.config/exampleapp/approval.json",
    "secrets_dir": "fileServer/secrets",
    "sign_in_script": ".claude/bin/playground-sign-in.sh",
    "blocked_scripts": ["deploy-to-wowza.sh", "deploy-win.sh", "deploy_jar.sh", "iis-manage.sh", "push_smil.sh"],
    "promote_scripts": {"promote-production.sh": {"free_stages": [], "component": None, "sha": 0}},
}
missing = [k for k, v in want.items() if c.get(k) != v]
stdin_ok = c.get("secrets_stdin_ok") or []
if len(stdin_ok) != 3 or not all("{" not in p or "{40}" in p for p in stdin_ok) \
        or not any("ensure-production-sysadmin" in p and "[0-9a-f]{40}" in p and "app-devops-sysadmin-production" in p for p in stdin_ok):
    missing.append("secrets_stdin_ok")
ro = c.get("remote_read_only") or []
if len(ro) != 21 or "pm2 logs [A-Za-z0-9@._-]+ --nostream( --lines [0-9]+)?" not in ro:
    missing.append("remote_read_only")
print(" ".join(missing))
sys.exit(1 if missing else 0)
PY
)"; then
  ok "guard-config.json holds every fact"
else
  bad "guard-config.json holds every fact (wrong: $facts)"
fi

# 3. Old project guard and template guard with that config agree on every command.
SHA="0123456789abcdef0123456789abcdef01234567"
OTHER="fedcba9876543210fedcba9876543210fedcba98"
APP="/var/www/example.app"
BUNDLE="PROD_APP_DIR=$APP BUNDLE_ROOT=$APP-bundle PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin sh $APP/bin/deploy.sh bundle $SHA build-artifacts:/"
PW="~/projects/example.app/fileServer/secrets/sysadmin/app-devops-sysadmin-"
APPROVAL="$HOME/.config/exampleapp/approval.json"

approve() {
  rm -f "$APPROVAL"
  [ "$1" = none ] && return
  mkdir -p "$(dirname "$APPROVAL")"
  python3 -c 'import json,sys,time; json.dump({"scope":sys.argv[1],"target":sys.argv[2],"expires_at":time.time()+600},open(sys.argv[3],"w"))' "$1" "$2" "$APPROVAL"
}

decide() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$PROJ" "$2" \
    | (cd "$PROJ" && HOME="$HOME" timeout 30 python3 "$1") \
    | python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "allow")'
}

# approval scope|target, expected decision, command
while IFS='|' read -r scope target want cmd; do
  [ -z "$cmd" ] && continue
  approve "$scope" "$target"
  old="$(decide "$OLD_DIR/guard-bash.py" "$cmd")"
  new="$(decide "$NEW_HOOK" "$cmd")"
  if [ "$old" = "$want" ] && [ "$new" = "$want" ]; then
    ok "same decision ($want, approval $scope): $cmd"
  else
    bad "same decision (want $want, old $old, new $new, approval $scope): $cmd"
  fi
done <<EOF
none||deny|ssh root@prod.example.net 'git -C $APP fetch --quiet origin && git -C $APP checkout --quiet --detach $SHA'
promote|$SHA|allow|ssh root@prod.example.net 'git -C $APP fetch --quiet origin && git -C $APP checkout --quiet --detach $SHA'
none||deny|ssh root@prod.example.net '$BUNDLE'
promote|$SHA|allow|ssh root@prod.example.net '$BUNDLE'
promote|$OTHER|deny|ssh root@prod.example.net '$BUNDLE'
rollback|$SHA|allow|ssh root@prod.example.net 'SKIP_DB_PUSH=1 $BUNDLE'
promote|$SHA|deny|ssh -p 22 root@prod.example.net '$BUNDLE'
promote|$SHA|deny|ssh root@prod.example.net '$BUNDLE; rm -rf /'
none||allow|ssh root@prod.example.net uptime
none||allow|ssh prod.example.net 'pm2 logs app --nostream --lines 50'
none||allow|ssh prod.example.net 'df -h | grep root'
none||deny|ssh prod.example.net 'rm -rf /tmp/x'
none||allow|ssh build.example.net 'rm -rf /tmp/x'
none||deny|scp notes.txt prod.example.net:/tmp/
none||allow|bin/ensure-production-sysadmin.sh $SHA < ${PW}production
none||deny|bin/ensure-production-sysadmin.sh $SHA extra < ${PW}production
none||allow|ssh root@build.example.net '/var/www/sandbox.example.app/bin/deploy-playground.sh $SHA --sysadmin-account' < ${PW}playground
none||allow|bun run ensure:agent-sysadmin < ${PW}playground
none||deny|cat fileServer/secrets/sysadmin/key
none||allow|cat fileServer/README.md
none||allow|cat ~/.config/exampleapp/approval.json
none||deny|echo '{}' > ~/.config/exampleapp/approval.json
none||deny|bin/owner-approve.sh host
none||deny|bin/promote-production.sh $SHA
promote|$SHA|allow|bin/promote-production.sh $SHA
none||deny|git push origin HEAD:production
none||deny|./bin/deploy-win.sh
none||allow|git status
none||allow|ls -la
EOF

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
