#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tests for install-fleet-automations.sh with a fake orca CLI (never touches live automations).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
script="$root/script/install-fleet-automations.sh"
_real_home=${DOTFILES_REAL_HOME:-${TEST_REAL_HOME:-}}
if [ -z "$_real_home" ]; then
  _real_home=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
fi
# shellcheck source=script/tests/lib/asdf-pin.sh disable=SC1091,SC2015
. "$here/lib/asdf-pin.sh"
_asdf_data=${ASDF_DATA_DIR:-$_real_home/.asdf}
_py_ver=${ASDF_PYTHON_VERSION:-$(awk '$1 == "python" { print $2; exit }' "$root/.tool-versions")}
python3_bin="$_asdf_data/installs/python/$_py_ver/bin/python3"
[ -x "$python3_bin" ] || python3_bin=$(ASDF_DATA_DIR="$_asdf_data" asdf which python3 2>/dev/null || true)
[ -x "$python3_bin" ] || python3_bin=$(command -v python3 2>/dev/null || true)
[ -x "$python3_bin" ] || { echo "FAIL: no python3 for fake orca tests" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export ASDF_DATA_DIR="$_asdf_data"
mkdir -p "$HOME/.config/fleet-watch" "$HOME/agent-state" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export FLEET_AUTOMATIONS_ENV="$HOME/.config/fleet-watch/automations.env"
export DOTFILES_DIR="$root"
export FLEET_WATCH_CONFIG="$HOME/config/fleet-watch.json"
export FLEET_WATCH_STATE="$HOME/state/fleet-watch.state.json"
export FLEET_WATCH_PRECHECK_LOG="$HOME/logs/fleet-watch-precheck.log"
printf '%s\n' \
  "DOTFILES_DIR=$DOTFILES_DIR" \
  "FLEET_WATCH_CONFIG=$FLEET_WATCH_CONFIG" \
  "FLEET_WATCH_STATE=$FLEET_WATCH_STATE" \
  "FLEET_WATCH_PRECHECK_LOG=$FLEET_WATCH_PRECHECK_LOG" \
  >"$FLEET_AUTOMATIONS_ENV"

cat >"$tmp/bin/hostname" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_HOSTNAME:-throwaway}"
EOS
chmod +x "$tmp/bin/hostname"

FAKE_ORCA_PY="$root/script/tests/lib/fake-orca-automations.py"
export FAKE_ORCA_PY
export FAKE_ORCA_STORE="$tmp/orca-automations.json"

cat >"$tmp/bin/orca" <<EOS
#!/usr/bin/env bash
export ASDF_DATA_DIR="$_asdf_data"
export ASDF_PYTHON_VERSION="\${ASDF_PYTHON_VERSION:-}"
exec "$python3_bin" "$FAKE_ORCA_PY" "\$@"
EOS
chmod +x "$tmp/bin/orca"

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

shellcheck -x --severity=error "$script"

export FAKE_HOSTNAME=throwaway
missing_coord_rc=0
missing_coord_out=$(bash "$script" --install 2>&1) || missing_coord_rc=$?
check 'missing coordinator.conf exits non-zero' test "$missing_coord_rc" -ne 0
echo "$missing_coord_out" | grep -q 'coordinator.conf' && check 'missing coordinator.conf names coordinator.conf' true || check 'missing coordinator.conf names coordinator.conf' false

printf 'coordinator coord-host\n' >"$HOME/agent-state/coordinator.conf"

dry=$(bash "$script" --dry-run --install 2>&1)
over=$(echo "$dry" | grep -oE -- '--precheck-timeout [0-9]+' | awk '$2 > 600' | head -1)
[ -z "$over" ] && check 'every precheck timeout fits the Orca 600s cap' true || check "every precheck timeout fits the Orca 600s cap ($over)" false
echo "$dry" | grep -q '\[dry-run\]' && echo "$dry" | grep -q 'fleet-watch' && check 'dry-run prints fleet-watch create' true || check 'dry-run prints fleet-watch create' false
echo "$dry" | grep -q 'wrap-up-scheduled' && check 'dry-run prints wrap-up create' true || check 'dry-run prints wrap-up create' false
echo "$dry" | grep -q 'sync-team-skills-drift' && check 'dry-run prints sync drift create' true || check 'dry-run prints sync drift create' false
echo "$dry" | grep -q 'team-audit-weekly' && check 'dry-run prints team audit create' true || check 'dry-run prints team audit create' false
echo "$dry" | grep -q 'weekly-update' && check 'dry-run prints weekly-update create' true || check 'dry-run prints weekly-update create' false
echo "$dry" | grep -q 'fleet-toolchain' && check 'dry-run prints fleet-toolchain create' true || check 'dry-run prints fleet-toolchain create' false
echo "$dry" | grep -q 'daily-program-1900' && check 'dry-run prints daily-program-1900 create' true || check 'dry-run prints daily-program-1900 create' false
echo "$dry" | grep -q 'staging-daily-1900' && check 'dry-run prints no staging-daily-1900' false || check 'dry-run prints no staging-daily-1900' true
echo "$dry" | grep -q '0 19 \* \* \*' && check 'dry-run includes 0 19 * * * schedule for daily-program-1900' true || check 'dry-run includes 0 19 * * * schedule for daily-program-1900' false
echo "$dry" | grep -q 'Asia/Taipei' && check 'dry-run includes Asia/Taipei timezone for daily-program-1900' true || check 'dry-run includes Asia/Taipei timezone for daily-program-1900' false
echo "$dry" | grep -q 'would create' && check 'dry-run labels would-create' true || check 'dry-run labels would-create' false
[ ! -f "$FAKE_ORCA_STORE" ] && check 'dry-run leaves store absent' true || check 'dry-run leaves store absent' false

first=$(bash "$script" --install 2>&1)
echo "$first" | grep -q 'fleet-watch created' && check 'first install creates fleet-watch' true || check 'first install creates fleet-watch' false
echo "$first" | grep -q 'wrap-up-scheduled created' && check 'first install creates wrap-up-scheduled' true || check 'first install creates wrap-up-scheduled' false
echo "$first" | grep -q 'sync-team-skills-drift created' && check 'first install creates sync drift' true || check 'first install creates sync drift' false
echo "$first" | grep -q 'team-audit-weekly created' && check 'first install creates team audit weekly' true || check 'first install creates team audit weekly' false
echo "$first" | grep -q 'weekly-update created' && check 'first install creates weekly-update' true || check 'first install creates weekly-update' false
echo "$first" | grep -q 'fleet-toolchain created' && check 'first install creates fleet-toolchain' true || check 'first install creates fleet-toolchain' false
echo "$first" | grep -q 'daily-program-1900 created' && check 'first install creates daily-program-1900' true || check 'first install creates daily-program-1900' false

status_off=$(bash "$script" --status)
echo "$status_off" | grep -q 'fleet-watch: disabled' && check 'non-coordinator status disabled fleet-watch' true || check 'non-coordinator status disabled fleet-watch' false
echo "$status_off" | grep -q 'wrap-up-scheduled: enabled' && check 'non-coordinator status enabled wrap-up' true || check 'non-coordinator status enabled wrap-up' false
echo "$status_off" | grep -q 'daily-program-1900: disabled' && check 'non-coordinator status disabled daily-program-1900' true || check 'non-coordinator status disabled daily-program-1900' false

# Re-running the installer on a non-coordinator host fixes a stale rrule (0 */2 * * *) and a disabled entry.
python3 - <<'PY'
import json, os
p = os.environ["FAKE_ORCA_STORE"]
d = json.load(open(p))
for a in d["automations"]:
    if a["name"] == "wrap-up-scheduled":
        a["rrule"] = "0 */2 * * *"
        a["enabled"] = False
json.dump(d, open(p, "w"))
PY
fix_stale=$(bash "$script" --install 2>&1)
echo "$fix_stale" | grep -q 'wrap-up-scheduled updated' && check 're-run updates stale disabled wrap-up-scheduled' true || check 're-run updates stale disabled wrap-up-scheduled' false
stale_fixed_ok=0
if python3 - <<'PY'
import json, os, sys
d = json.load(open(os.environ["FAKE_ORCA_STORE"]))
by_name = {a["name"]: a for a in d["automations"]}
w = by_name["wrap-up-scheduled"]
f = by_name["fleet-watch"]
if w.get("rrule") != "*/10 * * * *" or not w.get("enabled") or f.get("enabled"):
    sys.exit(1)
PY
then
  stale_fixed_ok=1
fi
check 're-run fixes stale 0 */2 * * * rrule and enables wrap-up while keeping fleet-watch disabled' test "$stale_fixed_ok" -eq 1
echo "$status_off" | grep -q 'fleet-toolchain: disabled' && check 'non-coordinator status disabled fleet-toolchain' true || check 'non-coordinator status disabled fleet-toolchain' false

# A host that still has the old staging-daily-1900 entry loses it on re-install (#834).
python3 - <<'PY'
import json, os
p = os.environ["FAKE_ORCA_STORE"]
d = json.load(open(p))
old = dict(next(a for a in d["automations"] if a["name"] == "daily-program-1900"))
old["id"] = "auto_legacy_staging"
old["name"] = "staging-daily-1900"
d["automations"].append(old)
json.dump(d, open(p, "w"))
PY
legacy=$(bash "$script" --install 2>&1)
echo "$legacy" | grep -q 'staging-daily-1900 removed' && check 're-install removes legacy staging-daily-1900' true || check 're-install removes legacy staging-daily-1900' false

ids=$(python3 -c 'import json, os; d=json.load(open(os.environ["FAKE_ORCA_STORE"])); print(" ".join(a["id"] for a in d["automations"]))')

second=$(bash "$script" --install 2>&1)
echo "$second" | grep -q 'unchanged' && check 'second install reports unchanged' true || check 'second install reports unchanged' false
ids2=$(python3 -c 'import json, os; d=json.load(open(os.environ["FAKE_ORCA_STORE"])); print(" ".join(a["id"] for a in d["automations"]))')
[ "$ids" = "$ids2" ] && check 'second install keeps automation ids' true || check 'second install keeps automation ids' false

export FAKE_HOSTNAME=coord-host
coord=$(bash "$script" --install 2>&1)
echo "$coord" | grep -q 'updated\|unchanged' && check 'coordinator install settles' true || check 'coordinator install settles' false
coord_status=$(bash "$script" --status)
echo "$coord_status" | grep -q 'fleet-watch: enabled' && check 'coordinator status enabled fleet-watch' true || check 'coordinator status enabled fleet-watch' false
echo "$coord_status" | grep -q 'wrap-up-scheduled: enabled' && check 'coordinator status enabled wrap-up' true || check 'coordinator status enabled wrap-up' false
echo "$coord_status" | grep -q 'fleet-toolchain: enabled' && check 'coordinator status enabled fleet-toolchain' true || check 'coordinator status enabled fleet-toolchain' false
echo "$coord_status" | grep -q 'daily-program-1900: enabled' && check 'coordinator status enabled daily-program-1900' true || check 'coordinator status enabled daily-program-1900' false
echo "$coord_status" | grep -q 'sync-team-skills-drift: disabled' && check 'coordinator creates sync-team-skills-drift disabled (owner opt-in)' true || check 'coordinator creates sync-team-skills-drift disabled (owner opt-in)' false
echo "$coord_status" | grep -q 'team-audit-weekly: disabled' && check 'coordinator creates team-audit-weekly disabled (owner opt-in)' true || check 'coordinator creates team-audit-weekly disabled (owner opt-in)' false
echo "$coord_status" | grep -q 'weekly-update: disabled' && check 'coordinator creates weekly-update disabled (owner opt-in)' true || check 'coordinator creates weekly-update disabled (owner opt-in)' false
[ "$(python3 -c 'import json, os; print(len(json.load(open(os.environ["FAKE_ORCA_STORE"]))["automations"]))')" -eq 7 ] \
  && check 'coordinator install has seven automations' true || check 'coordinator install has seven automations' false

fw_id=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "fleet-watch":
        print(a["id"]); break
')
"$tmp/bin/orca" automations run "$fw_id" --json >/dev/null
runs=$( "$tmp/bin/orca" automations runs --id "$fw_id" --json )
echo "$runs" | grep -q 'skipped_precheck' && check 'run history shows skipped_precheck' true || check 'run history shows skipped_precheck' false

un=$(bash "$script" --uninstall 2>&1)
echo "$un" | grep -q 'fleet-watch removed' && check 'uninstall removes fleet-watch' true || check 'uninstall removes fleet-watch' false
echo "$un" | grep -q 'wrap-up-scheduled removed' && check 'uninstall removes wrap-up-scheduled' true || check 'uninstall removes wrap-up-scheduled' false
echo "$un" | grep -q 'sync-team-skills-drift removed' && check 'uninstall removes sync drift' true || check 'uninstall removes sync drift' false
echo "$un" | grep -q 'team-audit-weekly removed' && check 'uninstall removes team audit weekly' true || check 'uninstall removes team audit weekly' false
echo "$un" | grep -q 'weekly-update removed' && check 'uninstall removes weekly-update' true || check 'uninstall removes weekly-update' false
echo "$un" | grep -q 'fleet-toolchain removed' && check 'uninstall removes fleet-toolchain' true || check 'uninstall removes fleet-toolchain' false
echo "$un" | grep -q 'daily-program-1900 removed' && check 'uninstall removes daily-program-1900' true || check 'uninstall removes daily-program-1900' false
[ "$(python3 -c 'import json, os; print(len(json.load(open(os.environ["FAKE_ORCA_STORE"]))["automations"]))')" -eq 0 ] \
  && check 'uninstall empties store' true || check 'uninstall empties store' false

re=$(bash "$script" --install 2>&1)
echo "$re" | grep -q 'created' && check 'reinstall after uninstall recreates' true || check 'reinstall after uninstall recreates' false

fleet_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "fleet-watch":
        print(a["precheck"]["command"])
        print(a["precheck"]["timeoutSeconds"])
        print(a["rrule"])
')
echo "$fleet_pc" | grep -q 'automation-precheck-wrapper.sh' && check 'fleet precheck uses trace wrapper' true || check 'fleet precheck uses trace wrapper' false
echo "$fleet_pc" | grep -q 'fleet-watch.py' && check 'fleet precheck runs fleet-watch.py' true || check 'fleet precheck runs fleet-watch.py' false
echo "$fleet_pc" | grep -q 'exit 1' && check 'fleet precheck ends with exit 1' true || check 'fleet precheck ends with exit 1' false
echo "$fleet_pc" | grep -q "$FLEET_WATCH_CONFIG" && check 'fleet precheck uses env config path' true || check 'fleet precheck uses env config path' false
echo "$fleet_pc" | grep -q '\*/5 \* \* \* \*' && check 'fleet-watch schedule is 5 min' true || check 'fleet-watch schedule is 5 min' false
echo "$fleet_pc" | grep -q '^280$' && check 'fleet-watch timeout 280' true || check 'fleet-watch timeout 280' false

wrap_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "wrap-up-scheduled":
        print(a["precheck"]["command"])
        print(a["rrule"])
')
echo "$wrap_pc" | grep -q 'automation-precheck-wrapper.sh' && check 'wrap precheck uses trace wrapper' true || check 'wrap precheck uses trace wrapper' false
echo "$wrap_pc" | grep -q 'wrap-up.sh' && check 'wrap precheck runs wrap-up.sh --scheduled' true || check 'wrap precheck runs wrap-up.sh --scheduled' false
echo "$wrap_pc" | grep -q '\*/10 \* \* \* \*' && check 'wrap-up schedule is 10 min' true || check 'wrap-up schedule is 10 min' false

echo "$wrap_pc" | grep -q 'WRAP_UP_ISSUE_REPO=mingster/agent-state' && check 'wrap precheck defaults WRAP_UP_ISSUE_REPO to the private agent-state repo' true || check 'wrap precheck defaults WRAP_UP_ISSUE_REPO to the private agent-state repo' false

# WRAP_UP_ISSUE_REPO is passed from automations.env when set.
printf '%s\n' \
  "DOTFILES_DIR=$DOTFILES_DIR" \
  "FLEET_WATCH_CONFIG=$FLEET_WATCH_CONFIG" \
  "FLEET_WATCH_STATE=$FLEET_WATCH_STATE" \
  "FLEET_WATCH_PRECHECK_LOG=$FLEET_WATCH_PRECHECK_LOG" \
  "WRAP_UP_ISSUE_REPO=owner/private-issues" \
  >"$FLEET_AUTOMATIONS_ENV"
bash "$script" --install >/dev/null 2>&1
wrap_issue_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "wrap-up-scheduled":
        print(a["precheck"]["command"])
')
echo "$wrap_issue_pc" | grep -q 'WRAP_UP_ISSUE_REPO=owner/private-issues' && check 'wrap precheck passes WRAP_UP_ISSUE_REPO from automations.env' true || check 'wrap precheck passes WRAP_UP_ISSUE_REPO from automations.env' false

# A host without the Orca app is skipped with a clear message and exits 0.
no_orca_store="$tmp/no-orca-store.json"
no_orca_rc=0
no_orca_out=$(env -u ORCA_CLI_COMMAND FLEET_ORCA_APP_BIN="$tmp/no-orca-app" FAKE_ORCA_STORE="$no_orca_store" HOME="$tmp/no-orca-home" PATH="/usr/bin:/bin" DOTFILES_DIR="$root" bash "$script" --install 2>&1) || no_orca_rc=$?
check 'host without Orca app exits 0' test "$no_orca_rc" -eq 0
echo "$no_orca_out" | grep -iq 'skip.*orca' && check 'host without Orca app prints clear skip message' true || check 'host without Orca app prints clear skip message' false
check 'host without Orca app leaves store untouched' test ! -f "$no_orca_store"

sync_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "sync-team-skills-drift":
        print(a["precheck"]["command"])
        print(a["rrule"])
')
echo "$sync_pc" | grep -q 'automation-precheck-sync-drift' && check 'sync precheck script' true || check 'sync precheck script' false
echo "$sync_pc" | grep -q '0 6 \* \* \*' && check 'sync drift schedule daily' true || check 'sync drift schedule daily' false

audit_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "team-audit-weekly":
        print(a["precheck"]["command"])
        print(a["rrule"])
')
echo "$audit_pc" | grep -q 'automation-precheck-team-audit-weekly' && check 'team audit precheck script' true || check 'team audit precheck script' false
echo "$audit_pc" | grep -q '0 7 \* \* 1' && check 'team audit schedule weekly monday' true || check 'team audit schedule weekly monday' false

weekly_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "weekly-update":
        print(a["precheck"]["command"])
        print(a["rrule"])
')
echo "$weekly_pc" | grep -q 'automation-precheck-weekly-update' && check 'weekly-update precheck script' true || check 'weekly-update precheck script' false
echo "$weekly_pc" | grep -q '0 8 \* \* 1' && check 'weekly-update schedule monday 08:00' true || check 'weekly-update schedule monday 08:00' false

toolchain_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "fleet-toolchain":
        print(a["precheck"]["command"])
        print(a["rrule"])
')
echo "$toolchain_pc" | grep -q 'automation-precheck-wrapper.sh' && check 'fleet-toolchain precheck uses trace wrapper' true || check 'fleet-toolchain precheck uses trace wrapper' false
echo "$toolchain_pc" | grep -q 'fleet-pull.sh' && check 'fleet-toolchain precheck runs fleet-pull.sh' true || check 'fleet-toolchain precheck runs fleet-pull.sh' false
echo "$toolchain_pc" | grep -q 'fleet-toolchain-check.sh.*--apply' && check 'fleet-toolchain precheck runs fleet-toolchain-check.sh --apply' true || check 'fleet-toolchain precheck runs fleet-toolchain-check.sh --apply' false
echo "$toolchain_pc" | grep -qE '0 [0-9]+ \* \* \*' && check 'fleet-toolchain schedule is daily' true || check 'fleet-toolchain schedule is daily' false

staging_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a["name"] == "daily-program-1900":
        print(a["precheck"]["command"])
        print(a["rrule"])
        print(a.get("timezone") or "")
')
echo "$staging_pc" | grep -q 'automation-precheck-wrapper.sh' && check 'daily-program-1900 precheck uses trace wrapper' true || check 'daily-program-1900 precheck uses trace wrapper' false
echo "$staging_pc" | grep -q 'automation-precheck-staging-daily.sh' && check 'daily-program-1900 precheck runs automation-precheck-staging-daily.sh' true || check 'daily-program-1900 precheck runs automation-precheck-staging-daily.sh' false
echo "$staging_pc" | grep -q 'exit 1' && check 'daily-program-1900 precheck ends with exit 1' true || check 'daily-program-1900 precheck ends with exit 1' false
echo "$staging_pc" | grep -q '^0 19 \* \* \*$' && check 'daily-program-1900 schedule is 0 19 * * *' true || check 'daily-program-1900 schedule is 0 19 * * *' false
echo "$staging_pc" | grep -q '^Asia/Taipei$' && check 'daily-program-1900 timezone defaults to Asia/Taipei' true || check 'daily-program-1900 timezone defaults to Asia/Taipei' false

symlink_dir="$tmp/dotfiles-link"
ln -sfn "$root" "$symlink_dir"
canonical_root=$(cd "$root" && pwd -P)
printf '%s\n' \
  "DOTFILES_DIR=$symlink_dir" \
  "FLEET_WATCH_CONFIG=$FLEET_WATCH_CONFIG" \
  "FLEET_WATCH_STATE=$FLEET_WATCH_STATE" \
  "FLEET_WATCH_PRECHECK_LOG=$FLEET_WATCH_PRECHECK_LOG" \
  >"$FLEET_AUTOMATIONS_ENV"
rm -f "$FAKE_ORCA_STORE"
bash "$script" --install >/dev/null 2>&1
link_repo=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a.get("name") == "fleet-watch":
        print(a.get("repo") or "")
        break
')
[ "$link_repo" = "path:$canonical_root" ] && check 'repo path uses canonical dotfiles' true || check 'repo path uses canonical dotfiles' false

rm -f "$FAKE_ORCA_STORE"
FAKE_ORCA_REPOS="[{\"id\":\"repo-1\",\"path\":\"$symlink_dir\"}]" bash "$script" --install >/dev/null 2>&1 || true
id_repo=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
print(next((a.get("repo") or "") for a in d["automations"] if a.get("name") == "fleet-watch"))
')
[ "$id_repo" = "id:repo-1" ] && check 'repo registered under a symlink is selected by id' true || check "repo registered under a symlink is selected by id ($id_repo)" false

mkdir -p "$HOME/.claude/state"
printf '%s\n' '{"runs":[{"id":"run_live","terminal":"term_live","waiter_pattern":"check"}]}' > "$HOME/.claude/state/fleet-watch-elon.json"
printf '%s\n' "DOTFILES_DIR=$DOTFILES_DIR" "FLEET_WATCH_STATE=$FLEET_WATCH_STATE" >"$FLEET_AUTOMATIONS_ENV"
rm -f "$FAKE_ORCA_STORE"
env -u FLEET_WATCH_CONFIG bash "$script" --install >/dev/null 2>&1
coord_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a.get("name") == "fleet-watch":
        print((a.get("precheck") or {}).get("command") or "")
')
echo "$coord_pc" | grep -q '/.claude/state/fleet-watch-elon.json' && check 'unset config uses the coordinator file' true || check 'unset config uses the coordinator file' false
printf '%s\n' '{"runs":[]}' > "$HOME/.claude/state/fleet-watch-elon.json"
rm -f "$FAKE_ORCA_STORE"
env -u FLEET_WATCH_CONFIG bash "$script" --install >/dev/null 2>&1
stub_pc=$(python3 -c '
import json, os
d=json.load(open(os.environ["FAKE_ORCA_STORE"]))
for a in d["automations"]:
    if a.get("name") == "fleet-watch":
        print((a.get("precheck") or {}).get("command") or "")
')
echo "$stub_pc" | grep -q '/.config/fleet-watch/config.json' && check 'coordinator file without runs keeps the stub config' true || check 'coordinator file without runs keeps the stub config' false
printf '%s\n' \
  "DOTFILES_DIR=$DOTFILES_DIR" \
  "FLEET_WATCH_CONFIG=$FLEET_WATCH_CONFIG" \
  "FLEET_WATCH_STATE=$FLEET_WATCH_STATE" \
  "FLEET_WATCH_PRECHECK_LOG=$FLEET_WATCH_PRECHECK_LOG" \
  >"$FLEET_AUTOMATIONS_ENV"

fake_wt="$tmp/fake-worktree/script"
mkdir -p "$fake_wt" "$HOME/dotfiles/script"
cp "$script" "$fake_wt/install-fleet-automations.sh"
touch "$HOME/dotfiles/script/fleet-watch.py"
canonical_home_dotfiles=$(cd "$HOME/dotfiles" && pwd -P)
unset DOTFILES_DIR
rm -f "$FLEET_AUTOMATIONS_ENV" "$FAKE_ORCA_STORE"
wt_install_ok=0
bash "$fake_wt/install-fleet-automations.sh" --install >/dev/null 2>&1 && wt_install_ok=1
check 'worktree copy install succeeds with HOME/dotfiles' test "$wt_install_ok" -eq 1
wt_cmds_ok=0
if [ -f "$FAKE_ORCA_STORE" ]; then
  if CANON_HOME_DOTFILES="$canonical_home_dotfiles" FAKE_WT="$fake_wt" python3 - <<'PY'
import json, os, sys
d = json.load(open(os.environ["FAKE_ORCA_STORE"]))
autos = d.get("automations", [])
if len(autos) != 7:
    sys.exit(1)
want = os.environ["CANON_HOME_DOTFILES"]
bad = os.environ["FAKE_WT"]
for a in autos:
    cmd = (a.get("precheck") or {}).get("command") or ""
    repo = a.get("repo") or ""
    if want not in cmd or bad in cmd or repo != f"path:{want}":
        sys.exit(1)
PY
  then
    wt_cmds_ok=1
  fi
fi
check 'worktree copy precheck commands reference HOME/dotfiles not worktree' test "$wt_cmds_ok" -eq 1

rm -rf "$HOME/dotfiles"
missing_rc=0
missing_out=$(bash "$fake_wt/install-fleet-automations.sh" --install 2>&1) || missing_rc=$?
check 'missing HOME/dotfiles exits non-zero' test "$missing_rc" -ne 0
missing_lines=$(printf '%s\n' "$missing_out" | awk 'NF { c++ } END { print c+0 }')
check 'missing HOME/dotfiles prints one line reason' test "$missing_lines" -eq 1

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
