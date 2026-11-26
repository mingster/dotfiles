#!/usr/bin/env bash
# Stop orphaned test and build runners on this host (#1954).
# Usage: reap-orphan-tests.sh [--dry-run]
# A candidate is a process of the current user with ppid 1, older than 30 minutes, whose command is a test or build
# runner (bun test, bunx playwright, playwright test, next build, xcodebuild test or build-for-testing, simctl spawn)
# and whose working directory is under the Orca workspaces folder. It gets TERM, then KILL after a grace wait, by PID
# only (never pkill). A process with a live parent, outside the folder, a launchd daemon, Chrome, brew, Orca or an
# agent CLI is never touched. One line per process: "reaped pid=.. age=.. cmd=.. cwd=..", or "would reap ..." with --dry-run.
# Env: REAP_ORPHAN_ROOT (default ~/orca/workspaces), REAP_ORPHAN_MIN_AGE seconds (default 1800),
# REAP_ORPHAN_GRACE seconds between TERM and KILL (default 5).
# Test seams: REAP_PS_CMD (list | show PID | cwd PID; tab lines: pid, ppid, age seconds, start, command),
# REAP_KILL_CMD (SIGNAL PID) and REAP_ALIVE_CMD (PID, exit 0 while alive).
set -uo pipefail

dry_run=0
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=1 ;;
  -h|--help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo 'Usage: reap-orphan-tests.sh [--dry-run]' >&2; exit 2 ;;
esac

root=${REAP_ORPHAN_ROOT:-$HOME/orca/workspaces}
root=$(printf '%s' "$root" | sed 's#//*#/#g; s#/$##')
min_age=${REAP_ORPHAN_MIN_AGE:-1800}
grace=${REAP_ORPHAN_GRACE:-5}
case "$min_age$grace" in *[!0-9]*|'') echo 'reap-orphan-tests: age and grace must be whole seconds' >&2; exit 2 ;; esac

ps_real() {
  case "$1" in
    list|show)
      local pargs=(-ww -u "$(id -un)"); [ "$1" = list ] || pargs=(-ww -p "$2")
      ps "${pargs[@]}" -o pid=,ppid=,etime=,lstart=,command= | awk '{
        t = $3; d = 0
        if (index(t, "-")) { split(t, dp, "-"); d = dp[1]; t = dp[2] }
        n = split(t, a, ":")
        s = (n == 3) ? a[1]*3600 + a[2]*60 + a[3] : a[1]*60 + a[2]; s += d*86400
        cmd = $9; for (i = 10; i <= NF; i++) cmd = cmd " " $i
        printf "%s\t%s\t%s\t%s %s %s %s %s\t%s\n", $1, $2, s, $4, $5, $6, $7, $8, cmd }' ;;
    cwd) command -v lsof >/dev/null 2>&1 || return 1
      local out; out=$(lsof -a -p "$2" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1); [ -n "$out" ] && printf '%s\n' "$out" ;;
  esac
}
ps_do() { if [ -n "${REAP_PS_CMD:-}" ]; then "$REAP_PS_CMD" "$@"; else ps_real "$@"; fi; }
kill_do() { if [ -n "${REAP_KILL_CMD:-}" ]; then "$REAP_KILL_CMD" "$1" "$2"; else kill "-$1" "$2"; fi; }
alive_do() { if [ -n "${REAP_ALIVE_CMD:-}" ]; then "$REAP_ALIVE_CMD" "$1"; else kill -0 "$1" 2>/dev/null; fi; }

# True for a test or build runner. The program name must be one of the runners' own, so an agent CLI or brew that
# only mentions "bun test" in its arguments never matches.
is_runner() {
  local cmd=$1 a0 a1 a2 rest
  read -r a0 a1 a2 rest <<< "$cmd"
  a0=${a0##*/}
  case "$a0" in
    bun) [ "$a1" = test ] ;;
    bunx) [ "$a1" = playwright ] ;;
    playwright) [ "$a1" = test ] ;;
    node) case "$a1" in */.bin/next|*/next/dist/bin/next) [ "$a2" = build ] ;; */.bin/playwright|*/playwright/cli.js) [ "$a2" = test ] ;; *) return 1 ;; esac ;;
    xcodebuild) case " $a1 $a2 $rest " in *' test '*|*' build-for-testing '*|*' test-without-building '*) return 0 ;; *) return 1 ;; esac ;;
    xcrun) [ "$a1" = simctl ] && [ "$a2" = spawn ] ;;
    simctl) [ "$a1" = spawn ] ;;
    *) return 1 ;;
  esac
}

under_root() {
  local p; p=$(printf '%s' "$1" | sed 's#//*#/#g; s#/$##')
  case "$p" in /*) : ;; *) return 1 ;; esac
  case "$p" in */../*|*/..|*/./*|*/.) return 1 ;; esac
  case "$p" in "$root"/*) return 0 ;; esac
  return 1
}

fmt_age() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! ps_do list > "$tmp/procs" 2>/dev/null; then echo 'reap-orphan-tests: process list unavailable; nothing reaped.' >&2; exit 0; fi

# Pass 1: choose candidates. Pass 2 sends TERM to all of them, so one grace wait covers every process.
: > "$tmp/chosen"
while IFS=$'\t' read -r pid ppid age started cmd; do
  [ "$ppid" = 1 ] || continue
  case "$age" in ''|*[!0-9]*) continue ;; esac
  [ "$age" -ge "$min_age" ] || continue
  is_runner "$cmd" || continue
  cwd=$(ps_do cwd "$pid" 2>/dev/null) || continue
  under_root "$cwd" || continue
  printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$age" "$started" "$cmd" "$cwd" >> "$tmp/chosen"
done < "$tmp/procs"

[ -s "$tmp/chosen" ] || exit 0

status=0
: > "$tmp/sent"
while IFS=$'\t' read -r pid age started cmd cwd; do
  line=$(printf 'pid=%s age=%s cmd=%s cwd=%s' "$pid" "$(fmt_age "$age")" "$(printf '%s' "$cmd" | cut -c1-100)" "$cwd")
  if [ "$dry_run" -eq 1 ]; then printf 'would reap %s\n' "$line"; continue; fi
  # The same process still: start time and command match, and its parent is still init.
  now_line=$(ps_do show "$pid" 2>/dev/null | head -n 1) || now_line=''
  IFS=$'\t' read -r _ n_ppid _ n_started n_cmd <<< "$now_line"
  if [ -z "$now_line" ] || [ "$n_ppid" != 1 ] || [ "$n_started" != "$started" ] || [ "$n_cmd" != "$cmd" ]; then continue; fi
  if kill_do TERM "$pid" >/dev/null 2>&1; then printf '%s\t%s\n' "$pid" "$line" >> "$tmp/sent"; fi
done < "$tmp/chosen"

[ -s "$tmp/sent" ] || exit 0
sleep "$grace"
while IFS=$'\t' read -r pid line; do
  if alive_do "$pid"; then
    if ! kill_do KILL "$pid" >/dev/null 2>&1 && alive_do "$pid"; then
      echo "Warning: pid $pid still alive after KILL." >&2; status=1; continue
    fi
    printf 'reaped %s (KILL)\n' "$line"
  else
    printf 'reaped %s (TERM)\n' "$line"
  fi
done < "$tmp/sent"
exit "$status"
