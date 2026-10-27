#!/usr/bin/env bash
# Set up a Mac as the coordinator machine. Generic: the repo and host list come from the
# private agent-state repo (coordinator.conf), never from this file.
#
# Steps: tools, clone agent-state, brew bundle, clone repos, restore state, install
# LaunchAgents, Orca data restore, health checks, then the list of owner-only steps.
#
# Usage: new-coordinator.sh [--dry-run] [--state-repo OWNER/NAME] [--state-dir DIR]
#                           [--orca-data PATH]
#   --state-repo  default: <gh login>/agent-state (or $AGENT_STATE_REPO)
#   --state-url   clone URL override (default https://github.com/<state-repo>.git)
#   coordinator.conf lines: repo <url> <dir under HOME>, host <ssh name>, launchagent <file>,
#   waiter <script under HOME>, Brewfile beside it.
#   --orca-data   directory or .tar/.tar.gz copied from the old Mac's Orca data folder
set -uo pipefail

dry=0
state_repo=${AGENT_STATE_REPO:-}
state_url=${AGENT_STATE_URL:-}
state_dir=${AGENT_STATE_DIR:-$HOME/agent-state}
orca_data=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --state-repo) state_repo=${2:?}; shift ;;
    --state-url) state_url=${2:?}; shift ;;
    --state-dir) state_dir=${2:?}; shift ;;
    --orca-data) orca_data=${2:?}; shift ;;
    -h | --help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

orca_target="$HOME/Library/Application Support/orca"
failures=0
owner_extra=()

step() { printf '\n== %s\n' "$*"; }
run() {
  if [ "$dry" = 1 ]; then
    printf 'would run: %s\n' "$*"
  else
    printf '+ %s\n' "$*"
    "$@"
  fi
}
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }
ok() { printf 'ok   %s\n' "$*"; }

step "Tools (Homebrew, git, gh)"
if ! command -v brew >/dev/null 2>&1; then
  if [ "$dry" = 1 ]; then
    echo "would run: the official Homebrew installer (asks the owner for the Mac password)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
  fi
fi
for t in git gh; do
  command -v "$t" >/dev/null 2>&1 || run brew install "$t"
done

if [ "$dry" = 0 ] && ! gh auth status >/dev/null 2>&1; then
  echo "gh is not signed in. Run: gh auth login   (the owner does this), then run this script again."
  exit 1
fi

if [ -z "$state_repo" ]; then
  if [ "$dry" = 1 ] || ! command -v gh >/dev/null 2>&1; then
    state_repo='<gh login>/agent-state'
  else
    state_repo="$(gh api user -q .login)/agent-state"
  fi
fi
[ -n "$state_url" ] || state_url="https://github.com/$state_repo.git"

step "Clone agent-state ($state_repo)"
if [ -d "$state_dir/.git" ]; then
  ok "already cloned at $state_dir"
else
  run git clone "$state_url" "$state_dir"
fi

conf="$state_dir/coordinator.conf"
if [ ! -f "$conf" ]; then
  echo "coordinator.conf not found yet; the remaining steps read it from agent-state."
  if [ "$dry" = 1 ]; then
    echo "would run: brew bundle, clone repos, restore state, install LaunchAgents, Orca restore, health checks"
    conf=
  else
    echo "agent-state looks incomplete: $conf missing" >&2
    exit 1
  fi
fi

repos=() hosts=() agents=() waiters=()
if [ -n "$conf" ]; then
  while read -r kind a b _; do
    case "$kind" in
      repo) repos+=("$a $b") ;;
      host) hosts+=("$a") ;;
      launchagent) agents+=("$a") ;;
      waiter) waiters+=("$a") ;;
    esac
  done < <(grep -v -E '^[[:space:]]*(#|$)' "$conf")

  step "Homebrew packages"
  if [ -f "$state_dir/Brewfile" ]; then
    run brew bundle --file "$state_dir/Brewfile"
  else
    echo "no Brewfile in agent-state; skipped"
  fi

  step "Clone repos"
  for r in ${repos[@]+"${repos[@]}"}; do
    url=${r%% *}; dest="$HOME/${r#* }"
    if [ -d "$dest/.git" ]; then
      ok "already cloned: $dest"
    else
      run mkdir -p "$(dirname "$dest")"
      run git clone "$url" "$dest"
    fi
  done

  step "Restore memory and state"
  run bash "$state_dir/sync.sh" pull
  run git -C "$state_dir" config core.hooksPath hooks

  step "Install LaunchAgents"
  run bash "$state_dir/sync.sh" install-agents

  step "Orca data restore"
  if [ -z "$orca_data" ]; then
    echo "no --orca-data given; skipped."
    owner_extra+=("Copy the Orca data folder from the old Mac, quit Orca, then run: $0 --orca-data <path>")
  elif [ "$dry" = 1 ]; then
    echo "would run: restore Orca data from $orca_data into $orca_target (refuses while Orca is running)"
  elif pgrep -x Orca >/dev/null 2>&1; then
    fail "Orca is running; quit it and run again with --orca-data"
  else
    if [ -e "$orca_target" ]; then
      mv "$orca_target" "$orca_target.pre-restore-$(date +%Y%m%d%H%M%S)"
    fi
    mkdir -p "$(dirname "$orca_target")"
    restored=0
    case "$orca_data" in
      *.tar | *.tar.gz | *.tgz) tar xf "$orca_data" -C "$(dirname "$orca_target")" && restored=1 ;;
      *) rsync -a "$orca_data/" "$orca_target/" && restored=1 ;;
    esac
    if [ "$restored" = 1 ]; then ok "Orca data restored"; else fail "Orca data restore"; fi
  fi
fi

step "Health checks"
if [ "$dry" = 1 ]; then
  echo "would check: orca bun gh claude cursor-agent, ssh to each host, inbox waiter, LaunchAgents"
  [ "${#hosts[@]}" -gt 0 ] && echo "hosts: ${hosts[*]}"
else
  for t in orca bun gh claude cursor-agent; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else fail "$t not found"; fi
  done
  if gh auth status >/dev/null 2>&1; then ok "gh signed in"; else fail "gh not signed in"; fi
  for h in ${hosts[@]+"${hosts[@]}"}; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" true >/dev/null 2>&1; then ok "ssh $h"; else fail "ssh $h unreachable"; fi
  done
  for w in ${waiters[@]+"${waiters[@]}"}; do
    if [ -x "$HOME/$w" ] && bash -n "$HOME/$w"; then ok "inbox waiter $w"; else fail "inbox waiter missing or not executable: $w"; fi
  done
  for a in ${agents[@]+"${agents[@]}"}; do
    if [ -f "$HOME/Library/LaunchAgents/$a" ]; then ok "LaunchAgent $a"; else fail "LaunchAgent $a not installed"; fi
  done
fi

step "Only the owner can do these"
n=1
owner_item() { printf '  %d. %s\n' "$n" "$1"; n=$((n + 1)); }
owner_item "Sign in to the Apple ID, and to GitHub (gh auth login) if it was not done."
owner_item "Sign in to each tool: claude, cursor-agent, codex, wrangler, gcloud auth login."
owner_item "Unlock the encrypted secrets image and type its passphrase: script/secrets-unpack.sh <image.dmg> <target dir>"
owner_item "Open Orca. If the host pairing did not carry over, create a new pairing code on each remote host."
for x in ${owner_extra[@]+"${owner_extra[@]}"}; do owner_item "$x"; done
owner_item "Start the coordinator agent. It reads its memory and starts the rest of the team."

if [ "$failures" -gt 0 ]; then
  printf '\n%d check(s) failed.\n' "$failures"
  exit 1
fi
