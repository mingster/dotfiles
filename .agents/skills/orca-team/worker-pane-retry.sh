#!/usr/bin/env bash
# Shared close/verify loop. Source after defining close_allowed (positive dispatch-end check).
# Each invocation has a 30-minute wall-clock budget, including stalled CLI calls.
close_rpc() {
  local remaining=$((close_deadline-SECONDS))
  [ "$remaining" -gt 0 ] || remaining=1
  [ "$remaining" -le 20 ] || remaining=20
  python3 - "$remaining" "$orca" "$@" <<'PY'
import subprocess,sys
try:
    r=subprocess.run(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     timeout=int(sys.argv[1]))
    sys.stdout.buffer.write(r.stdout)
    sys.exit(r.returncode)
except (OSError, subprocess.TimeoutExpired):
    sys.exit(1)
PY
}
close_verified() {
  local h="$1" d="$2" wait=5 list
  local close_deadline=$((SECONDS+${ORCA_PANE_CLOSE_TIMEOUT:-1800}))
  while :; do
    close_allowed "$d" "$h" || return 1
    close_rpc terminal close --terminal "$h" >/dev/null 2>&1 || :
    if list=$(close_rpc terminal list --json 2>/dev/null); then
      if printf '%s' "$list" | python3 -c '
import json,sys
try:
    r=json.load(sys.stdin)
    if r.get("ok") is False: sys.exit(1)
    r=r["result"]
    if r.get("truncated"): sys.exit(1)
    terms=r["terminals"]
    assert isinstance(terms,list)
    sys.exit(0 if all(t["handle"] != sys.argv[1] for t in terms) else 1)
except Exception: sys.exit(1)' "$h"; then return 0; fi
    fi
    [ "$SECONDS" -lt "$close_deadline" ] || return 1
    [ "$wait" -le "$((close_deadline-SECONDS))" ] || wait=$((close_deadline-SECONDS))
    sleep "$wait"
    case "$wait" in 5) wait=15;; 15) wait=30;; *) wait=60;; esac
    [ "$SECONDS" -lt "$close_deadline" ] || return 1
  done
}
