#!/usr/bin/env bash
# Behavioral tests for templates/agent-team/.claude/hooks/guard-bash.py (guard-config.json, template-managed path gate, worktree .env gate) and support-csm/team-facts templates (#732).
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/guard-bash.py"
SUPPORT_CSM="$ROOT/templates/agent-team/.claude/agents/support-csm.md"
TEAM_FACTS="$ROOT/templates/agent-team/docs/agents/team-facts.md"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
PROJ="$TMP/proj"
mkdir -p "$HOME_DIR" "$PROJ/.claude/hooks" "$PROJ/docs/agents"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email "test@example.invalid"
git -C "$PROJ" config user.name "Test"
echo "init" > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm "initial"
SHA="$(git -C "$PROJ" rev-parse HEAD)"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run_bash_hook() {
  local cwd="$1" cmd="$2" sync="${3:-}"
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$cwd" "$cmd" \
    | AGENT_TEAM_SYNC="$sync" HOME="$HOME_DIR" python3 "$HOOK"
}

run_edit_hook() {
  local cwd="$1" tool="$2" path="$3" sync="${4:-}"
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[2],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[3],"content":"x"}}))' "$cwd" "$tool" "$path" \
    | AGENT_TEAM_SYNC="$sync" HOME="$HOME_DIR" python3 "$HOOK"
}

decision() {
  python3 -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "allow")' <<<"$1"
}

check_bash() {
  local label="$1" cwd="$2" cmd="$3" want="$4" needle="${5:-}" sync="${6:-}"
  local out dec
  out="$(run_bash_hook "$cwd" "$cmd" "$sync")"
  dec="$(decision "$out")"
  if [ "$dec" != "$want" ]; then
    bad "$label (got $dec, want $want; out=$out)"
    return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    bad "$label (missing '$needle' in: $out)"
    return
  fi
  ok "$label"
}

check_edit() {
  local label="$1" cwd="$2" tool="$3" path="$4" want="$5" needle="${6:-}" sync="${7:-}"
  local out dec
  out="$(run_edit_hook "$cwd" "$tool" "$path" "$sync")"
  dec="$(decision "$out")"
  if [ "$dec" != "$want" ]; then
    bad "$label (got $dec, want $want; out=$out)"
    return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    bad "$label (missing '$needle' in: $out)"
    return
  fi
  ok "$label"
}

write_approval() {
  local scope="$1" target="${2:-}" offset="${3:-1800}"
  mkdir -p "$HOME_DIR/.config/acme"
  python3 -I -c 'import json,sys,time
now=int(time.time())
with open(sys.argv[1],"w") as f:
    json.dump({"scope":sys.argv[2],"target":sys.argv[3] or None,"schema":False,"created_at":now,"expires_at":now+int(sys.argv[4])},f)
' "$HOME_DIR/.config/acme/approval.json" "$scope" "$target" "$offset"
}

# 1. Default empty guard-config.json is a no-op for project-specific lists.
echo '{}' > "$PROJ/.claude/hooks/guard-config.json"
check_bash "empty config allows ordinary ssh" "$PROJ" "ssh dev@example.invalid 'echo hi'" allow
check_bash "empty config allows feature git push" "$PROJ" "git push origin feat/x" allow

# 2. Populate guard-config.json with all project lists.
cat > "$PROJ/.claude/hooks/guard-config.json" <<'JSON'
{
  "approval_namespace": "acme",
  "production_hosts": ["prod.example.invalid", "203.0.113.10"],
  "stage_branches": ["staging", "production", "web2/staging", "streaminator/*"],
  "promote_scripts": ["promote-production.sh"],
  "blocked_scripts": ["deploy-raw.sh", "deploy-win.sh"],
  "secrets_dir": "vault/keys",
  "sign_in_script": ".claude/bin/dev-sign-in.sh",
  "secrets_stdin_ok": [
    "bun run seed:admin < [^\\s]*vault/keys/dev-admin"
  ],
  "worktree_env_allow": [".env.test"]
}
JSON

# production_hosts
rm -f "$HOME_DIR/.config/acme/approval.json"
check_bash "production_hosts blocks mutating ssh without approval" "$PROJ" "ssh root@prod.example.invalid 'systemctl restart app'" deny "owner-approve.sh"
check_bash "production_hosts blocks interactive ssh without approval" "$PROJ" "ssh root@prod.example.invalid" deny "owner-approve.sh"
check_bash "production_hosts blocks scp without approval" "$PROJ" "scp app.tar root@prod.example.invalid:/tmp/" deny "owner-approve.sh"
check_bash "production_hosts blocks rsync without approval" "$PROJ" "rsync -av dist/ 203.0.113.10:/srv/app/" deny "owner-approve.sh"
check_bash "production_hosts allows read-only ssh status" "$PROJ" "ssh root@prod.example.invalid 'uptime'" allow

write_approval "host" "" 1800
check_bash "production_hosts allows mutating ssh with valid host approval" "$PROJ" "ssh root@prod.example.invalid 'systemctl restart app'" allow
check_bash "production_hosts allows scp with valid host approval" "$PROJ" "scp app.tar root@prod.example.invalid:/tmp/" allow
check_bash "production_hosts allows rsync with valid host approval" "$PROJ" "rsync -av dist/ 203.0.113.10:/srv/app/" allow

write_approval "host" "" -10
check_bash "production_hosts denies ssh when approval expired" "$PROJ" "ssh root@prod.example.invalid 'systemctl restart app'" deny "expired"
rm -f "$HOME_DIR/.config/acme/approval.json"

# stage_branches
check_bash "stage_branches blocks direct push to staging" "$PROJ" "git push origin main:staging" deny "owner-approve.sh"
check_bash "stage_branches blocks direct push to production" "$PROJ" "git push origin HEAD:production" deny "owner-approve.sh"
check_bash "stage_branches blocks direct push to component staging" "$PROJ" "git push origin HEAD:web2/staging" deny "owner-approve.sh"
check_bash "stage_branches blocks direct push to wildcard branch" "$PROJ" "git push origin HEAD:streaminator/staging" deny "owner-approve.sh"
check_bash "stage_branches allows push to feature branch" "$PROJ" "git push origin feat/branch" allow
check_bash "force push allowed on feature branch" "$PROJ" "git push --force-with-lease origin feat/branch" allow
check_bash "force push gated on main" "$PROJ" "git push --force origin main" deny "owner-approve.sh"

write_approval "promote" "$SHA" 1800
check_bash "stage_branches allows push with matching promote approval" "$PROJ" "git push origin $SHA:production" allow
rm -f "$HOME_DIR/.config/acme/approval.json"

# promote_scripts & blocked_scripts
# shellcheck disable=SC2016
check_bash "promote_scripts denies variable sha" "$PROJ" 'bin/promote-production.sh $S' deny "literal"
check_bash "promote_scripts denies unapproved sha" "$PROJ" "bin/promote-production.sh $SHA" deny "owner-approve.sh promote"
write_approval "promote" "$SHA" 1800
check_bash "promote_scripts allows approved sha" "$PROJ" "bin/promote-production.sh $SHA" allow
rm -f "$HOME_DIR/.config/acme/approval.json"

check_bash "blocked_scripts denies direct execution" "$PROJ" "./bin/deploy-raw.sh" deny "deploy"
check_bash "blocked_scripts denies bash execution" "$PROJ" "bash bin/deploy-win.sh" deny "deploy"
check_bash "blocked_scripts allows reading script" "$PROJ" "grep -n set bin/deploy-raw.sh" allow

# secrets_dir, sign_in_script, secrets_stdin_ok
check_bash "secrets_dir denies cat and names sign_in_script" "$PROJ" "cat vault/keys/api-token" deny ".claude/bin/dev-sign-in.sh"
check_bash "sign_in_script execution allowed" "$PROJ" ".claude/bin/dev-sign-in.sh http://localhost:3000 dev@example.invalid" allow
check_bash "secrets_stdin_ok allows matching stdin redirect" "$PROJ" "bun run seed:admin < /tmp/vault/keys/dev-admin" allow
check_bash "secrets_stdin_ok denies non-matching command with secret stdin" "$PROJ" "cat < /tmp/vault/keys/dev-admin" deny "secrets"

# worktree_env_allow in linked worktree
WT="$TMP/orca/workspaces/acme/worker-1"
mkdir -p "$(dirname "$WT")"
git -C "$PROJ" worktree add -q -b worker-1 "$WT"
cp "$PROJ/.claude/hooks/guard-config.json" "$WT/.claude/hooks/guard-config.json" 2>/dev/null || {
  mkdir -p "$WT/.claude/hooks"
  cp "$PROJ/.claude/hooks/guard-config.json" "$WT/.claude/hooks/guard-config.json"
}

check_bash "worktree_env blocks cp .env.local into worktree" "$WT" "cp /tmp/.env.local $WT/.env.local" deny "worktree"
check_bash "worktree_env blocks ln -s .env into worktree" "$WT" "ln -s /tmp/.env .env" deny "worktree"
check_bash "worktree_env blocks shell redirect overwrite of .env in worktree" "$WT" "echo SECRET=1 > .env" deny "worktree"
check_edit "worktree_env blocks Write to .env in worktree" "$WT" "Write" "$WT/.env" deny "worktree"
check_bash "worktree_env_allow permits allowed .env.test in worktree" "$WT" "cp /tmp/.env.test $WT/.env.test" allow
check_edit "worktree_env_allow permits Write to .env.test in worktree" "$WT" "Write" "$WT/.env.test" allow
check_bash "worktree_env permits .env.example in worktree" "$WT" "cp /tmp/.env.example $WT/.env.example" allow

# 3. Template-managed path gate in adopted project outside dotfiles
for rel in \
  ".claude/agents/elon.md" \
  ".claude/agents/support-csm.md" \
  ".claude/hooks/guard-bash.py" \
  ".claude/hooks/strikes.py" \
  ".claude/hooks/worker-budget.py" \
  ".claude/hooks/session-start.md" \
  ".claude/bin/env-peek.py" \
  ".claude/bin/state-of-play.sh" \
  ".claude/settings.json" \
  ".claude/model-routing.md" \
  "docs/agents/team.md" \
  "docs/agents/elon-dispatch.md" \
  "docs/agents/release-manager-work.md" \
  "bin/changelog-compile.sh" \
  "bin/changelog-compile.test.sh" \
  ".agents/skills/crew/SKILL.md" \
  ".agents/skills/deploy/SKILL.md"
do
  check_edit "Write denied on template-managed $rel" "$PROJ" "Write" "$PROJ/$rel" deny "guard-config.json"
  check_bash "Bash write denied on template-managed $rel" "$PROJ" "echo changed > $rel" deny "settings.project.json"
done

check_edit "Edit denied on template-managed role names team-facts.md" "$PROJ" "Edit" "$PROJ/.claude/agents/elon.md" deny "docs/agents/team-facts.md"
check_edit "MultiEdit denied on template-managed hook names templates/agent-team/" "$PROJ" "MultiEdit" "$PROJ/.claude/hooks/guard-bash.py" deny "dotfiles/templates/agent-team/"
check_edit "AGENT_TEAM_SYNC=1 allows Write on template-managed path" "$PROJ" "Write" "$PROJ/.claude/settings.json" allow "" "1"
check_bash "AGENT_TEAM_SYNC=1 allows Bash write on template-managed path" "$PROJ" "cp /tmp/x .claude/settings.json" allow "" "1"
check_bash "inline AGENT_TEAM_SYNC=1 prefix denied on template-managed path" "$PROJ" "AGENT_TEAM_SYNC=1 cp /tmp/x .claude/settings.json" deny "guard-config.json"

# Project-owned extension paths remain allowed without AGENT_TEAM_SYNC=1
for rel in \
  ".claude/agents/stream-health.md" \
  ".claude/hooks/guard-config.json" \
  ".claude/hooks/custom-guard.py" \
  ".claude/settings.project.json" \
  ".agents/skills/custom-tier3/SKILL.md" \
  "docs/agents/team-facts.md"
do
  check_edit "Write allowed on project-owned $rel" "$PROJ" "Write" "$PROJ/$rel" allow
  check_bash "Bash write allowed on project-owned $rel" "$PROJ" "echo ok > $rel" allow
done

# 4. support-csm.md and team-facts.md template checks
for forbidden in "read-thread.sh" "agent-post.sh" "request-issue.sh"; do
  if grep -qF "$forbidden" "$SUPPORT_CSM"; then
    bad "support-csm.md still references $forbidden"
  else
    ok "support-csm.md has no $forbidden reference"
  fi
done

words=$(wc -w < "$SUPPORT_CSM" | tr -d ' ')
if [ "$words" -le 800 ]; then
  ok "support-csm.md within 800 word budget ($words)"
else
  bad "support-csm.md exceeds 800 word budget ($words)"
fi

if grep -qF "docs/agents/team-facts.md" "$SUPPORT_CSM" && grep -qF "Role facts" "$SUPPORT_CSM" && grep -qF "support-csm" "$SUPPORT_CSM"; then
  ok "support-csm.md points to docs/agents/team-facts.md (## Role facts, ### support-csm)"
else
  bad "support-csm.md missing pointer to docs/agents/team-facts.md (## Role facts, ### support-csm)"
fi

if grep -qE '^## Role facts$' "$TEAM_FACTS" && grep -qE '^### support-csm$' "$TEAM_FACTS"; then
  ok "team-facts.md defines ## Role facts and ### support-csm"
else
  bad "team-facts.md missing ## Role facts or ### support-csm"
fi

# 5. Wrong-typed guard-config.json values and non-object config file do not crash, ignore bad key, and log one stderr line
cat > "$PROJ/.claude/hooks/guard-config.json" <<'JSON'
{
  "production_hosts": "prod.example.invalid",
  "blocked_scripts": ["deploy-raw.sh"]
}
JSON
err_str="$TMP/err-str"
out_str="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$PROJ" "ssh root@p 'systemctl restart app'" | HOME="$HOME_DIR" python3 "$HOOK" 2>"$err_str")"
rc_str=$?
if [ "$rc_str" -eq 0 ] && [ "$(decision "$out_str")" = "allow" ] && [ "$(wc -l < "$err_str" | tr -d ' ')" -eq 1 ]; then
  ok "wrong-typed string production_hosts ignored with 1 stderr line and no char-iteration"
else
  bad "wrong-typed string production_hosts failed (rc=$rc_str dec=$(decision "$out_str") stderr_lines=$(wc -l < "$err_str" | tr -d ' ') stderr=$(cat "$err_str"))"
fi

echo '["not-an-object"]' > "$PROJ/.claude/hooks/guard-config.json"
err_arr="$TMP/err-arr"
out_arr="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$PROJ" "git status" | HOME="$HOME_DIR" python3 "$HOOK" 2>"$err_arr")"
rc_arr=$?
if [ "$rc_arr" -eq 0 ] && [ "$(decision "$out_arr")" = "allow" ] && [ "$(wc -l < "$err_arr" | tr -d ' ')" -eq 1 ]; then
  ok "non-object guard-config.json ignored with 1 stderr line"
else
  bad "non-object guard-config.json failed (rc=$rc_arr dec=$(decision "$out_arr") stderr_lines=$(wc -l < "$err_arr" | tr -d ' ') stderr=$(cat "$err_arr"))"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
