#!/usr/bin/env bash
# install_zed.sh: already on PATH, pacman message, brew branch, missing after install (#1498).
# Every tool is a stub on a private PATH, so no real brew, sudo or network runs.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/install_zed.sh"
BASH_BIN="$(command -v bash)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # fresh <name>: new HOME and a bin dir with no package manager
  CASE="$TMP/$1"
  BIN="$CASE/bin"
  mkdir -p "$BIN" "$CASE/home"
  : >"$CASE/log"
}
stub() { # stub <name> <body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
# A brew stub: --cask zed is not installed; "install" logs and, when BREW_INSTALLS=yes, puts zed on PATH.
brew_stub() {
  stub brew 'echo "brew $*" >>"$LOG"
case "$1" in
  list) exit 1 ;;
  install) if [ "${BREW_INSTALLS:-yes}" = yes ]; then printf "#!/bin/sh\n" >"$(dirname "$0")/zed"; chmod +x "$(dirname "$0")/zed"; fi ;;
esac'
  ln -s "$(command -v dirname)" "$BIN/dirname"; ln -s "$(command -v chmod)" "$BIN/chmod"
}
run() {
  HOME="$CASE/home" PATH="$BIN" LOG="$CASE/log" "$BASH_BIN" "$SCRIPT" 2>"$CASE/err" >"$CASE/out"
}

fresh onpath
stub zed 'exit 0'
brew_stub
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "zed already in PATH" "$CASE/out" && [ ! -s "$CASE/log" ]; } && ok "zed on PATH exits 0 with no install" || bad "zed on PATH exits 0 with no install" "rc=$rc $(cat "$CASE/out" "$CASE/err" "$CASE/log")"

fresh pacman
stub pacman 'echo "pacman $*" >>"$LOG"; [ "$1 $2" = "-Q zed" ]'
brew_stub
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "zed installed via pacman" "$CASE/out" && ! grep -q "^brew" "$CASE/log"; } \
  && ok "pacman-installed zed prints the pacman message and never reaches brew" || bad "pacman-installed zed prints the pacman message" "rc=$rc $(cat "$CASE/out" "$CASE/err" "$CASE/log")"

fresh brew
brew_stub
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "^brew install --cask zed$" "$CASE/log" && grep -q "install_zed: ok" "$CASE/out"; } \
  && ok "brew branch runs brew install --cask zed" || bad "brew branch runs brew install --cask zed" "rc=$rc $(cat "$CASE/out" "$CASE/err" "$CASE/log")"

fresh missing
brew_stub
BREW_INSTALLS=no run
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "zed not on PATH. If you used install.sh, add ~/.local/bin to PATH" "$CASE/err"; } \
  && ok "zed missing after install exits 1 with the PATH hint" || bad "zed missing after install exits 1 with the PATH hint" "rc=$rc $(cat "$CASE/out" "$CASE/err")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
