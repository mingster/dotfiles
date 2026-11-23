#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# automation-precheck-*.sh arguments: -h and --help print one Usage line and exit 0, any other argument
# exits 2 with that Usage line on stderr. Either way the job does not run and writes no log. The wrapper
# prints its Usage line for -h, --help, and missing arguments, and still exits 1 when the job ran fine.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
mkdir -p "$work/home" "$work/script"
cp "$root/script/automation-precheck-"*.sh "$work/script/"

# The real job never runs here: HOME and every log path point into $work and the configs are missing.
# Any file under $work/home/.local means a precheck ran past its argument check.
prechecks=(sync-drift team-audit-weekly weekly-update staging-daily)

check() { # check <ok-bool> <label> [detail]
  if [ "$1" = true ]; then
    pass=$((pass + 1)); echo "ok   $2"
  else
    fail=$((fail + 1)); echo "FAIL $2 ${3:-}"
  fi
}

run_precheck() { # run_precheck <script-name> <args...>; sets rc and out
  local name=$1; shift
  rm -rf "$work/home/.local"
  set +e
  out=$(HOME="$work/home" DOTFILES="$work" TEAM_AUDIT_CONF="$work/none.conf" \
    AGENT_STATE_DIR="$work/state" FLEET_PULL_CONFIG="$work/none.json" FLEET_WATCH_CONFIG="$work/none.json" \
    WEEKLY_UPDATE_LOG="$work/home/.local/state/agent-team/weekly-update.log" \
    bash "$work/script/automation-precheck-$name.sh" "$@" 2>&1)
  rc=$?
  set -e
}

for name in "${prechecks[@]}"; do
  usage="Usage: automation-precheck-$name.sh [-h|--help]"
  for flag in -h --help; do
    run_precheck "$name" "$flag"
    check "$([ "$rc" = 0 ] && grep -qxF -- "$usage" <<<"$out" && echo true || echo false)" \
      "$name $flag prints one usage line and exits 0" "(rc=$rc out=$out)"
    check "$([ -z "$(ls -A "$work/home/.local" 2>/dev/null)" ] && echo true || echo false)" \
      "$name $flag writes no log"
  done
  # No arguments is the scheduled run, so it is not in this list.
  for bad in --bogus extra "-h extra"; do
    # shellcheck disable=SC2086
    run_precheck "$name" $bad
    check "$([ "$rc" = 2 ] && grep -qF -- "$usage" <<<"$out" && echo true || echo false)" \
      "$name argument '$bad' exits 2 with usage" "(rc=$rc out=$out)"
    check "$([ -z "$(ls -A "$work/home/.local" 2>/dev/null)" ] && echo true || echo false)" \
      "$name argument '$bad' runs no job and writes no log"
  done
done

# The wrapper: usage for -h, --help, and missing arguments; the job-ran contract (exit 1, never 0) holds.
wrap_usage='Usage: automation-precheck-wrapper.sh <name> <log-path> -- <command...>'
wrap() { # wrap <args...>; sets rc and out
  set +e
  out=$(HOME="$work/home" bash "$root/script/automation-precheck-wrapper.sh" "$@" 2>&1)
  rc=$?
  set -e
}
for flag in -h --help; do
  wrap "$flag"
  check "$([ "$rc" = 0 ] && grep -qxF -- "$wrap_usage" <<<"$out" && echo true || echo false)" \
    "wrapper $flag prints its usage line and exits 0" "(rc=$rc out=$out)"
done
wrap
check "$([ "$rc" = 2 ] && grep -qF -- "$wrap_usage" <<<"$out" && echo true || echo false)" \
  "wrapper with no arguments exits 2 with usage" "(rc=$rc out=$out)"
wrap only-name
check "$([ "$rc" = 2 ] && grep -qF -- "$wrap_usage" <<<"$out" && echo true || echo false)" \
  "wrapper with one argument exits 2 with usage" "(rc=$rc out=$out)"
wrap fake-name "$work/wrap.log" -- true
check "$([ "$rc" = 1 ] && grep -q 'phase=end exit=0' "$work/wrap.log" && echo true || echo false)" \
  "wrapper with a passing job exits 1 and logs the end line" "(rc=$rc out=$out)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
