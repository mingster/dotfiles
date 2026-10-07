#!/usr/bin/env bash
# Live, read-only view of one Orca worker inside a split pane, with a colored title bar.
# Usage: worker-pane.sh <dispatch_id> [color 1-7]
# Orca has no option to start a worker as a split pane (each worker owns its worktree),
# so this mirrors the worker's screen into a pane of the coordinator's tab.
set -u
d="$1"; c="${2:-6}"; orca="${ORCA_CLI_COMMAND:-orca}"
while :; do
  info=$("$orca" orchestration worker-show --dispatch "$d" --json 2>/dev/null)
  read -r term status title < <(printf '%s' "$info" | python3 -c '
import sys,json
try: r=json.load(sys.stdin)["result"]
except Exception: print("- unknown -"); sys.exit()
d=r.get("dispatch",{}); w=r.get("worker",{})
t=d.get("assigneeHandle") or w.get("terminalHandle") or "-"
print(t, d.get("status","?"), (d.get("taskTitle") or w.get("title") or d.get("id","")).replace("\n"," "))')
  rows=$(tput lines 2>/dev/null || echo 30); cols=$(tput cols 2>/dev/null || echo 80)
  body=""
  [ "$term" != "-" ] && body=$("$orca" terminal read --terminal "$term" --screen --json 2>/dev/null | python3 -c '
import sys,json
try: tail=json.load(sys.stdin)["result"]["terminal"]["tail"]
except Exception: tail=[]
print("\n".join(l for l in tail if l.strip()))' | tail -n $((rows-2)) | cut -c1-"$cols")
  printf '\033[H\033[2J\033[1;37;4%sm %-*s\033[0m\n' "$c" $((cols-1)) "$title [$status]"
  printf '%s\n' "$body"
  case "$status" in completed|failed|cancelled|released) printf '\033[1;3%sm-- %s, pane stays for review (Ctrl+C to close) --\033[0m\n' "$c" "$status"; sleep 3600; exit;; esac
  sleep 5
done
