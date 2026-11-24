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

# Schema stamp (#1725): a lockfile in the sub dir is found, an unchanged head skips, a schema only change regenerates.
mkdir -p "$tmp/lane-s/web/prisma"
printf 'lock\n' > "$tmp/lane-s/web/bun.lock"; printf 'model A {}\n' > "$tmp/lane-s/web/prisma/schema.prisma"
printf '#!/bin/sh\necho install >> "$INSTALL_LOG"\nmkdir -p node_modules\n' > "$tmp/bin/bun"
printf '#!/bin/sh\necho "$@" >> "$GEN_LOG"\n' > "$tmp/bin/bunx"
chmod +x "$tmp/bin/bun" "$tmp/bin/bunx"
export GEN_LOG="$tmp/gens"; : > "$INSTALL_LOG"; : > "$GEN_LOG"
run_sub() { PATH="$tmp/bin:$PATH" bash "$heavy" --host fixture --repo-dir checkout --dir "$tmp/lane-s" --sub web --gate "$tmp/gate" -- true >"$tmp/out" 2>&1; }
count() { wc -l < "$1" | tr -d ' '; }
run_sub
if [ "$(count "$INSTALL_LOG")" = 1 ] && [ "$(count "$GEN_LOG")" = 1 ] && [ -f "$tmp/lane-s/web/.remote-heavy-lock-sha" ]; then check "a lockfile in the sub dir is found: installs and generates once" ok; else check "a lockfile in the sub dir is found: installs and generates once" bad; fi
run_sub
if [ "$(count "$INSTALL_LOG")" = 1 ] && [ "$(count "$GEN_LOG")" = 1 ]; then check "an unchanged head skips install and generate" ok; else check "an unchanged head skips install and generate" bad; fi
printf 'model A {}\nmodel B {}\n' > "$tmp/lane-s/web/prisma/schema.prisma"
run_sub
if [ "$(count "$GEN_LOG")" = 2 ] && grep -q generate "$GEN_LOG"; then check "a schema only change regenerates the client" ok; else check "a schema only change regenerates the client" bad; fi
# A failing generate after a successful install fails the run and keeps the new schema out of the stamp (#1725).
printf 'model C {}\n' > "$tmp/lane-s/web/prisma/schema.prisma"
new_sum=$({ sha256sum 2>/dev/null || shasum -a 256; } < "$tmp/lane-s/web/prisma/schema.prisma" | cut -d' ' -f1)
printf '#!/bin/sh\necho "$@" >> "$GEN_LOG"\necho "prisma generate: boom-line"\nexit 1\n' > "$tmp/bin/bunx"
run_sub; rc=$?
if [ "$rc" -ne 0 ]; then check "a failing prisma generate exits non zero" ok; else check "a failing prisma generate exits non zero" bad; fi
if grep -q 'prisma generate: boom-line' "$tmp/out"; then check "a failing prisma generate prints its log line" ok; else check "a failing prisma generate prints its log line" bad; fi
if ! grep -qs ":$new_sum" "$tmp/lane-s/web/.remote-heavy-lock-sha"; then check "a failing prisma generate does not stamp the new schema hash" ok; else check "a failing prisma generate does not stamp the new schema hash" bad; fi

echo "remote-heavy-install: $pass passed, $fail failed"
[ "$fail" -eq 0  ]
