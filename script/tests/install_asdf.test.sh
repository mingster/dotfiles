#!/usr/bin/env bash
# install_asdf.sh: already installed, brew path, Debian release binary, failed version lookup (#1496).
# Every tool is a stub on a private PATH, so no network and no real install runs.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/install_asdf.sh"
BASH_BIN="$(command -v bash)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fresh <name>: new HOME and a bin dir holding only the real basics the script needs.
fresh() {
  CASE="$TMP/$1"
  BIN="$CASE/bin"
  mkdir -p "$BIN" "$CASE/home"
  for t in mktemp rm mkdir cp chmod sed dirname cat; do ln -s "$(command -v "$t")" "$BIN/$t"; done
  : >"$CASE/log"
}
stub() { # stub <name> <body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
run() {
  HOME="$CASE/home" PATH="$BIN" LOG="$CASE/log" "$BASH_BIN" "$SCRIPT" 2>"$CASE/err" >"$CASE/out"
}
# Stubs for the Debian path. LOOKUP=fail makes the release lookup fail.
debian_stubs() {
  stub uname 'if [ "${1:-}" = -m ]; then echo "$ARCH"; fi'
  stub curl 'echo "curl $*" >>"$LOG"
case "$*" in
  *releases/latest*) [ "${LOOKUP:-ok}" = ok ] && echo "{\"tag_name\": \"v9.9.9\"}" || exit 22 ;;
  *) while [ $# -gt 0 ]; do [ "$1" = -o ] && echo x >"$2"; shift; done ;;
esac'
  stub tar 'dir=; while [ $# -gt 0 ]; do [ "$1" = -C ] && dir=$2; shift; done
printf "#!/bin/sh\necho 9.9.9\n" >"$dir/asdf"'
}

fresh installed
stub asdf 'echo 0.1.0'
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "already in PATH" "$CASE/out"; } && ok "already installed exits 0" || bad "already installed exits 0" "$(cat "$CASE/out" "$CASE/err")"

fresh brew
stub brew 'echo "brew $*" >>"$LOG"
case "$1" in list) exit 1 ;; install) printf "#!/bin/sh\necho 0.2.0\n" >"$(dirname "$0")/asdf"; chmod +x "$(dirname "$0")/asdf" ;; esac'
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "^brew install asdf$" "$CASE/log"; } && ok "brew path runs brew install asdf" || bad "brew path runs brew install asdf" "$(cat "$CASE/log" "$CASE/err")"

fresh debian
debian_stubs
ARCH=aarch64 run
rc=$?
{ [ "$rc" -eq 0 ] && [ -x "$CASE/home/.local/bin/asdf" ] \
  && grep -q "releases/download/v9.9.9/asdf-v9.9.9-linux-arm64.tar.gz" "$CASE/log" \
  && grep -q "ok (9.9.9)" "$CASE/out"; } && ok "debian installs the release binary for arm64 into ~/.local/bin and prints the version" \
  || bad "debian installs the release binary" "$(cat "$CASE/log" "$CASE/out" "$CASE/err")"

fresh amd64
debian_stubs
ARCH=x86_64 run
grep -q "linux-amd64.tar.gz" "$CASE/log" && ok "x86_64 maps to amd64" || bad "x86_64 maps to amd64" "$(cat "$CASE/log" "$CASE/err")"

fresh lookup
debian_stubs
ARCH=x86_64 LOOKUP=fail run
rc=$?
{ [ "$rc" -eq 1 ] && [ "$(cat "$CASE/err")" = "install_asdf: could not read the latest asdf release" ]; } \
  && ok "failed lookup prints the message and exits 1" || bad "failed lookup prints the message and exits 1" "rc=$rc $(cat "$CASE/err")"

fresh arch
debian_stubs
ARCH=riscv64 run
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "unsupported architecture riscv64" "$CASE/err"; } && ok "unsupported arch exits 1" || bad "unsupported arch exits 1" "rc=$rc $(cat "$CASE/err")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
