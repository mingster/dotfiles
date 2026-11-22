#!/usr/bin/env bash
# automation-precheck-sync-drift.sh, -team-audit-weekly.sh and -weekly-update.sh: each logs what a silent
# unattended run needs (skip line, expanded paths, exit codes). Stub agent-team.sh, team-audit.sh and
# weekly-update.sh under a temp DOTFILES and HOME.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
passed=0
failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed + 1)); else printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); fi; }

dot="$tmp/dotfiles"
mkdir -p "$dot/script"
for w in sync-drift team-audit-weekly weekly-update; do
  cp "$root/script/automation-precheck-$w.sh" "$dot/script/"
done
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$dot/script/$1"; }
stub agent-team.sh 'printf "check args: %s\n" "$*"; exit "${STUB_CHECK_EXIT:-0}"'
stub team-audit.sh 'printf "metrics=%s\n" "${TEAM_AUDIT_RUN_METRICS-unset}"'
stub weekly-update.sh 'exit "${STUB_WEEKLY_EXIT:-0}"'
export DOTFILES="$dot"

# sync-drift
log="$tmp/drift.log"
conf="$tmp/team-audit.conf"
run_drift() { SYNC_DRIFT_LOG="$log" TEAM_AUDIT_CONF="$conf" bash "$dot/script/automation-precheck-sync-drift.sh"; }

: >"$log"; rm -f "$conf"
run_drift; rc=$?
check 'sync-drift: no config exits 0' test "$rc" -eq 0
check 'sync-drift: no config logs the skip line' grep -q "^skip: no project roots in $conf\$" "$log"
check 'sync-drift: no config does not run check' bash -c "! grep -q 'check args' '$log'"

: >"$log"; printf '# comment\n\n~/proj-a\n/abs/proj-b\n' >"$conf"
run_drift
check 'sync-drift: ~ path is expanded to HOME' grep -q "check args: check $HOME/proj-a /abs/proj-b\$" "$log"
check 'sync-drift: passing check logs no failure line' bash -c "! grep -q 'drift or check failure' '$log'"

: >"$log"
STUB_CHECK_EXIT=3 run_drift; rc=$?
check 'sync-drift: failing check logs the exit code' grep -q '^drift or check failure (exit 3)$' "$log"
check 'sync-drift: failing check still exits 0' test "$rc" -eq 0

# team-audit-weekly: PATH without bun
bin="$tmp/bin"
mkdir -p "$bin"
for c in bash date mkdir dirname printf; do ln -sf "$(command -v "$c")" "$bin/$c"; done
: >"$dot/script/team-audit-metrics.ts"
log="$tmp/audit.log"
: >"$log"
PATH="$bin" TEAM_AUDIT_WEEKLY_LOG="$log" "$bin/bash" "$dot/script/automation-precheck-team-audit-weekly.sh"
check 'team-audit-weekly: no bun logs the skip' grep -q '^skip: team-audit-metrics.ts or bun unavailable$' "$log"
check 'team-audit-weekly: no bun sets TEAM_AUDIT_RUN_METRICS=0' grep -q '^metrics=0$' "$log"

printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/bun"; chmod +x "$bin/bun"
: >"$log"
PATH="$bin" TEAM_AUDIT_WEEKLY_LOG="$log" "$bin/bash" "$dot/script/automation-precheck-team-audit-weekly.sh"
check 'team-audit-weekly: bun present sets TEAM_AUDIT_RUN_METRICS=1' grep -q '^metrics=1$' "$log"

# weekly-update
log="$tmp/weekly.log"
: >"$log"
WEEKLY_UPDATE_LOG="$log" bash "$dot/script/automation-precheck-weekly-update.sh"
check 'weekly-update: success logs no failure' bash -c "! grep -q 'weekly-update failed' '$log'"
STUB_WEEKLY_EXIT=7 WEEKLY_UPDATE_LOG="$log" bash "$dot/script/automation-precheck-weekly-update.sh"
check 'weekly-update: failing run logs the exit code' grep -q '^weekly-update failed (exit 7)$' "$log"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
