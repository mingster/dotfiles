#!/usr/bin/env bash
# fleet-watch-loop.sh, dotfiles-sync.sh, eight install scripts and shellcheck-dotfiles.sh:
# -h/--help print usage and exit 0, any other argument exits 2, and neither runs the job (#1581 #1582).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Every stub appends its name to $tmp/calls, so "nothing ran" is one file check.
mkdir -p "$tmp/bin"
for c in brew curl sudo code asdf pacman yay apt-get gcloud aws claude zed shellcheck python-stub; do
  printf '#!/bin/sh\necho %s >>"%s/calls"\nexit 0\n' "$c" "$tmp" >"$tmp/bin/$c"
  chmod +x "$tmp/bin/$c"
done

# dotfiles-sync.sh runs a sibling session-sync.sh; give it a copy that only records the call.
mkdir -p "$tmp/sync"
cp "$root/script/dotfiles-sync.sh" "$tmp/sync/"
printf '#!/bin/sh\necho session-sync >>"%s/calls"\n' "$tmp" >"$tmp/sync/session-sync.sh"

n=0
for name in fleet-watch-loop dotfiles-sync install_asdf install_aws_cli install_claude install_gcloud \
  install_java_dev install_vscode_extensions install_zed shellcheck-dotfiles; do
  for arg in -h --help --stp --bogus; do
    n=$((n + 1))
    h="$tmp/home-$n"
    mkdir -p "$h"
    : >"$tmp/calls"
    script="$root/script/$name.sh"
    [ "$name" = dotfiles-sync ] && script="$tmp/sync/dotfiles-sync.sh"
    out=$(HOME="$h" PATH="$tmp/bin:$PATH" OSTYPE=linux-gnu PYTHON="$tmp/bin/python-stub" \
      FLEET_WATCH_CONFIG=c FLEET_WATCH_STATE=s FLEET_WATCH_LOOP_ONCE=1 FLEET_WATCH_LOOP_DIR="$tmp/loop-$n" \
      bash "$script" "$arg" 2>&1 </dev/null)
    rc=$?
    case "$arg" in -h | --help) want=0 ;; *) want=2 ;; esac
    [ "$rc" -eq "$want" ] || fail "$name $arg exited $rc, want $want: $out"
    [[ "$out" == *sage:* ]] || fail "$name $arg printed no usage: $out"
    [ ! -s "$tmp/calls" ] || fail "$name $arg ran: $(tr '\n' ' ' <"$tmp/calls")"
    [ ! -e "$tmp/loop-$n" ] || fail "$name $arg touched the loop dir"
    [ -z "$(find "$h" -mindepth 1 | head -1)" ] || fail "$name $arg wrote under HOME"
    pass=$((pass + 1))
  done
done

# No argument still does the job.
: >"$tmp/calls"
HOME="$tmp/h0" FLEET_WATCH_CONFIG=c FLEET_WATCH_STATE=s FLEET_WATCH_LOOP_ONCE=1 FLEET_WATCH_LOOP_DIR="$tmp/loop-0" \
  PYTHON="$tmp/bin/python-stub" bash "$root/script/fleet-watch-loop.sh" >/dev/null 2>&1 </dev/null
grep -q python-stub "$tmp/calls" || fail "fleet-watch-loop.sh with no argument did not run a pass"
: >"$tmp/calls"
bash "$tmp/sync/dotfiles-sync.sh" >/dev/null 2>&1
grep -q session-sync "$tmp/calls" || fail "dotfiles-sync.sh with no argument did not sync"
# --status and --stop keep working.
HOME="$tmp/h0" FLEET_WATCH_LOOP_DIR="$tmp/loop-0" bash "$root/script/fleet-watch-loop.sh" --status >/dev/null 2>&1
[ $? -eq 1 ] || fail "--status changed behavior"
HOME="$tmp/h0" FLEET_WATCH_LOOP_DIR="$tmp/loop-0" bash "$root/script/fleet-watch-loop.sh" --stop >/dev/null 2>&1 || fail "--stop changed behavior"
printf 'PASS: %s cases\n' "$pass"
