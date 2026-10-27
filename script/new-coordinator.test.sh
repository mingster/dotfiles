#!/usr/bin/env bash
# Run new-coordinator.sh against a fake HOME, fake tools and a local fake agent-state repo.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 AGENT_STATE_SKIP_LAUNCHCTL=1
mkdir -p "$HOME/Library/LaunchAgents" "$tmp/bin" "$HOME/.claude/state/bin"
export PATH="$tmp/bin:$PATH"
for t in brew orca bun claude cursor-agent; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n' "$t" "$tmp" >"$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncase "$1" in auth) exit "${FAKE_GH_AUTH:-0}" ;; api) echo fakeowner ;; esac\n' >"$tmp/bin/gh"
printf '#!/usr/bin/env bash\ncase "$*" in *down-host*) exit 1 ;; esac\nexit 0\n' >"$tmp/bin/ssh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/pgrep"
chmod +x "$tmp/bin/gh" "$tmp/bin/ssh" "$tmp/bin/pgrep"

# Fake project repo and fake agent-state with a stub sync.sh.
git init -q -b main "$tmp/proj-src"
git -C "$tmp/proj-src" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git init -q -b main "$tmp/state-src"
cd "$tmp/state-src" || exit 2
printf 'repo %s apps/one\nhost up-host\nhost down-host\nlaunchagent fake.plist\nwaiter .claude/state/bin/wait.sh\n' "$tmp/proj-src" >coordinator.conf
echo 'brew "jq"' >Brewfile
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "sync $*" >>"%s/calls"\n[ "$1" = install-agents ] && touch "$HOME/Library/LaunchAgents/fake.plist"\nexit 0\n' "$tmp" >sync.sh
git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m init
cd "$tmp" || exit 2

pass=0 fail=0
check() { if "$@"; then pass=$((pass + 1)); echo "ok   $DESC"; else fail=$((fail + 1)); echo "FAIL $DESC"; fi; }
nc() { bash "$here/new-coordinator.sh" --state-url "$tmp/state-src" "$@"; }

DESC="dry run on an empty machine changes nothing"
nc --dry-run >"$tmp/dry1" 2>&1; rc=$?
check test "$rc" -eq 0 -a ! -e "$HOME/agent-state" -a ! -e "$tmp/calls"
DESC="dry run lists the owner steps"
check grep -q 'Only the owner can do these' "$tmp/dry1"

git clone -q "$tmp/state-src" "$HOME/agent-state"
DESC="dry run with agent-state present names the steps"
nc --dry-run >"$tmp/dry2" 2>&1
check grep -q 'would run: brew bundle' "$tmp/dry2"
DESC="dry run does not clone the repos"
check test ! -e "$HOME/apps/one"

DESC="real run exits 1 while a host is down and the waiter is missing"
nc >"$tmp/run1" 2>&1; rc=$?
check test "$rc" -eq 1
DESC="real run clones repos, bundles, restores state, installs agents"
check test -d "$HOME/apps/one/.git" -a -d "$HOME/agent-state/.git" && grep -q '^+ brew bundle' "$tmp/run1"
DESC="sync pull and install-agents were called"
check grep -q 'sync pull' "$tmp/calls"
DESC="reports the unreachable host"
check grep -q 'FAIL ssh down-host unreachable' "$tmp/run1"
DESC="reports the reachable host"
check grep -q 'ok   ssh up-host' "$tmp/run1"
DESC="reports the missing inbox waiter"
check grep -q 'FAIL inbox waiter missing' "$tmp/run1"

printf '#!/bin/bash\ntrue\n' >"$HOME/.claude/state/bin/wait.sh"; chmod +x "$HOME/.claude/state/bin/wait.sh"
sed -i.bak '/down-host/d' "$HOME/agent-state/coordinator.conf"
DESC="all green run exits 0"
nc >"$tmp/run2" 2>&1; rc=$?
check test "$rc" -eq 0
DESC="Orca restore is skipped without --orca-data and listed as an owner step"
check grep -q 'Copy the Orca data folder' "$tmp/run2"

mkdir -p "$tmp/orca-old" && echo data >"$tmp/orca-old/f"
nc --orca-data "$tmp/orca-old" >"$tmp/run3" 2>&1
DESC="Orca data is restored from a folder"
check test -f "$HOME/Library/Application Support/orca/f"
DESC="no names of projects, hosts or people in the script"
check bash "$here/tests/no-project-names.test.sh"

FAKE_GH_AUTH=1 nc >"$tmp/run4" 2>&1; rc=$?
DESC="stops with a clear message when gh is not signed in"
check test "$rc" -eq 1 && grep -q 'gh auth login' "$tmp/run4"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
