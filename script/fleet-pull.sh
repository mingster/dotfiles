#!/usr/bin/env bash
# Fast-forward the main checkout of each configured repo on this host and every fleet host.
# Config (untracked, see fleet-pull.config.example.json): {"hosts": ["ssh-host"], "repos": ["~/path"]}
# Skips a repo that is dirty or not on main. Never merges, resets or stashes.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=${FLEET_PULL_CONFIG:-$here/fleet-pull.config.json}
command -v jq >/dev/null || { echo 'fleet-pull requires jq' >&2; exit 1; }
[ -f "$cfg" ] || { echo "missing $cfg (copy fleet-pull.config.example.json)" >&2; exit 1; }
remote='
for d in "$@"; do
  d=${d/#\~/$HOME}
  [ -d "$d/.git" ] || { echo "skip $d (missing)"; continue; }
  b=$(git -C "$d" branch --show-current)
  [ "$b" = main ] || { echo "skip $d (on $b)"; continue; }
  [ -z "$(git -C "$d" status --porcelain)" ] || { echo "skip $d (dirty)"; continue; }
  git -C "$d" fetch -q origin || { echo "fail $d (fetch)"; continue; }
  git -C "$d" merge --ff-only -q origin/main >/dev/null 2>&1 && echo "ok   $d $(git -C "$d" rev-parse --short HEAD)" || echo "fail $d (not fast-forward)"
done'
repos=(); while IFS= read -r r; do repos+=("$r"); done < <(jq -r '.repos[]' "$cfg")
echo "local"; bash -c "$remote" _ "${repos[@]}"
for h in $(jq -r '.hosts[]' "$cfg"); do
  echo "$h"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" bash -s -- "${repos[@]}" <<<"$remote" 2>&1 || echo "warn unreachable $h"
done
