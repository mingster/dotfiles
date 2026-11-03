#!/usr/bin/env bash
# Elon session start: bring every fleet host up to date and report what is wrong. Read only except
# fleet-pull (a fast-forward of clean main checkouts). It never installs or deletes anything.
# Usage: elon-startup.sh [--no-pull]
# Hosts and repos come from fleet-pull.config.json (untracked). Needs jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}
command -v jq >/dev/null || { echo 'elon-startup requires jq' >&2; exit 1; }
[ -f "$cfg" ] || { echo "missing $cfg" >&2; exit 1; }
hosts=$(jq -r '.hosts[]' "$cfg")
repos=$(jq -r '.repos[]' "$cfg" | tr '\n' ' ')
problems=0
flag() { echo "PROBLEM $*"; problems=$((problems + 1)); }

echo "== 1 pull latest"
if [ "${1:-}" != --no-pull ]; then "$here/fleet-pull.sh" 2>&1 | tail -20; fi

# Runs on a host (or here): tools, the node pin of each repo, gh auth, heavy-gate slots.
check='
export PATH=$HOME/.bun/bin:$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:$PATH
for t in git jq bun node gh python3; do command -v $t >/dev/null || echo "missing tool $t"; done
for d in "$@"; do
  d=${d/#\~/$HOME}; [ -d "$d" ] || { echo "missing repo $d"; continue; }
  tv=$(find "$d" -maxdepth 2 -name .tool-versions -not -path "*/node_modules/*" 2>/dev/null | head -1)
  want=$([ -n "$tv" ] && awk "\$1==\"nodejs\"{print \$2}" "$tv")
  have=$(cd "$d" && node --version 2>/dev/null | tr -d v)
  [ -z "$want" ] || [ "$want" = "$have" ] || echo "node $d wants $want, runs ${have:-none}"
  [ -d "$d/web/node_modules" ] || [ ! -d "$d/web" ] || echo "no node_modules in $d/web (run bun install)"
done
gh auth status >/dev/null 2>&1 || echo "gh not signed in on this host"
for s in $HOME/.cache/heavy-gate/slot-*; do
  [ -f "$s/pid" ] || continue
  p=$(cat "$s/pid"); kill -0 "$p" 2>/dev/null || echo "heavy-gate $(basename $s) held by dead pid $p"
done'

echo "== 2 tools, pins, gh, heavy-gate (per host)"
out=$(bash -c "$check" _ $repos 2>&1); [ -z "$out" ] && echo "ok local" || { echo "$out" | sed 's/^/local: /'; problems=$((problems + 1)); }
for h in $hosts; do
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$h" bash -s -- $repos <<<"$check" 2>&1) || { flag "$h unreachable by ssh"; continue; }
  [ -z "$out" ] && echo "ok $h" || { echo "$out" | sed "s/^/$h: /"; problems=$((problems + 1)); }
done

echo "== 3 load and usage"
"$HOME/.claude/state/fleet-load.sh" 2>&1 | cut -c1-120
python3 "$here/usage-gate.py" check 2>&1 | python3 -c '
import sys, json
try:
    for r in json.load(sys.stdin): print(r["provider"], r["verdict"], r.get("weekly_used", ""))
except Exception: print("usage gate unreadable")'

echo "== 4 leftovers (preview only, nothing deleted)"
if [ -x "$here/wrap-up.sh" ] && [ -d "${PWD}/.git" -o -f "${PWD}/.git" ]; then
  env -u ORCA_CLI_COMMAND "$here/wrap-up.sh" --fleet --repo "$PWD" 2>&1 | grep -E '^(Remove|Delete) |removed worktrees' | cut -c1-140 | head -20
fi

echo "== 5 handoffs"
ls -t "$HOME/.claude/state/lead-handoffs" 2>/dev/null | head -3

echo "== $problems problem(s)"
