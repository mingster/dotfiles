#!/usr/bin/env bash
# Tests for bin/with-keychain with a stub `security` on PATH. Run: bash bin/with-keychain.test.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../script/tests/lib/asdf-pin.sh
. "$here/../script/tests/lib/asdf-pin.sh"
SCRIPT="$here/with-keychain"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

# Stub: knows ALPHA and BETA; any other item is missing (and still prints a value, to catch a leak). Logs the service it was asked for.
cat > "$tmp/security" <<'STUB'
#!/bin/sh
[ "$1" = find-generic-password ] || exit 44
svc=
while [ $# -gt 0 ]; do [ "$1" = -s ] && svc=$2; shift; done
case "$svc" in
  ALPHA) echo "secret-alpha-value" ;;
  BETA) echo "secret-beta-value" ;;
  *) echo "leaked-stdout-value"; echo "security: item not found" >&2; exit 44 ;;
esac
STUB
chmod +x "$tmp/security"
export PATH="$tmp:$PATH" USER=tester
run() { sh "$SCRIPT" "$@"; }

out=$(run ALPHA BETA -- sh -c 'printf "%s|%s" "$ALPHA" "$BETA"' 2>&1); rc=$?
check "exports the named vars to the command" "$([ $rc = 0 ] && [ "$out" = "secret-alpha-value|secret-beta-value" ]; echo $?)"

# Bad usage: no names, no --, no command, nothing at all. Each exits 2 with the usage line.
for args in "-- true" "ALPHA true" "ALPHA --" ""; do
  # shellcheck disable=SC2086
  out=$(run $args 2>&1); rc=$?
  check "bad usage exits 2: '$args'" "$([ $rc = 2 ] && echo "$out" | grep -q '^Usage: with-keychain'; echo $?)"
done

out=$(run ALPHA NOPE -- sh -c 'echo ran' 2>&1); rc=$?
check "missing item exits 1 and names the item" "$([ $rc = 1 ] && echo "$out" | grep -q "'NOPE'"; echo $?)"
check "missing item never prints a value or runs the command" "$(echo "$out" | grep -qE "secret-|leaked-|^ran$"; [ $? = 1 ]; echo $?)"

# The caller shell is unchanged: run in a subshell, the var stays unset afterwards.
unset ALPHA
( run ALPHA -- true )
check "caller shell does not get the var" "$([ -z "${ALPHA:-}" ]; echo $?)"
# The command gets the caller's other env too, and its exit status passes through.
run ALPHA -- sh -c 'exit 7'; rc=$?
check "command exit status passes through" "$([ $rc = 7 ]; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
