#!/usr/bin/env bash
# Replay command fixtures through the template guard-bash.py and report any that flip.
#
# Each file under <fixtures>/allow/ holds a command that must pass the guard (a false positive
# otherwise); each file under <fixtures>/deny/ holds a command the guard must refuse. Every
# later false positive becomes one new allow/ fixture in the PR that fixes it.
# The guard runs in a scratch project whose guard-config.json guards `deploy-raw.sh`, so
# fixtures name that script.
#
# Usage:  script/check-guard-false-positives.sh [fixtures-dir]
# Default: templates/agent-team/.claude/hooks/tests/fixtures
# Stderr: <fixture>:1: message per problem. Stdout: one summary line.
# Exit:   0 clean, 1 a fixture flipped, 2 usage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/templates/agent-team/.claude/hooks/guard-bash.py"
fixtures="$ROOT/templates/agent-team/.claude/hooks/tests/fixtures"

usage() { echo "usage: check-guard-false-positives.sh [fixtures-dir]" >&2; exit 2; }
case "${1:-}" in -h|--help) usage ;; esac
[ $# -le 1 ] || usage
[ $# -eq 0 ] || fixtures="$1"
[ -d "$fixtures/allow" ] && [ -d "$fixtures/deny" ] || { echo "check-guard-false-positives: $fixtures needs allow/ and deny/" >&2; exit 2; }

# The real interpreter, not an asdf shim: a shim fails under the scratch HOME below.
PY="$(python3 -c 'import sys; print(sys.executable)')" || exit 2
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/project/.claude/hooks" "$scratch/home"
printf '%s\n' '{"blocked_scripts": ["deploy-raw.sh"]}' >"$scratch/project/.claude/hooks/guard-config.json"

# Prints deny or allow for the command in file $1.
verdict() {
  local out
  "$PY" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":open(sys.argv[2]).read()}}))' \
    "$scratch/project" "$1" >"$scratch/input.json"
  out=$(HOME="$scratch/home" "$PY" "$HOOK" <"$scratch/input.json" 2>/dev/null)
  if grep -q '"permissionDecision": "deny"' <<<"$out"; then echo deny; else echo allow; fi
}

checked=0 problems=0
for kind in allow deny; do
  for f in "$fixtures/$kind"/*; do
    [ -f "$f" ] || continue
    checked=$((checked + 1))
    got=$(verdict "$f")
    if [ "$got" != "$kind" ]; then
      problems=$((problems + 1))
      if [ "$kind" = allow ]; then
        echo "$f:1: allow fixture is blocked by the guard (false positive)" >&2
      else
        echo "$f:1: deny fixture passes the guard" >&2
      fi
    fi
  done
done

echo "check-guard-false-positives: $checked fixtures, $problems problems"
[ "$problems" -eq 0 ]
