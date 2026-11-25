#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2015,SC2016,SC2086,SC2166
# Elon session start: bring every fleet host up to date and report what is wrong. Read only except
# fleet-pull (a fast-forward of clean main checkouts and an agent-team.sh machine render of
# ~/.claude role files and hooks). It never installs or deletes anything.
# Usage: elon-startup.sh [--no-pull]
# -h and --help print the usage and exit 0; any other argument exits 2 before any host contact or pull.
# Hosts and repos come from fleet-pull.config.json (untracked). Needs jq.
set -u
usage='Usage: elon-startup.sh [--no-pull]'
case "${1:-}" in
  -h|--help) [ $# -eq 1 ] && { echo "$usage"; exit 0; } ;;
esac
{ [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --no-pull ]; }; } || { echo "$usage" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
state=${AGENT_STATE_DIR:-$HOME/agent-state}
state_dir_agent=${ELON_STATE_DIR:-$HOME/.local/state/agent-team}
command -v jq >/dev/null || { echo 'elon-startup requires jq' >&2; exit 1; }
if [ -n "${FLEET_PULL_CONFIG:-}" ]; then
  cfg=$FLEET_PULL_CONFIG
elif [ -f "$state/fleet-pull.json" ]; then
  cfg="$state/fleet-pull.json"
elif [ -f "$state/fleet-config.json" ] && jq -e 'has("repos") or has("hosts")' "$state/fleet-config.json" >/dev/null 2>&1; then
  cfg="$state/fleet-config.json"
else
  cfg="$here/fleet-pull.config.json"
fi
[ -f "$cfg" ] || { echo "missing $cfg" >&2; exit 1; }
hosts=$(jq -r '(.hosts // [])[]' "$cfg")
repos=$(jq -r '(.repos // [])[]' "$cfg" | tr '\n' ' ')
problems=0
flag() { echo "PROBLEM $*"; problems=$((problems + 1)); }

# Runs a command with a time limit (macOS has no timeout). Usage: run_limited <seconds> cmd...
run_limited() {
  local secs=$1 pid watcher rc; shift
  "$@" >/dev/null 2>&1 & pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}

# May this host dispatch? Reports only. Every failure is a flag plus a NO DISPATCH line.
echo "== 0 coordinator"
nodispatch() { flag "$1"; echo "NO DISPATCH: $1"; blocked=1; }
blocked=0
if ! git -C "$state" rev-parse --git-dir >/dev/null 2>&1; then
  nodispatch "no state repo at $state"
else
  conf=$(cat "$state/coordinator.conf" 2>/dev/null || true)
  if GIT_TERMINAL_PROMPT=0 run_limited 10 git -C "$state" fetch -q origin main; then
    if [ "$(git -C "$state" branch --show-current 2>/dev/null)" = main ] && [ -z "$(git -C "$state" status --porcelain 2>/dev/null)" ]; then
      git -C "$state" merge --ff-only -q origin/main >/dev/null 2>&1 || true
    fi
    conf=$(git -C "$state" show origin/main:coordinator.conf 2>/dev/null || true)
    behind=$(git -C "$state" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    [ "$behind" = 0 ] || nodispatch "state repo is behind origin/main by $behind commit(s)"
  else
    nodispatch "fetch of the state repo failed, using the local coordinator.conf"
  fi
  want=$(printf '%s\n' "$conf" | awk '$1=="coordinator"{print $2; exit}' | tr '[:upper:]' '[:lower:]')
  me=$(hostname -s | tr '[:upper:]' '[:lower:]')
  if [ -z "$want" ]; then
    nodispatch "no coordinator line in coordinator.conf"
  elif [ "$want" != "$me" ]; then
    nodispatch "this host is $me, coordinator is $want"
  fi
  if [ ! -f "$state/.sync-ok" ]; then
    nodispatch "no .sync-ok, the last sync is unknown"
  else
    mtime=$(stat -c %Y "$state/.sync-ok" 2>/dev/null || stat -f %m "$state/.sync-ok")
    [ $(( $(date +%s) - mtime )) -lt 1800 ] || nodispatch ".sync-ok is older than 30 minutes"
  fi
  [ "$blocked" = 1 ] || echo "ok coordinator $want, state fresh"
fi

echo "== 1 pull latest"
if [ "${1:-}" != --no-pull ]; then "$here/fleet-pull.sh" 2>&1 | tail -20; fi

# Runs on a host (or here): tools, the node pin of each repo, gh auth, heavy-gate slots.
# shellcheck disable=SC2016,SC2001,SC2015,SC2086,SC2166
check='
export PATH=$HOME/.bun/bin:$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:$PATH
for t in git jq bun node gh python3; do command -v $t >/dev/null || echo "missing tool $t"; done
for d in "$@"; do
  d=${d/#\~/$HOME}; [ -d "$d" ] || { echo "missing repo $d"; continue; }
  tv=$(find "$d" -maxdepth 2 -name .tool-versions -not -path "*/node_modules/*" 2>/dev/null | head -1)
  [ -n "$tv" ] || continue
  want=$([ -n "$tv" ] && awk "\$1==\"nodejs\"{print \$2}" "$tv")
  have=$(cd "$(dirname "$tv")" && node --version 2>/dev/null | tr -d v)
  [ -z "$want" ] || [ "$want" = "$have" ] || echo "node $d wants $want, runs ${have:-none}"
  [ -d "$d/web/node_modules" ] || [ ! -d "$d/web" ] || echo "no node_modules in $d/web (run bun install)"
done
gh auth status >/dev/null 2>&1 || echo "gh not signed in on this host"
for s in $HOME/.cache/heavy-gate/slot-*; do
  [ -f "$s/pid" ] || continue
  p=$(cat "$s/pid"); kill -0 "$p" 2>/dev/null || echo "heavy-gate $(basename $s) held by dead pid $p"
done'

echo "== 2 toolchain (orca, bun, node)"
if [ -x "$here/fleet-toolchain-check.sh" ]; then
  tc=$("$here/fleet-toolchain-check.sh" 2>&1) || true
  if [ -n "$tc" ]; then echo "$tc" | sed 's/^/toolchain: /'; problems=$((problems + 1)); else echo "ok toolchain"; fi
fi

echo "== 3 tools, pins, gh, heavy-gate (per host)"
out=$(bash -c "$check" _ $repos 2>&1); [ -z "$out" ] && echo "ok local" || { echo "$out" | sed 's/^/local: /'; problems=$((problems + 1)); }
for h in $hosts; do
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$h" bash -s -- $repos <<<"$check" 2>&1) || { flag "$h unreachable by ssh"; continue; }
  [ -z "$out" ] && echo "ok $h" || { echo "$out" | sed "s/^/$h: /"; problems=$((problems + 1)); }
done

echo "== 4 load and usage"
"$HOME/.claude/state/fleet-load.sh" 2>&1 | cut -c1-120
python3 "$here/usage-gate.py" check 2>&1 | python3 -c '
import sys, json
try:
    for r in json.load(sys.stdin): print(r["provider"], r["verdict"], r.get("weekly_used", ""))
except Exception: print("usage gate unreadable")'

echo "== 5 leftovers (preview only, nothing deleted)"
if [ -x "$here/wrap-up.sh" ] && [ -d "${PWD}/.git" -o -f "${PWD}/.git" ]; then
  env -u ORCA_CLI_COMMAND "$here/wrap-up.sh" --fleet --repo "$PWD" 2>&1 | grep -E '^(Remove|Delete) |removed worktrees' | cut -c1-140 | head -20
fi

# The four elon jobs (#1778, owner 2026-11-24): fleet-watch every 5 minutes, a waiter for worker mail, a 5 minute watch of
# the fleet, and keeping target_workers filled. They are checked here, on the coordinator host only: fleet-watch is the Orca
# automation (#1838), so startup only checks that it is enabled. The waiter and the watch live in the elon session, so this prints the waiter script and the 5 minute interval for the /elon skill.
echo "== 6 elon jobs"
if [ "$blocked" = 1 ]; then
  echo "skip elon jobs: this host may not dispatch"
else
  tmpdir=$state_dir_agent
  mkdir -p "$tmpdir" 2>/dev/null || true
  FLEET_WATCH_CONFIG=${FLEET_WATCH_CONFIG:-$HOME/.claude/state/fleet-watch-elon.json}
  status_cmd=${FLEET_AUTOMATION_STATUS_CMD:-$here/install-fleet-automations.sh}
  fw_state=$(bash "$status_cmd" --status 2>/dev/null | sed -n 's/^fleet-watch: //p' | head -n 1)
  case "$fw_state" in
    enabled) echo "job fleet-watch: Orca automation enabled (every 5 minutes)" ;;
    disabled) flag "fleet-watch automation is disabled; enable it in Orca Automations (or: orca automations edit --id <id> --enabled)" ;;
    *) flag "fleet-watch automation is missing; run script/install-fleet-automations.sh --install" ;;
  esac
  run_id=$(jq -r '(.runs // [])[0].id // empty' "$FLEET_WATCH_CONFIG" 2>/dev/null || true)
  if [ -z "$run_id" ]; then
    flag "waiter not armed: no run id in $FLEET_WATCH_CONFIG (runs[0].id)"
  else
    waiter=$tmpdir/elon-wait.sh
    printf '#!/usr/bin/env bash\n# One wait for worker mail. 3600000 ms is only the backstop, the 5 minute watch wakes elon on time.\nexec "${ORCA_CLI_COMMAND:-orca}" orchestration check --run %s --wait --timeout-ms 3600000 --full >"%s/elon-waiter.json"\n' "$run_id" "$tmpdir" >"$waiter"
    chmod +x "$waiter"
    echo "job waiter: armed, script $waiter (run $run_id, backstop 3600000 ms); start it with Bash run_in_background"
  fi
  echo "job watch: every 5 minutes (300 s) plus on worker mail; set it with CronCreate '*/5 * * * *'"
fi

# Open asks and live claims, written by each fleet-watch pass beside its state file, so a compaction loses neither (#1843).
echo "== 7 open asks and live claims"
open_work=${ELON_OPEN_WORK_FILE:-$state_dir_agent/elon-open-work.md}
if [ -f "$open_work" ]; then cat "$open_work"; else echo "no open work file at $open_work (fleet-watch has not run a pass)"; fi

echo "== $problems problem(s)"
