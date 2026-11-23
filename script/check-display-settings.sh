#!/usr/bin/env bash
# Print every Claude display key in a settings file that differs from the fleet value (#1409).
# Usage: check-display-settings.sh [settings.json]   (default ~/.claude/settings.json; -h and --help print this text)
# Keys: verbose=true, spinnerTipsEnabled=false, prefersReducedMotion=true, tui="fullscreen".
# Prints "display key <name>: <value or missing>" per drift and exits 1 when any is found. Prints no other settings value.
set -u
print_usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; }
for a in ${1+"$@"}; do case "$a" in -h|--help) print_usage; exit 0 ;; --) break ;; esac; done
f=${1:-$HOME/.claude/settings.json}
command -v jq >/dev/null || { echo 'check-display-settings requires jq' >&2; exit 2; }
[ -f "$f" ] || { echo "no settings file: $f" >&2; exit 2; }
out=$(jq -r '
  . as $s
  | {verbose: true, spinnerTipsEnabled: false, prefersReducedMotion: true, tui: "fullscreen"}
  | to_entries[]
  | . as $e
  | select($s[$e.key] != $e.value)
  | "display key \($e.key): \(if $s | has($e.key) then ($s[$e.key] | tojson) else "missing" end)"' "$f" 2>/dev/null) \
  || { echo "unreadable settings file: $f" >&2; exit 2; }
[ -z "$out" ] && exit 0
printf '%s\n' "$out"
exit 1
