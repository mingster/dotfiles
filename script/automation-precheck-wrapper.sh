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

summary_file="${AUTOMATION_TRACE_SUMMARY_FILE:-${TMPDIR:-/tmp}/orca-automation-trace-$$.txt}"
export AUTOMATION_TRACE_SUMMARY_FILE="$summary_file"
: >"$summary_file"

inner_rc=0
child_pid=""
trace_done=0

stop_child() {
  local pid=${child_pid:-}
  [ -n "$pid" ] || return 0
  child_pid=""
  kill -TERM -"$pid" "$pid" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL -"$pid" "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

finish_trace() {
  [ "$trace_done" -eq 0 ] || return 0
  trace_done=1
  trap '' EXIT TERM INT
  stop_child
  if [ -s "$summary_file" ]; then
    export AUTOMATION_TRACE_SUMMARY
    AUTOMATION_TRACE_SUMMARY=$(head -1 "$summary_file")
    export AUTOMATION_TRACE_SUMMARY
  fi

  local duration=$((SECONDS - started)) summary
  # The scheduled log path is argument 2; inner env may set WRAP_UP_SCHEDULED_LOG only for the child.
  [ "$name" = wrap-up-scheduled ] && export WRAP_UP_SCHEDULED_LOG="$log"
  summary=$(
    AUTOMATION_NAME="$name" AUTOMATION_INNER_RC="$inner_rc" AUTOMATION_LOG="$log" AUTOMATION_RID="$rid" python3 - <<'PY'
import os, re, sys

name = os.environ.get("AUTOMATION_NAME", "")
rc = int(os.environ.get("AUTOMATION_INNER_RC", "0"))
log_path = os.environ.get("AUTOMATION_LOG", "")
rid = os.environ.get("AUTOMATION_RID", "")
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
    s = last_wrapup_summary(os.environ.get("WRAP_UP_SCHEDULED_LOG", "") or log_path)
    if s:
        sys.stdout.write(s[:240])
        raise SystemExit

try:
    lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    lines = []
marker = f"run={rid} phase=start"
for idx in range(len(lines) - 1, -1, -1):
    if marker in lines[idx]:
        lines = lines[idx + 1:]
        break
for line in reversed(lines):
    m = re.search(r"((?:drift or check failure|team-audit findings|metrics failed|weekly-update failed) \(exit \d+\)|skip: [^\n]+)", line)
    if m:
        sys.stdout.write(m.group(1).strip()[:240])
        raise SystemExit

if rc != 0:
    sys.stdout.write("failed inner exit %s" % rc)
else:
    sys.stdout.write("no change")
PY
  )
  summary=${summary//$'\n'/ }
  [ -n "$summary" ] || {
    if [ "$inner_rc" -ne 0 ]; then summary="failed inner exit $inner_rc"; else summary="no change"; fi
  }

  trace_emit "phase=end exit=$inner_rc duration=${duration}s summary=$summary"
  rm -f "$summary_file"
}

# shellcheck disable=SC2329
on_term() {
  trap '' TERM INT
  inner_rc=143
  stop_child
  exit 143
}

# shellcheck disable=SC2329
on_int() {
  trap '' TERM INT
  inner_rc=130
  stop_child
  exit 130
}

trap finish_trace EXIT
trap on_term TERM
trap on_int INT

trace_emit "phase=start exit=- duration=0s summary=starting"

perl -e 'setpgrp(0, 0); exec(@ARGV) or exit 127' -- "$@" >>"$log" 2>&1 &
child_pid=$!
wait "$child_pid"
inner_rc=$?
child_pid=""
finish_trace
exit 1
