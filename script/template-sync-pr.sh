#!/usr/bin/env bash
# Bump each project to the current dotfiles template after a template merge (#1247).
# Usage: template-sync-pr.sh --verdict-from <owner/dotfiles#N> [--project <checkout>]... [--no-ship]
# For each project: a worktree off its origin/main, agent-team.sh sync from dotfiles origin/main (which writes
# .claude/agent-team-pin), and on a diff a PR from branch team-sync/<dotfiles sha>. A rerun reuses the open PR.
# When the PR checks are green, ship.sh lands it with --verdict-from. The worktree is removed after.
# Projects: --project, else the fleet-pull config checkouts whose origin is in ship config verdict_from_repos.
# Writes one line per project, "<slug> <state> <pr or ->", state one of none, open, red, merged, failed.
# TEMPLATE_SYNC_STATE (default ~/.claude/state/template-sync.json) keeps the last state per project for fleet-watch.
# TEMPLATE_SYNC_WAIT seconds (default 1800) bounds the wait for checks; pending at the end leaves the PR open.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dotfiles=$(cd "$here/.." && pwd)
verdict_from="" ship=1 projects=()
while [ $# -gt 0 ]; do
  case "$1" in
    --verdict-from) verdict_from=${2:?--verdict-from needs owner/dotfiles#N}; shift 2 ;;
    --project) projects+=("${2:?--project needs a path}"); shift 2 ;;
    --no-ship) ship=0; shift ;;
    *) echo "Usage: $0 --verdict-from <owner/dotfiles#N> [--project <checkout>]... [--no-ship]" >&2; exit 2 ;;
  esac
done
[[ "$verdict_from" =~ ^[A-Za-z0-9_.-]+/dotfiles#[0-9]+$ ]] || { echo "template-sync: --verdict-from must look like owner/dotfiles#N" >&2; exit 2; }
state_file=${TEMPLATE_SYNC_STATE:-$HOME/.claude/state/template-sync.json}
wait_limit=${TEMPLATE_SYNC_WAIT:-1800}
poll=${TEMPLATE_SYNC_POLL:-30}

slug_of() { # <checkout>
  git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/|ssh://[^/]+/)##; s#\.git$##'
}

if [ "${#projects[@]}" -eq 0 ]; then
  state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
  pull_cfg=${FLEET_PULL_CONFIG:-}
  for c in "$state_dir/fleet-pull.json" "$state_dir/fleet-config.json" "$here/fleet-pull.config.json"; do
    [ -n "$pull_cfg" ] || { [ -f "$c" ] && jq -e 'has("repos")' "$c" >/dev/null 2>&1 && pull_cfg=$c; }
  done
  ship_cfg=$(python3 "$here/apply-local-overlay.py" "$here/ship.config.example.json" "$here/ship.local.json") || ship_cfg='{}'
  [ -n "$pull_cfg" ] || { echo "template-sync: no fleet-pull config with repos" >&2; exit 1; }
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    d=${raw/#\~/$HOME}
    jq -e --arg s "$(slug_of "$d")" '(.verdict_from_repos // []) | index($s) != null' <<<"$ship_cfg" >/dev/null && projects+=("$d")
  done < <(jq -r '(.repos // [])[]' "$pull_cfg")
fi
[ "${#projects[@]}" -gt 0 ] || { echo "template-sync: no projects to sync"; exit 0; }

git -C "$dotfiles" fetch -q origin || { echo "template-sync: cannot fetch dotfiles" >&2; exit 1; }
dot_sha=$(git -C "$dotfiles" rev-parse --verify -q 'origin/main^{commit}') || { echo "template-sync: no dotfiles origin/main" >&2; exit 1; }
# Named for the last template commit, not origin/main, so an unrelated dotfiles commit finds the same PR (#1329).
tpl_sha=$(git -C "$dotfiles" log -1 --format=%H "$dot_sha" -- templates/agent-team script/agent-team.sh 2>/dev/null)
branch="team-sync/${tpl_sha:-$dot_sha}"
lock_dir=${TEMPLATE_SYNC_LOCK_DIR:-$HOME/.claude/state/template-sync.lock.d}
lock=""
tmp=$(mktemp -d)
dot_wt="$tmp/dotfiles"
cleanup() {
  local w
  [ -z "$lock" ] || rm -rf "$lock"
  for w in "$tmp"/proj-*; do
    [ -d "$w" ] || continue
    git -C "$w" worktree remove --force "$w" >/dev/null 2>&1 || true
  done
  git -C "$dotfiles" worktree remove --force "$dot_wt" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
git -C "$dotfiles" worktree add -q --detach "$dot_wt" "$dot_sha" || { echo "template-sync: cannot check out dotfiles $dot_sha" >&2; exit 1; }

record() { # <slug> <state> <pr>
  echo "$1 $2 ${3:--}"
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || return 0
  python3 - "$state_file" "$1" "$2" "${3:-}" "$dot_sha" <<'PY' || true
import json, os, sys, time
path, slug, state, pr, sha = sys.argv[1:]
try:
    data = json.load(open(path))
except (OSError, ValueError):
    data = {}
data[slug] = {'state': state, 'pr': int(pr) if pr else None, 'sha': sha, 'at': int(time.time())}
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
os.replace(tmp, path)
PY
}

# pass | fail | pending, from gh pr checks buckets.
checks_state() { # <slug> <pr>
  local out
  out=$(gh pr checks "$2" --repo "$1" --json bucket 2>/dev/null) || { echo pending; return; }
  jq -r 'if length == 0 then "pending"
    elif any(.[]; .bucket == "fail" or .bucket == "cancel") then "fail"
    elif all(.[]; .bucket == "pass" or .bucket == "skipping") then "pass"
    else "pending" end' <<<"$out"
}

status=0 n=0
for proj in "${projects[@]}"; do
  n=$((n + 1))
  slug=$(slug_of "$proj")
  [ -n "$slug" ] || { echo "template-sync: $proj has no origin" >&2; status=1; continue; }
  # One run per project: ship.sh and fleet-watch both start this script (#1329).
  [ -z "$lock" ] || { rm -rf "$lock"; lock=""; }
  mkdir -p "$lock_dir" 2>/dev/null
  lock="$lock_dir/${slug//\//_}"
  if ! mkdir "$lock" 2>/dev/null; then
    if kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null; then
      echo "$slug busy -"; lock=""; continue
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "$slug busy -"; lock=""; continue; }
  fi
  echo $$ >"$lock/pid"
  wt="$tmp/proj-$n"
  if ! git -C "$proj" fetch -q origin || ! git -C "$proj" worktree add -q --detach "$wt" origin/main; then
    record "$slug" failed ""; status=1; continue
  fi
  if ! DOTFILES="$dot_wt" bash "$dot_wt/script/agent-team.sh" sync "$wt" >"$tmp/sync.log" 2>&1; then
    sed 's/^/  /' "$tmp/sync.log" >&2
    record "$slug" failed ""; status=1
    git -C "$proj" worktree remove --force "$wt" >/dev/null 2>&1
    continue
  fi
  if [ -z "$(git -C "$wt" status --porcelain)" ]; then
    record "$slug" none ""
    git -C "$proj" worktree remove --force "$wt" >/dev/null 2>&1
    continue
  fi
  pr_n=$(gh pr list --repo "$slug" --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null) || pr_n=""
  if [ -z "$pr_n" ]; then
    stat=$(git -C "$wt" add -A && git -C "$wt" diff --cached --stat) || stat=""
    # ship.sh needs a Builder line and a ## Self-check with a command and its output (#1291).
    body=$(printf 'Bumps the agent team template to dotfiles %s (%s).\n\nGenerated by template-sync-pr.sh: agent-team.sh sync, no hand edits. Lands with ship.sh --verdict-from %s.\n\nBuilder: agent=script model=template-sync-pr.sh\n\n## Self-check\n\n```\n$ git diff --cached --stat\n%s\n```\n' \
      "${dot_sha:0:12}" "$verdict_from" "$verdict_from" "$stat")
    if ! git -C "$wt" checkout -q -b "$branch" \
      || ! git -C "$wt" add -A \
      || ! git -C "$wt" commit -q -m "chore(team): sync agent team template to dotfiles ${dot_sha:0:12}" \
      || ! git -C "$wt" push -q origin "$branch" \
      || ! pr_url=$(gh pr create --repo "$slug" --head "$branch" --base main \
        --title "chore(team): sync agent team template to dotfiles ${dot_sha:0:12}" --body "$body"); then
      record "$slug" failed ""; status=1
      git -C "$proj" worktree remove --force "$wt" >/dev/null 2>&1
      continue
    fi
    pr_n=${pr_url##*/}
  fi
  git -C "$proj" worktree remove --force "$wt" >/dev/null 2>&1
  if [ "$ship" -eq 0 ]; then
    record "$slug" open "$pr_n"
    continue
  fi
  waited=0 cs=pending
  while :; do
    cs=$(checks_state "$slug" "$pr_n")
    [ "$cs" = pending ] && [ "$waited" -lt "$wait_limit" ] || break
    sleep "$poll"
    waited=$((waited + poll))
  done
  case "$cs" in
    pass)
      # ship.sh refuses a cwd that is not the project checkout (#1326), so run it from there.
      if (cd "$proj" && bash "$here/ship.sh" --repo "$slug" --pr "$pr_n" --verdict-from "$verdict_from"); then
        record "$slug" merged "$pr_n"
      else
        record "$slug" failed "$pr_n"; status=1
      fi
      ;;
    fail) record "$slug" red "$pr_n"; status=1 ;;
    *) record "$slug" open "$pr_n" ;;
  esac
done
exit "$status"
