#!/usr/bin/env bash
# Live, read-only view of one Orca worker inside a split pane, with a colored title bar.
# Usage: worker-pane.sh <dispatch_id> [color 0-255]
#        worker-pane.sh --role-color "<task title>"   (print the color for the title's role)
# The color comes from the role in the task title ("<role> - <job>"), looked up in role-colors.tsv
# next to this script; unknown roles get 240 (grey). An explicit color argument overrides it.
# Orca has no option to start a worker as a split pane (each worker owns its worktree),
# so this mirrors the worker's screen into a pane of the coordinator's tab.
# When the dispatch ends (completed, failed, cancelled, released) the pane prints the final status, waits
# ORCA_PANE_CLOSE_DELAY seconds (default 10) and closes itself (needs ORCA_TERMINAL_HANDLE, set by Orca).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
role_color() { # title -> 256-color number
  local role; role=$(printf '%s' "$1" | sed 's/ - .*//' | tr 'A-Z' 'a-z' | tr -d '[:space:]')
  awk -F'\t' -v r="$role" '$1 == r { print $2; f = 1; exit } END { if (!f) print 240 }' "$here/role-colors.tsv"
}
if [ "$1" = "--role-color" ]; then role_color "${2:-}"; exit; fi
d="$1"; arg_c="${2:-}"; orca="${ORCA_CLI_COMMAND:-orca}"
while :; do
  info=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null)
  read -r term status title < <(printf '%s' "$info" | python3 -c '
import sys,json
try: r=json.load(sys.stdin)["result"]
except Exception: print("- unknown -"); sys.exit()
d=r.get("dispatch",{}); w=r.get("worker",{})
t=d.get("assigneeHandle") or w.get("terminalHandle") or "-"
print(t, d.get("status","?"), (d.get("taskTitle") or w.get("title") or d.get("id","")).replace("\n"," "))')
  c="${arg_c:-$(role_color "$title")}"
  rows=$(tput lines 2>/dev/null || echo 30); cols=$(tput cols 2>/dev/null || echo 80)
  body=""
  [ "$term" != "-" ] && body=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null | python3 -c '
import sys,json
try: tail=json.load(sys.stdin)["result"]["terminal"]["tail"]
except Exception: tail=[]
print("\n".join(l for l in tail if l.strip()))' | tail -n $((rows-2)) | cut -c1-"$cols")
  printf '\033[H\033[2J\033[1;37;48;5;%sm %-*s\033[0m\n' "$c" $((cols-1)) "$title [$status]"
  printf '%s\n' "$body"
  case "$status" in completed|failed|cancelled|released)
    printf '\033[1;38;5;%sm-- %s --\033[0m\n' "$c" "$status"
    # Close this pane too. A split that timed out (screen saver) leaves a pane whose handle nobody recorded,
    # so worker-pane-close.sh cannot find it. Orca sets ORCA_TERMINAL_HANDLE in every terminal.
    if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
      sleep "${ORCA_PANE_CLOSE_DELAY:-10}"
      "$orca" terminal close --terminal "$ORCA_TERMINAL_HANDLE" >/dev/null 2>&1
    fi
    exit;;
  esac
  sleep 5
done
