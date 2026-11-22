#!/usr/bin/env bash
# Tests for bin/agy with a fake agy on PATH. Run: bash bin/agy.test.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../script/tests/lib/asdf-pin.sh
. "$here/../script/tests/lib/asdf-pin.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

# A copy of the wrapper in its own dir, so "itself on PATH" is a dir the test controls.
mkdir -p "$tmp/wrap" "$tmp/real" "$tmp/empty"
cp "$here/agy" "$tmp/wrap/agy"
cat > "$tmp/real/agy" <<'FAKE'
#!/bin/sh
echo "real agy args=$* SSH_CONNECTION=${SSH_CONNECTION-unset} SSH_TTY=${SSH_TTY-unset} SSH_CLIENT=${SSH_CLIENT-unset}"
FAKE
chmod +x "$tmp/real/agy"
export SSH_CONNECTION="1 2 3 4" SSH_TTY=/dev/ttys001 SSH_CLIENT="1 2 3"
base=/usr/bin:/bin
# A wrapper that loops on itself must fail the test, not hang it.
wrap() {
  sh "$tmp/wrap/agy" "$@" & local pid=$!
  ( sleep 10; kill "$pid" ) >/dev/null 2>&1 & local wd=$!
  wait "$pid"; local rc=$?
  kill "$wd" >/dev/null 2>&1
  return $rc
}

out=$(PATH="$tmp/wrap:$tmp/real:$base" wrap one two 2>&1); rc=$?
check "runs the real agy with its args" "$([ $rc = 0 ] && echo "$out" | grep -q 'real agy args=one two'; echo $?)"
check "SSH_CONNECTION, SSH_TTY, SSH_CLIENT are unset for the real agy" "$(echo "$out" | grep -q 'SSH_CONNECTION=unset SSH_TTY=unset SSH_CLIENT=unset'; echo $?)"

# The wrapper is first on PATH and reached through a symlink: it must still skip itself.
ln -s "$tmp/wrap" "$tmp/wraplink"
out=$(PATH="$tmp/wraplink:$tmp/real:$base" wrap 2>&1); rc=$?
check "skips itself on PATH even through a symlinked dir" "$([ $rc = 0 ] && echo "$out" | grep -q 'real agy'; echo $?)"

# No real agy: exit 127.
out=$(PATH="$tmp/wrap:$tmp/empty:$base" wrap 2>&1); rc=$?
check "exit 127 when no real agy exists" "$([ $rc = 127 ] && echo "$out" | grep -q 'no agy found'; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
