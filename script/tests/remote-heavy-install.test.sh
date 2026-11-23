#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# No network: run the transported remote script locally (stub ssh) with a fake package manager that records installs.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
heavy=$(cd "$here/.." && pwd)/remote-heavy.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME" "$tmp/bin" "$tmp/lane"
pass=0; fail=0
check() { if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi; }

printf '#!/bin/sh\n[ "$1" != rev-parse ] || echo fixture-sha\nexit 0\n' > "$tmp/bin/git"
printf '#!/bin/sh\nshift\nexec /bin/sh -c "$*"\n' > "$tmp/bin/ssh"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$tmp/gate"
# The fake installer counts runs and creates node_modules, like a real install plus its postinstall.
printf '#!/bin/sh\necho "$1" >> "$INSTALL_LOG"\nmkdir -p node_modules\nexit "${INSTALL_EXIT:-0}"\n' > "$tmp/bin/bun"
chmod +x "$tmp/bin/git" "$tmp/bin/ssh" "$tmp/gate" "$tmp/bin/bun"
export INSTALL_LOG="$tmp/installs"
printf 'lock v1\n' > "$tmp/lane/bun.lock"

run_heavy() {
  PATH="$tmp/bin:$PATH" bash "$heavy" --host fixture --repo-dir checkout --dir "$tmp/lane" --gate "$tmp/gate" -- sh -c 'test -d node_modules' >"$tmp/out" 2>&1
}
installs() { [ -f "$INSTALL_LOG" ] && wc -l < "$INSTALL_LOG" | tr -d ' ' || echo 0; }

run_heavy; rc=$?
if [ "$rc" -eq 0 ] && [ "$(installs)" = 1 ]; then check "a checkout with no install is installed before the step" ok; else check "a checkout with no install is installed before the step" bad; fi
run_heavy
if [ "$(installs)" = 1 ]; then check "an unchanged lockfile does not reinstall" ok; else check "an unchanged lockfile does not reinstall" bad; fi
printf 'lock v2\n' > "$tmp/lane/bun.lock"
run_heavy
if [ "$(installs)" = 2 ]; then check "a changed lockfile reinstalls" ok; else check "a changed lockfile reinstalls" bad; fi
rm -rf "$tmp/lane/node_modules"
run_heavy
if [ "$(installs)" = 3 ]; then check "a stamp with no node_modules reinstalls" ok; else check "a stamp with no node_modules reinstalls" bad; fi
printf 'lock v3\n' > "$tmp/lane/bun.lock"
INSTALL_EXIT=1 run_heavy; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q 'lock v3' "$tmp/lane/.remote-heavy-lock-sha" 2>/dev/null; then check "a failed install exits non zero and leaves no stamp for the new lockfile" ok; else check "a failed install exits non zero and leaves no stamp for the new lockfile" bad; fi


# Two runs on one host never share an install log (#1599). Lane b fails after lane a has started writing.
export TMPDIR="$tmp/tmpd"; mkdir -p "$TMPDIR" "$tmp/lane-a" "$tmp/lane-b"
printf 'lock\n' > "$tmp/lane-a/bun.lock"; printf 'lock\n' > "$tmp/lane-b/bun.lock"
cat > "$tmp/bin/bun" <<'STUB'
#!/bin/sh
lane=$(basename "$PWD")
case "$lane" in
  lane-b)
    for i in $(seq 1 3); do echo "LOG-B-$i"; done; : > "$SYNC/b-wrote"
    for i in $(seq 1 100); do [ -f "$SYNC/a-wrote" ] && break; sleep 0.1; done
    exit 1 ;;
  lane-a)
    for i in $(seq 1 100); do [ -f "$SYNC/b-wrote" ] && break; sleep 0.1; done; echo "LOG-A-line"; : > "$SYNC/a-wrote"
    for i in $(seq 1 100); do [ -f "$SYNC/b-done" ] && break; sleep 0.1; done
    mkdir -p node_modules; exit 0 ;;
esac
STUB
chmod +x "$tmp/bin/bun"
export SYNC="$tmp/sync"; mkdir -p "$SYNC"
heavy_lane() { PATH="$tmp/bin:$PATH" bash "$heavy" --host fixture --repo-dir checkout --dir "$tmp/$1" --gate "$tmp/gate" -- true >"$tmp/out-$1" 2>&1; echo $? > "$tmp/rc-$1"; }
heavy_lane lane-a & pa=$!
heavy_lane lane-b; : > "$SYNC/b-done"; wait "$pa"
if [ "$(cat "$tmp/rc-lane-b")" != 0 ] && [ "$(cat "$tmp/rc-lane-a")" = 0 ]; then check "concurrent runs: the failing one exits non zero, the other succeeds" ok; else check "concurrent runs: the failing one exits non zero, the other succeeds" bad; fi
if grep -q LOG-B-3 "$tmp/out-lane-b" && ! grep -q LOG-A "$tmp/out-lane-b"; then check "the failure tail shows only its own install output" ok; else check "the failure tail shows only its own install output" bad; fi
if [ -z "$(ls -A "$TMPDIR")" ]; then check "no install log is left in the temp dir" ok; else check "no install log is left in the temp dir" bad; fi
unset TMPDIR

echo "remote-heavy-install: $pass passed, $fail failed"
[ "$fail" -eq 0  ]
