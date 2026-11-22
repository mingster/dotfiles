#!/usr/bin/env bash
# mac/stowall with a stub stow on a throwaway config tree (refs #1457).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stowall="$here/../mac/stowall"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
check() { if "$@"; then pass=$((pass + 1)); echo "ok   $DESC"; else fail=$((fail + 1)); echo "FAIL $DESC"; fi; }

mkdir -p "$tmp/dot/.config/pkga" "$tmp/dot/.config/pkgb" "$tmp/stub" "$tmp/nostow"
cat >"$tmp/stub/stow" <<'STUB'
#!/usr/bin/env bash
[ "${STOW_FAIL:-}" = "$2" ] && { echo "stow: conflict in $2" >&2; exit 1; }
echo "$*" >>"$STOW_LOG"
STUB
chmod +x "$tmp/stub/stow"
for tool in basename tput; do ln -s "$(command -v "$tool")" "$tmp/nostow/$tool"; done

run() { env DOTFILES="$tmp/dot" STOW_LOG="$tmp/log" "$@" >"$tmp/out" 2>&1; }

DESC="success path exits 0 and stows every package"
: >"$tmp/log"
run PATH="$tmp/stub:$PATH" TERM=xterm bash "$stowall"; rc=$?
check test "$rc" -eq 0 -a "$(wc -l <"$tmp/log" | tr -d ' ')" = 2

DESC="a failing package exits non zero and is named"
run PATH="$tmp/stub:$PATH" TERM=xterm STOW_FAIL=pkgb bash "$stowall"; rc=$?
check test "$rc" -ne 0
DESC="failure output names pkgb and does not claim success"
check test -n "$(grep pkgb "$tmp/out")" -a -z "$(grep 'All packages stowed' "$tmp/out")"

DESC="missing stow exits non zero and says so"
run PATH="$tmp/nostow" TERM=xterm /bin/bash "$stowall"; rc=$?
check test "$rc" -ne 0 -a -n "$(grep -i 'stow' "$tmp/out")"

DESC="no TERM still succeeds with no tput error or escape codes"
env -u TERM DOTFILES="$tmp/dot" STOW_LOG="$tmp/log" PATH="$tmp/stub:$PATH" bash "$stowall" >"$tmp/out" 2>&1; rc=$?
check test "$rc" -eq 0 -a -z "$(grep -a -E 'tput|'$'\033' "$tmp/out")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
