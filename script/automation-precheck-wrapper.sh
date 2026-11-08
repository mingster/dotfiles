#!/usr/bin/env bash
# Orca fleet automation precheck wrapper: one traceable start and end line per run.
# Usage: automation-precheck-wrapper.sh <name> <log-path> -- <command...>
set -uo pipefail
name=${1:?automation name}
log=${2:?log path}
shift 2
[ "${1:-}" = -- ] && shift
[ $# -gt 0 ] || {
  echo "automation-precheck-wrapper: missing command" >&2
  exit 2
}

mkdir -p "$(dirname "$log")"
host=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
rid=$$
started=$SECONDS

trace_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

trace_emit() {
  # shellcheck disable=SC2129
  printf '%s host=%s automation=%s run=%s %s\n' "$(trace_ts)" "$host" "$name" "$rid" "$*" >>"$log"
}

trace_emit "phase=start exit=- duration=0s summary=starting"

summary_file="${AUTOMATION_TRACE_SUMMARY_FILE:-${TMPDIR:-/tmp}/orca-automation-trace-$$.txt}"
export AUTOMATION_TRACE_SUMMARY_FILE="$summary_file"
: >"$summary_file"

inner_rc=0
"$@" >>"$log" 2>&1
inner_rc=$?
if [ -s "$summary_file" ]; then
  export AUTOMATION_TRACE_SUMMARY
  AUTOMATION_TRACE_SUMMARY=$(head -1 "$summary_file")
  export AUTOMATION_TRACE_SUMMARY
fi

duration=$((SECONDS - started))
summary=$(
  AUTOMATION_NAME="$name" AUTOMATION_INNER_RC="$inner_rc" python3 - <<'PY'
import os, re, sys

name = os.environ.get("AUTOMATION_NAME", "")
rc = int(os.environ.get("AUTOMATION_INNER_RC", "0"))
manual = (os.environ.get("AUTOMATION_TRACE_SUMMARY") or "").strip()
if manual:
    sys.stdout.write(manual[:240])
    raise SystemExit

def last_wrapup_summary(path: str) -> str:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""
    for line in reversed(text.splitlines()):
        if "phase=" in line:
            continue
        if "wrap-up-scheduled" not in line:
            continue
        return re.sub(r"^\S+\s+wrap-up-scheduled\s+\[\d+\]\s*", "", line).strip()
    return ""

if name == "wrap-up-scheduled":
    s = last_wrapup_summary(os.environ.get("WRAP_UP_SCHEDULED_LOG", ""))
    if s:
        sys.stdout.write(s[:240])
        raise SystemExit

if rc != 0:
    sys.stdout.write("failed inner exit %s" % rc)
else:
    sys.stdout.write("no change")
PY
)
summary=${summary//$'\n'/ }

trace_emit "phase=end exit=$inner_rc duration=${duration}s summary=$summary"
rm -f "$summary_file"
exit 1
