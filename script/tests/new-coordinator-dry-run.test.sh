#!/usr/bin/env bash
# script/new-coordinator.sh with HOME in a temp dir and stub brew, gh, git, launchctl, ssh:
# --dry-run changes nothing and lists every step, bad arguments fail, a failing step is counted.
here=$(cd "$(dirname "$0")/.." && pwd)
script="$here/new-coordinator.sh"
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

stubs="$tmp/stubs"; home="$tmp/home"; calls="$tmp/calls.log"
mkdir -p "$stubs" "$home/agent-state/.git"
for t in brew gh git launchctl orca bun claude cursor-agent; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$t" "$calls" > "$stubs/$t"
done
printf '#!/bin/sh\necho "ssh $*" >> "%s"\n[ -z "${STUB_SSH_FAIL-}" ]\n' "$calls" > "$stubs/ssh"
chmod +x "$stubs"/*
cat > "$home/agent-state/coordinator.conf" <<'EOS'
# comment
repo https://example.invalid/r.git GitHub/r
host mini7
launchagent com.example.job.plist
EOS
: > "$home/agent-state/Brewfile"
printf '#!/bin/sh\necho "sync $*" >> "%s"\n' "$calls" > "$home/agent-state/sync.sh"

run() { HOME="$home" PATH="$stubs:/usr/bin:/bin" "$@"; }
snap() { (cd "$home" && find . | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort) ; }

# --dry-run: no change under HOME, no stub called, every step printed.
before=$(snap); : > "$calls"
out=$(run bash "$script" --dry-run 2>&1); rc=$?
after=$(snap)
check "dry-run exits 0" "$([ "$rc" = 0 ]; echo $?)"
check "dry-run changes nothing under HOME" "$([ "$before" = "$after" ]; echo $?)"
check "dry-run runs no tool" "$([ ! -s "$calls" ]; echo $?)"
missing=0
for s in "Tools (Homebrew, git, gh)" "Clone agent-state" "Homebrew packages" "Clone repos" \
  "Restore memory and state" "Install LaunchAgents" "Orca data restore" "Health checks" "Only the owner can do these"; do
  echo "$out" | grep -qF "== $s" || { missing=1; echo "  missing step: $s"; }
done
check "dry-run prints every step" "$missing"
echo "$out" | grep -qF "would run: brew bundle" && echo "$out" | grep -qF "would run: git clone https://example.invalid/r.git $home/GitHub/r"
check "dry-run shows what it would run" "$?"

# Argument errors and help.
out=$(run bash "$script" --nope 2>&1); rc=$?
check "unknown option exits 2" "$([ "$rc" = 2 ] && echo "$out" | grep -q 'unknown option: --nope'; echo $?)"
out=$(run bash "$script" --state-repo 2>&1); rc=$?
check "--state-repo without a value fails" "$([ "$rc" != 0 ]; echo $?)"
out=$(run bash "$script" --help 2>&1); rc=$?
check "--help prints the usage" "$([ "$rc" = 0 ] && echo "$out" | grep -q '^# Usage: new-coordinator.sh'; echo $?)"

# Real run: all good exits 0; a failing step is counted and exits non zero.
mkdir -p "$home/Library/LaunchAgents"; : > "$home/Library/LaunchAgents/com.example.job.plist"
mkdir -p "$home/GitHub/r/.git"
out=$(run bash "$script" 2>&1); rc=$?
check "all steps pass exits 0" "$([ "$rc" = 0 ]; echo $?)"
out=$(STUB_SSH_FAIL=1 run bash "$script" 2>&1); rc=$?
check "failing ssh step is reported" "$(echo "$out" | grep -q 'FAIL ssh mini7 unreachable'; echo $?)"
check "failing step exits non zero with the count" "$([ "$rc" != 0 ] && echo "$out" | grep -q '^1 check(s) failed'; echo $?)"
rm "$home/Library/LaunchAgents/com.example.job.plist"
out=$(STUB_SSH_FAIL=1 run bash "$script" 2>&1); rc=$?
check "two failing steps are counted as two" "$([ "$rc" != 0 ] && echo "$out" | grep -q '^2 check(s) failed'; echo $?)"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
