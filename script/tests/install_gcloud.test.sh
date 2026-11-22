#!/usr/bin/env bash
# install_gcloud.sh: already installed, brew branch, missing after install (#1498).
# Every tool is a stub on a private PATH, so no real brew, sudo, apt or network runs.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/install_gcloud.sh"
BASH_BIN="$(command -v bash)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() { # fresh <name>: new HOME and a bin dir with only head
  CASE="$TMP/$1"
  BIN="$CASE/bin"
  mkdir -p "$BIN" "$CASE/home"
  ln -s "$(command -v head)" "$BIN/head"
  ln -s "$(command -v dirname)" "$BIN/dirname"; ln -s "$(command -v chmod)" "$BIN/chmod"
  : >"$CASE/log"
}
stub() { # stub <name> <body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
# A brew stub: the cask is not installed; "install" logs and, unless BREW_INSTALLS=no, puts gcloud on PATH.
brew_stub() {
  stub brew 'echo "brew $*" >>"$LOG"
case "$1" in
  list) exit 1 ;;
  install) if [ "${BREW_INSTALLS:-yes}" = yes ]; then printf "#!/bin/sh\necho Google Cloud SDK 1.0\n" >"$(dirname "$0")/gcloud"; chmod +x "$(dirname "$0")/gcloud"; fi ;;
esac'
}
run() {
  HOME="$CASE/home" PATH="$BIN" LOG="$CASE/log" "$BASH_BIN" "$SCRIPT" 2>"$CASE/err" >"$CASE/out"
}

fresh installed
stub gcloud 'echo "Google Cloud SDK 9.9.9"'
brew_stub
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "already installed (Google Cloud SDK 9.9.9)" "$CASE/out" && [ ! -s "$CASE/log" ]; } \
  && ok "already installed exits 0 with no install" || bad "already installed exits 0 with no install" "rc=$rc $(cat "$CASE/out" "$CASE/err" "$CASE/log")"

fresh brew
brew_stub
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "^brew install --cask google-cloud-sdk$" "$CASE/log" && grep -q "install_gcloud: ok (Google Cloud SDK 1.0)" "$CASE/out"; } \
  && ok "brew branch runs brew install --cask google-cloud-sdk" || bad "brew branch runs brew install --cask google-cloud-sdk" "rc=$rc $(cat "$CASE/out" "$CASE/err" "$CASE/log")"

fresh missing
brew_stub
BREW_INSTALLS=no run
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "gcloud not on PATH after install" "$CASE/err"; } \
  && ok "gcloud missing after install exits 1" || bad "gcloud missing after install exits 1" "rc=$rc $(cat "$CASE/out" "$CASE/err")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
