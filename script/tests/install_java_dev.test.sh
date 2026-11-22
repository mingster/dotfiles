#!/usr/bin/env bash
# install_java_dev.sh: asdf missing exits 1 with the hint; the .asdfrc line is added once over two runs (#1498).
# Every tool is a stub on a private PATH and HOME is a temp folder, so nothing real is installed.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/install_java_dev.sh"
BASH_BIN="$(command -v bash)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # fresh <name>: new HOME and a bin dir with only grep
  CASE="$TMP/$1"
  BIN="$CASE/bin"
  mkdir -p "$BIN" "$CASE/home"
  ln -s "$(command -v grep)" "$BIN/grep"
  : >"$CASE/log"
}
stub() { # stub <name> <body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
run() {
  HOME="$CASE/home" PATH="$BIN" LOG="$CASE/log" "$BASH_BIN" "$SCRIPT" 2>"$CASE/err" >"$CASE/out"
}

fresh noasdf
run
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "install_java_dev: asdf not found; run script/install_asdf.sh first" "$CASE/err"; } \
  && ok "missing asdf exits 1 with the install_asdf.sh hint" || bad "missing asdf exits 1 with the install_asdf.sh hint" "rc=$rc $(cat "$CASE/out" "$CASE/err")"
[ ! -e "$CASE/home/.asdfrc" ] && ok "missing asdf writes no .asdfrc" || bad "missing asdf writes no .asdfrc"

fresh twice
# Java is already added and installed, so only the .asdfrc line is left to write.
stub asdf 'echo "asdf $*" >>"$LOG"
case "$1" in plugin) echo java ;; list) echo openjdk-21 ;; esac'
stub java 'echo "openjdk 21"'
run
rc1=$?
run
rc2=$?
count=$(grep -cxF 'java_macos_integration_enable=yes' "$CASE/home/.asdfrc" 2>/dev/null || true)
{ [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$count" = 1 ]; } \
  && ok ".asdfrc line is added once over two runs" || bad ".asdfrc line is added once over two runs" "rc1=$rc1 rc2=$rc2 count=$count $(cat "$CASE/err")"
grep -q "^asdf set -u java openjdk-21$" "$CASE/log" && ok "pins java openjdk-21 through asdf" || bad "pins java openjdk-21 through asdf" "$(cat "$CASE/log")"
! grep -q "^asdf install\|^asdf plugin add" "$CASE/log" && ok "skips plugin add and install when already present" || bad "skips plugin add and install when already present" "$(cat "$CASE/log")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
