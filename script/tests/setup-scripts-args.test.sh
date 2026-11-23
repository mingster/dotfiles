#!/usr/bin/env bash
# The seven setup scripts take no arguments: -h/--help print usage and exit 0, anything else exits 2, and neither touches HOME (#1568).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Stubs so a script that wrongly runs its job cannot install anything.
mkdir -p "$tmp/bin"
for c in brew curl; do printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$c"; chmod +x "$tmp/bin/$c"; done

for name in orca zed grok cursor vscode antigravity claude-desktop; do
  script="$root/script/setup-$name.sh"
  for arg in -h --help --bogus; do
    h="$tmp/home-$name-${arg#--}"
    rm -rf "$h"; mkdir -p "$h"
    set +e
    out=$(HOME="$h" DOTFILES="$root" PATH="$tmp/bin:$PATH" bash "$script" "$arg" 2>&1)
    rc=$?
    set -e
    case "$arg" in
      --bogus) want=2 ;;
      *) want=0 ;;
    esac
    [ "$rc" -eq "$want" ] || fail "setup-$name $arg exited $rc, want $want: $out"
    [[ "$out" == *Usage:* ]] || fail "setup-$name $arg printed no usage: $out"
    left=$(find "$h" -mindepth 1 | head -3)
    [ -z "$left" ] || fail "setup-$name $arg wrote under HOME: $left"
    pass=$((pass + 1))
  done
done
printf 'PASS: %s cases\n' "$pass"
