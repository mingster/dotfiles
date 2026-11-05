#!/usr/bin/env bash
# Move the coordinator role to this host. Manual only: nothing schedules this, failover is never automatic.
# Hosts come from coordinator.conf in the private agent-state repo (`coordinator <name>`, ordered
# `backup <name>` lines, names are `hostname -s`). Hand back by running the same command on the other host.
#
# Usage: take-over-coordinator.sh --yes [--state-dir DIR] [--dry-run] [--skip-order]
#   --yes         required; without it the plan is printed and nothing runs
#   --dry-run     print what would happen after the read-only checks, change nothing
#   --skip-order  continue although an earlier backup answers ssh
#   --state-dir   agent-state checkout (default $AGENT_STATE_DIR or ~/agent-state)
#
# Steps: 2 fetch and fast-forward, 3 role checks, 4 fence (coordinator.conf, commit, push), 5 stop the old
# host's sync over ssh, 6 restore live state, 7 turn on local sync, 8 one push. Safe to run again.
set -uo pipefail

state=${AGENT_STATE_DIR:-$HOME/agent-state}
dry=0 yes=0 skip_order=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) yes=1 ;;
    --dry-run) dry=1 ;;
    --skip-order) skip_order=1 ;;
    --state-dir) state=${2:?}; shift ;;
    -h | --help) sed -n 2,13p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

label=com.agent-state.sync
me=$(hostname -s | tr '[:upper:]' '[:lower:]')
sync_sh="$state/sync.sh"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
say() { printf '%s\n' "$*"; }
git_s() { git -C "$state" "$@"; }
conf() { git_s show origin/main:coordinator.conf 2>/dev/null; }
coord_name() { conf | awk '$1 == "coordinator" { print $2; exit }'; }
stop() { # step, what happened, next command
  say ""
  say "STOPPED at step $1: $2"
  say "State: this host $me; origin coordinator.conf names '$(coord_name)'."
  say "Next: $3"
  exit 1
}

with_timeout() {
  local secs=$1 pid killer rc
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  "$@" &
  pid=$!
  (sleep "$secs"; kill "$pid" 2>/dev/null) &
  killer=$!
  wait "$pid"
  rc=$?
  kill "$killer" 2>/dev/null
  return $rc
}
ssh6() { with_timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=6 "$@"; }

say "Take over the coordinator role on $me (state: $state):"
say "  2. fetch and fast-forward the state repo"
say "  3. check this host is a backup and no earlier backup answers ssh"
say "  4. fence: set 'coordinator $me' in coordinator.conf, commit that file, push"
say "  5. stop the old host's sync over ssh (unreachable is fine, the fence holds it)"
say "  6. restore live state with sync.sh pull (this host's .zshenv.local is kept)"
say "  7. install and load only $label.plist"
say "  8. run one sync.sh push"
if [ "$yes" != 1 ] && [ "$dry" != 1 ]; then
  say ""
  say "Refused: the owner runs this by hand. Re-run with --yes to go ahead, or --dry-run to look."
  exit 1
fi
[ "$dry" = 1 ] && say "(dry run: read-only checks, nothing is changed)"

say ""
say "== Step 2: fetch and fast-forward"
[ -d "$state/.git" ] && [ -f "$sync_sh" ] || stop 2 "$state is not an agent-state checkout" "clone agent-state there or pass --state-dir"
git_s fetch -q origin || stop 2 "git fetch failed" "check the network and gh sign-in, then re-run"
unpushed=$(git_s log --oneline origin/main..HEAD)
if [ -n "$unpushed" ]; then
  say "Unpushed local commits:"; say "$unpushed"
  stop 2 "local commits are not on origin" "push or drop them in $state, then re-run"
fi
dirty=$(git_s status --porcelain)
if [ -n "$dirty" ]; then
  say "Uncommitted changes:"; say "$dirty"
  stop 2 "the state repo has changes that are not on origin" "commit or discard them in $state, then re-run"
fi
if [ "$dry" = 1 ]; then
  say "would fast-forward to origin/main"
else
  git_s merge -q --ff-only origin/main || stop 2 "cannot fast-forward to origin/main" "inspect $state, then re-run"
fi

old=$(coord_name)
already=0
say ""
say "== Step 3: role checks"
if [ "$(lower "$old")" = "$me" ]; then
  already=1
  say "This host is already the coordinator. Only restoring and turning on sync (steps 6 to 8)."
else
  backups=$(conf | awk '$1 == "backup" { print $2 }')
  if ! printf '%s\n' "$backups" | tr '[:upper:]' '[:lower:]' | grep -qx "$me"; then
    stop 3 "this host is not a backup in coordinator.conf, so it cannot take over" "ask the owner to add 'backup $me' to coordinator.conf in agent-state"
  fi
  blockers=
  while read -r b; do
    [ -n "$b" ] || continue
    [ "$(lower "$b")" = "$me" ] && break
    [ "$(lower "$b")" = "$(lower "$old")" ] && continue
    if ssh6 "$b" true >/dev/null 2>&1; then
      say "WARNING: backup '$b' comes before this host and answers ssh. It should take over first."
      blockers="$blockers $b"
    fi
  done <<<"$backups"
  if [ -n "$blockers" ] && [ "$skip_order" != 1 ]; then
    stop 3 "earlier backup answers ssh:$blockers" "run this command on that host, or re-run here with --skip-order"
  fi
  say "ok: $me is a backup; old coordinator is '${old:-none}'."
fi

write_fence() {
  local f="$state/coordinator.conf" tmp old_is_backup=0
  tmp=$(mktemp)
  if [ -n "$old" ] && conf | awk '$1 == "backup" { print tolower($2) }' | grep -qx "$(lower "$old")"; then old_is_backup=1; fi
  awk -v me="$me" -v old="$old" -v keep="$old_is_backup" '
    $1 == "coordinator" { print "coordinator " me; done = 1; next }
    $1 == "backup" && tolower($2) == me { if (old != "" && !keep) print "backup " old; next }
    { print }
    END { if (!done) print "coordinator " me }' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}
fence_commit_push() {
  write_fence
  git_s add coordinator.conf
  git_s commit -q -m "coordinator: $me takes over from ${old:-none}" -- coordinator.conf || return 1
  git_s push -q origin HEAD:main
}

if [ "$already" = 0 ]; then
  say ""
  say "== Step 4: fence"
  if [ "$dry" = 1 ]; then
    say "would set 'coordinator $me', commit coordinator.conf only, push"
  elif ! fence_commit_push; then
    say "push rejected, fetching and retrying once"
    git_s reset -q --hard HEAD~1
    git_s fetch -q origin || stop 4 "git fetch failed during the retry" "re-run when origin is reachable"
    git_s merge -q --ff-only origin/main || stop 4 "cannot fast-forward after the rejection" "inspect $state, then re-run"
    now=$(coord_name)
    [ "$(lower "$now")" = "$(lower "$old")" ] || stop 4 "coordinator changed to '$now' while this ran" "ask the owner who is coordinator now"
    fence_commit_push || stop 4 "push rejected twice" "check the origin settings, then re-run"
  else
    say "ok: origin names $me as coordinator. '${old:-none}' refuses on its next sync."
  fi

  say ""
  say "== Step 5: stop the old host's sync"
  if [ -z "$old" ]; then
    say "no old coordinator recorded, nothing to stop"
  elif [ "$dry" = 1 ]; then
    say "would run launchctl bootout for $label on $old over ssh"
  else
    # shellcheck disable=SC2016
    ssh6 "$old" 'launchctl bootout gui/$(id -u)/'"$label"' >/dev/null 2>&1; if launchctl print gui/$(id -u)/'"$label"' >/dev/null 2>&1; then exit 3; fi' >/dev/null 2>&1
    case $? in
      0) say "old host sync stopped" ;;
      3) stop 5 "the sync is still loaded on $old" "ssh $old launchctl bootout gui/\$(id -u)/$label, then re-run here (the fence already holds $old)" ;;
      *) say "old host unreachable, fenced by coordinator.conf" ;;
    esac
  fi
fi

say ""
say "== Step 6: restore live state"
if [ "$dry" = 1 ]; then
  say "would run sync.sh pull, keeping $HOME/.zshenv.local"
else
  aside=
  if [ -f "$HOME/.zshenv.local" ]; then aside=$(mktemp) && cp -p "$HOME/.zshenv.local" "$aside"; fi
  bash "$sync_sh" pull
  pull_rc=$?
  if [ -n "$aside" ]; then cp -p "$aside" "$HOME/.zshenv.local"; rm -f "$aside"; fi
  [ "$pull_rc" -eq 0 ] || stop 6 "sync.sh pull failed" "bash $sync_sh pull, then re-run"
  say "ok: live state restored"
fi

say ""
say "== Step 7: local sync"
if [ "$dry" = 1 ]; then
  say "would run sync.sh install-agent $label and touch .sync-ok"
else
  bash "$sync_sh" install-agent "$label" || stop 7 "could not install $label.plist" "bash $sync_sh install-agent $label, then re-run"
  touch "$state/.sync-ok"
fi

say ""
say "== Step 8: first push"
if [ "$dry" = 1 ]; then
  say "would run sync.sh push"
else
  if result=$(bash "$sync_sh" push 2>&1); then
    say "$result"
  else
    say "$result"
    stop 8 "the first push did not pass" "read the lines above, fix them, then bash $sync_sh push"
  fi
fi

say ""
say "Left for the owner:"
say "  * Orca pairing on this host"
say "  * start the coordinator agent here"
say "Hand back: run this same command on the other host."
