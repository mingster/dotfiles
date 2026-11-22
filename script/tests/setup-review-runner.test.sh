#!/usr/bin/env bash
# setup-review-runner.sh: args, existing .runner skips download and config, SessionCreate delete is
# tolerant, .path is written, bootout then bootstrap use the gui/<uid>/<label> label.
# Stubs gh, curl, launchctl and the runner scripts under a temp HOME; no network, no real launchd.
# PlistBuddy is the real macOS tool (the script calls it by absolute path) on a temp plist.
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
script="$here/script/setup-review-runner.sh"
[ -x /usr/libexec/PlistBuddy ] || { echo "skip: PlistBuddy needs macOS"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$here/script/tests/lib/asdf-pin.sh"
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

repo=acme/widgets name=mini9
label=actions.runner.acme-widgets.$name
plist=$HOME/Library/LaunchAgents/$label.plist
log=$tmp/calls.log
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$tmp/pkg"

stub() { printf '#!/bin/sh\n%s\n' "$2" >"$HOME/.local/bin/$1"; chmod +x "$HOME/.local/bin/$1"; }
stub gh   'echo "gh $*" >>"$CALLS"; case "$*" in *releases/latest*) echo v2.999.0 ;; *) echo tok ;; esac'
stub launchctl 'echo "launchctl $*" >>"$CALLS"'
# curl serves a tarball holding stub config.sh and svc.sh (svc.sh install writes a plist with SessionCreate).
cat >"$tmp/pkg/config.sh" <<'SH'
#!/bin/sh
echo "config.sh $*" >>"$CALLS"
echo cfg >.runner
SH
cat >"$tmp/pkg/svc.sh" <<'SH'
#!/bin/sh
echo "svc.sh $*" >>"$CALLS"
/usr/libexec/PlistBuddy -c 'Add :Label string x' -c 'Add :SessionCreate bool true' "$PLIST" >/dev/null
SH
chmod +x "$tmp/pkg/config.sh" "$tmp/pkg/svc.sh"
tar -czf "$tmp/runner.tgz" -C "$tmp/pkg" config.sh svc.sh
stub curl 'echo "curl $*" >>"$CALLS"; cat "$TGZ"'
export CALLS=$log TGZ=$tmp/runner.tgz PLIST=$plist

run() { : >"$log"; "$script" "$@" >"$tmp/out" 2>&1; }
has() { grep -qF -- "$1" "$log" && echo 0 || echo 1; }
hasnt() { grep -qF -- "$1" "$log" && echo 1 || echo 0; }
plist_has() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" >/dev/null 2>&1 && echo 0 || echo 1; }
reset_plist() { rm -f "$plist"; /usr/libexec/PlistBuddy -c 'Add :Label string x' "$plist" >/dev/null; }

# 1. missing args
"$script" >/dev/null 2>&1; check "no args exits non zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
"$script" "$repo" >/dev/null 2>&1; check "one arg exits non zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# 2. existing .runner skips download and config; SessionCreate present is deleted
dir=$tmp/runner-existing; mkdir -p "$dir"; echo cfg >"$dir/.runner"
reset_plist; /usr/libexec/PlistBuddy -c 'Add :SessionCreate bool true' "$plist" >/dev/null
run "$repo" "$name" "$dir"; rc=$?
check "existing runner: succeeds" "$rc"
check "existing runner: no gh call" "$(hasnt 'gh ')"
check "existing runner: no curl download" "$(hasnt 'curl ')"
check "existing runner: no config.sh" "$(hasnt 'config.sh')"
check "existing runner: SessionCreate deleted" "$([ "$(plist_has SessionCreate)" = 1 ] && echo 0 || echo 1)"
check ".path written with the script PATH" "$([ "$(cat "$dir/.path")" = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.node_modules/bin:/usr/bin:/bin:/usr/sbin:/sbin" ] && echo 0 || echo 1)"

# 3. SessionCreate absent: the delete fails but the run still succeeds
reset_plist
run "$repo" "$name" "$dir"; check "SessionCreate absent: run still succeeds" "$?"
check "SessionCreate absent: bootstrap still runs" "$(has 'launchctl bootstrap')"

# 4. bootout then bootstrap with the gui/<uid>/<label> label
dom=gui/$(id -u)
check "bootout uses domain/label" "$(has "launchctl bootout $dom/$label")"
check "bootstrap uses domain and plist" "$(has "launchctl bootstrap $dom $plist")"
order=$(grep -n '^launchctl' "$log" | cut -d' ' -f2 | paste -sd, -)
check "bootout runs before bootstrap" "$([ "$order" = bootout,bootstrap ] && echo 0 || echo 1)"

# 5. no .runner: downloads, configures with the review label, installs the service
dir=$tmp/runner-fresh; rm -f "$plist"
run "$repo" "$name" "$dir"; check "fresh runner: succeeds" "$?"
check "fresh runner: downloads the tarball" "$(has 'curl -fsSL https://github.com/actions/runner/releases/download/v2.999.0/')"
check "fresh runner: config.sh gets repo, name and review label" "$(has "config.sh --unattended --url https://github.com/$repo --token tok --name $name --labels review --replace")"
check "fresh runner: svc.sh install runs when no plist" "$(has 'svc.sh install')"
check "fresh runner: SessionCreate removed after install" "$([ "$(plist_has SessionCreate)" = 1 ] && echo 0 || echo 1)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
