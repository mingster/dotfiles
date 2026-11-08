#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tests for script/automation-precheck-staging-daily.sh and docs/agents/orca-automations.md.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
script="$root/script/automation-precheck-staging-daily.sh"
wrapper="$root/script/automation-precheck-wrapper.sh"
doc="$root/docs/agents/orca-automations.md"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
  local desc=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
    echo "ok   $desc"
  else
    fail=$((fail + 1))
    echo "FAIL $desc"
  fi
}

check 'precheck script exists and is executable' test -x "$script"
if [ -f "$script" ]; then
  shellcheck -x --severity=error "$script"
  check 'shellcheck passes on automation-precheck-staging-daily.sh' true
else
  check 'shellcheck passes on automation-precheck-staging-daily.sh' false
fi

mkdir -p "$tmp/bin" "$tmp/state" "$tmp/config"
export PATH="$tmp/bin:$PATH"
export ORCA_LOG="$tmp/orca-calls.log"
export ORCA_CLI_COMMAND="$tmp/bin/orca"

cat >"$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORCA_LOG:?}"
if [ "${1:-}" = "orchestration" ] && [ "${2:-}" = "run-list" ]; then
  printf '{"ok":true,"result":{"runs":[{"id":"run_from_list"}]}}\n'
  exit 0
fi
printf '{"ok":true,"result":{"sent":true}}\n'
EOS
chmod +x "$tmp/bin/orca"

export FLEET_WATCH_CONFIG="$tmp/config/fleet-watch.json"
cat >"$FLEET_WATCH_CONFIG" <<'EOF'
{
  "runs": [
    {
      "id": "run_coord_1900",
      "terminal": "term_coord_1900"
    }
  ]
}
EOF

make_repo_with_origin() {
  local bare=$1 work=$2
  git init --bare -q -b main "$bare"
  git clone -q "$bare" "$work"
  git -C "$work" config user.email "test@example.com"
  git -C "$work" config user.name "Test"
  echo "initial" >"$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm "initial commit"
  git -C "$work" push -q -u origin main
}

advance_bare_branch() {
  local bare=$1 branch=$2 msg=$3 clone
  clone="$tmp/work-$(basename "$bare" .git)-$$-$RANDOM"
  git clone -q -b "$branch" "$bare" "$clone"
  git -C "$clone" config user.email "test@example.com"
  git -C "$clone" config user.name "Test"
  printf '%s\n' "$msg" >>"$clone/file.txt"
  git -C "$clone" commit -qam "$msg"
  git -C "$clone" push -q origin "$branch"
  rm -rf "$clone"
}

# --- 1. Skip when origin/main == origin/staging ---
repo_a_bare="$tmp/repo-a.git"
repo_a="$tmp/repo-a"
make_repo_with_origin "$repo_a_bare" "$repo_a"
git -C "$repo_a" push -q origin main:staging

# Advance both main and staging in origin so precheck must fetch origin first
advance_bare_branch "$repo_a_bare" main "synced advance"
git --git-dir="$repo_a_bare" update-ref refs/heads/staging refs/heads/main

log1="$tmp/staging-daily-1.log"
: >"$ORCA_LOG"
rc1=0
FLEET_STAGING_REPOS="$repo_a" STAGING_DAILY_LOG="$log1" bash "$script" >/dev/null 2>&1 || rc1=$?
check 'equal main and staging exits 0' test "$rc1" -eq 0
check 'equal main and staging logs skip: staging equals main' grep -q 'skip: staging equals main' "$log1"
check 'equal main and staging does not call orca orchestration send' test ! -s "$ORCA_LOG"

# Verify wrapper exits 1 for Orca precheck contract and traces skip summary
log1_wrap="$tmp/staging-daily-1-wrap.log"
wrap_rc=0
FLEET_STAGING_REPOS="$repo_a" STAGING_DAILY_LOG="$log1_wrap" \
  bash "$wrapper" staging-daily-1900 "$log1_wrap" -- bash "$script" || wrap_rc=$?
check 'wrapper exits 1 so Orca skips LLM run' test "$wrap_rc" -eq 1
check 'wrapper records skip: staging equals main in summary' grep -q 'summary=skip: staging equals main' "$log1_wrap"

# --- 2. Wake coordinator when origin/main is ahead of origin/staging ---
advance_bare_branch "$repo_a_bare" main "new feature on main"
log2="$tmp/staging-daily-2.log"
: >"$ORCA_LOG"
rc2=0
FLEET_STAGING_REPOS="$repo_a" STAGING_DAILY_LOG="$log2" bash "$script" >/dev/null 2>&1 || rc2=$?
check 'ahead origin/main exits 0' test "$rc2" -eq 0
check 'ahead origin/main records ahead repo name in log' grep -q 'repo-a' "$log2"
check 'ahead origin/main sends orchestration wake message' grep -q 'orchestration send' "$ORCA_LOG"
check 'wake message targets active coordinator run' grep -q 'run:run_coord_1900' "$ORCA_LOG"
check 'wake message names ahead repo' grep -q 'repo-a' "$ORCA_LOG"
check 'wake message instructs coordinator to dispatch release-manager' grep -q 'release-manager' "$ORCA_LOG"
check 'wake message instructs coordinator to run /staging-review' grep -q '/staging-review' "$ORCA_LOG"
check 'wake message states production deploy remains gated on owner approval' grep -qi 'production.*owner' "$ORCA_LOG"

# --- 3. Per-component <component>/staging branches in .claude/hooks/guard-config.json & fleet-config.json ---
repo_b_bare="$tmp/repo-b.git"
repo_b="$tmp/repo-b"
make_repo_with_origin "$repo_b_bare" "$repo_b"
mkdir -p "$repo_b/.claude/hooks"
cat >"$repo_b/.claude/hooks/guard-config.json" <<'EOF'
{
  "stage_branches": [
    "web2/staging",
    "web2/production",
    "api/staging",
    "api/production"
  ]
}
EOF
git -C "$repo_b" add .claude/hooks/guard-config.json
git -C "$repo_b" commit -qm "add guard-config"
git -C "$repo_b" push -q origin main
git -C "$repo_b" push -q origin main:web2/staging
git -C "$repo_b" push -q origin main:api/staging

cat >"$tmp/state/fleet-config.json" <<EOF
{
  "hosts": [],
  "repos": ["$repo_b"]
}
EOF

# 3a. All component staging branches equal origin/main -> skip
log3a="$tmp/staging-daily-3a.log"
: >"$ORCA_LOG"
rc3a=0
env -u FLEET_STAGING_REPOS AGENT_STATE_DIR="$tmp/state" STAGING_DAILY_LOG="$log3a" bash "$script" >/dev/null 2>&1 || rc3a=$?
check 'component staging branches equal to main exits 0' test "$rc3a" -eq 0
check 'component staging branches equal to main logs skip' grep -q 'skip: staging equals main' "$log3a"
check 'component staging branches equal to main sends no wake' test ! -s "$ORCA_LOG"

# 3b. Advance origin/main and origin/api/staging, leaving origin/web2/staging behind -> wake naming web2/staging
advance_bare_branch "$repo_b_bare" main "web2 change on main"
git --git-dir="$repo_b_bare" update-ref refs/heads/api/staging refs/heads/main

log3b="$tmp/staging-daily-3b.log"
: >"$ORCA_LOG"
rc3b=0
env -u FLEET_STAGING_REPOS AGENT_STATE_DIR="$tmp/state" STAGING_DAILY_LOG="$log3b" bash "$script" >/dev/null 2>&1 || rc3b=$?
check 'behind component staging branch exits 0' test "$rc3b" -eq 0
check 'behind component staging branch wakes coordinator' grep -q 'orchestration send' "$ORCA_LOG"
check 'wake message records ahead component web2/staging' grep -q 'web2/staging' "$ORCA_LOG"
if grep -q 'api/staging' "$ORCA_LOG"; then
  check 'up-to-date component api/staging is not listed as ahead' false
else
  check 'up-to-date component api/staging is not listed as ahead' true
fi

# --- 4. Documentation in docs/agents/orca-automations.md ---
check 'docs/agents/orca-automations.md documents staging-daily-1900' grep -q 'staging-daily-1900' "$doc"
check 'docs/agents/orca-automations.md documents 0 19 * * *' grep -q '0 19 \* \* \*' "$doc"
check 'docs/agents/orca-automations.md documents Asia/Taipei' grep -q 'Asia/Taipei' "$doc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
