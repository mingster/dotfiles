#!/usr/bin/env bash
# Tests for install-fleet-automations.sh with a fake orca CLI (never touches live automations).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd -P)
script="$root/script/install-fleet-automations.sh"
_real_home=${DOTFILES_REAL_HOME:-${TEST_REAL_HOME:-}}
if [ -z "$_real_home" ]; then
  _real_home=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
fi
# shellcheck source=lib/asdf-pin.sh
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
printf 'coordinator mini6\n' >"$HOME/agent-state/coordinator.conf"

dry=$(bash "$script" --dry-run --install 2>&1)
echo "$dry" | grep -q '\[dry-run\]' && echo "$dry" | grep -q 'fleet-watch' && check 'dry-run prints fleet-watch create' true || check 'dry-run prints fleet-watch create' false
echo "$dry" | grep -q 'wrap-up-scheduled' && check 'dry-run prints wrap-up create' true || check 'dry-run prints wrap-up create' false
echo "$dry" | grep -q 'would create' && check 'dry-run labels would-create' true || check 'dry-run labels would-create' false
[ ! -f "$FAKE_ORCA_STORE" ] && check 'dry-run leaves store absent' true || check 'dry-run leaves store absent' false

first=$(bash "$script" --install 2>&1)
echo "$first" | grep -q 'fleet-watch created' && check 'first install creates fleet-watch' true || check 'first install creates fleet-watch' false
echo "$first" | grep -q 'wrap-up-scheduled created' && check 'first install creates wrap-up-scheduled' true || check 'first install creates wrap-up-scheduled' false

status_off=$(bash "$script" --status)
echo "$status_off" | grep -q 'fleet-watch: disabled' && check 'non-coordinator status disabled fleet-watch' true || check 'non-coordinator status disabled fleet-watch' false
echo "$status_off" | grep -q 'wrap-up-scheduled: disabled' && check 'non-coordinator status disabled wrap-up' true || check 'non-coordinator status disabled wrap-up' false

ids=$(python3 -c 'import json, os; d=json.load(open(os.environ["FAKE_ORCA_STORE"])); print(" ".join(a["id"] for a in d["automations"]))')

second=$(bash "$script" --install 2>&1)
echo "$second" | grep -q 'unchanged' && check 'second install reports unchanged' true || check 'second install reports unchanged' false
ids2=$(python3 -c 'import json, os; d=json.load(open(os.environ["FAKE_ORCA_STORE"])); print(" ".join(a["id"] for a in d["automations"]))')
[ "$ids" = "$ids2" ] && check 'second install keeps automation ids' true || check 'second install keeps automation ids' false

export FAKE_HOSTNAME=mini6
coord=$(bash "$script" --install 2>&1)
echo "$coord" | grep -q 'updated\|unchanged' && check 'coordinator install settles' true || check 'coordinator install settles' false
coord_status=$(bash "$script" --status)
echo "$coord_status" | grep -q 'fleet-watch: enabled' && check 'coordinator status enabled fleet-watch' true || check 'coordinator status enabled fleet-watch' false
echo "$coord_status" | grep -q 'wrap-up-scheduled: enabled' && check 'coordinator status enabled wrap-up' true || check 'coordinator status enabled wrap-up' false

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
echo "$wrap_pc" | grep -q 'wrap-up.sh' && check 'wrap precheck runs wrap-up.sh --scheduled' true || check 'wrap precheck runs wrap-up.sh --scheduled' false
echo "$wrap_pc" | grep -q '0 \*/2 \* \* \*' && check 'wrap-up schedule is 2 h' true || check 'wrap-up schedule is 2 h' false

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
