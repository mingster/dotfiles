#!/usr/bin/env bash
# install_aws_cli.sh: already installed, unsupported arch, missing unzip, temp folder removed after a failed unzip (#1497).
# Every tool is a stub on a private PATH, so no network, no sudo and no real install runs.
# shellcheck source=script/tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/script/install_aws_cli.sh"
BASH_BIN="$(command -v bash)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -gt 1 ] && echo "$2"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fresh <name>: new HOME, TMPDIR and a bin dir holding only the real basics the script needs.
fresh() {
  CASE="$TMP/$1"
  BIN="$CASE/bin"
  mkdir -p "$BIN" "$CASE/home" "$CASE/tmp"
  for t in mktemp rm mkdir head mv dirname; do ln -s "$(command -v "$t")" "$BIN/$t"; done
  : >"$CASE/log"
}
stub() { # stub <name> <body>
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}
run() {
  HOME="$CASE/home" TMPDIR="$CASE/tmp" PATH="$BIN" LOG="$CASE/log" "$BASH_BIN" "$SCRIPT" 2>"$CASE/err" >"$CASE/out"
}
linux_stubs() {
  stub uname 'if [ "${1:-}" = -m ]; then echo "$ARCH"; fi'
  stub curl 'echo "curl $*" >>"$LOG"
while [ $# -gt 0 ]; do [ "$1" = -o ] && echo x >"$2"; shift; done'
  stub sudo 'echo "sudo $*" >>"$LOG"'
}

fresh installed
stub aws 'echo "aws-cli/2.0.0"'
run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "already installed (aws-cli/2.0.0)" "$CASE/out"; } && ok "already installed exits 0" || bad "already installed exits 0" "$(cat "$CASE/out" "$CASE/err")"

fresh arch
linux_stubs
ARCH=riscv64 run
rc=$?
{ [ "$rc" -eq 1 ] && grep -q "unsupported architecture riscv64" "$CASE/err"; } && ok "unsupported arch exits 1" || bad "unsupported arch exits 1" "rc=$rc $(cat "$CASE/err")"

fresh nounzip
linux_stubs
ARCH=x86_64 run
rc=$?
{ [ "$rc" -eq 1 ] && [ "$(cat "$CASE/err")" = "install_aws_cli: unzip is required (sudo apt-get install unzip)" ] && ! grep -q "^curl" "$CASE/log"; } \
  && ok "missing unzip prints the hint, exits 1 and downloads nothing" || bad "missing unzip prints the hint, exits 1 and downloads nothing" "rc=$rc $(cat "$CASE/err" "$CASE/log")"
[ -z "$(ls -A "$CASE/tmp")" ] && ok "missing unzip leaves no temp folder" || bad "missing unzip leaves no temp folder" "$(ls "$CASE/tmp")"

fresh failzip
linux_stubs
stub unzip 'echo "unzip $*" >>"$LOG"; exit 9'
ARCH=x86_64 run
rc=$?
{ [ "$rc" -ne 0 ] && grep -q "^unzip " "$CASE/log" && ! grep -q "^sudo" "$CASE/log"; } && ok "failed unzip stops before sudo" || bad "failed unzip stops before sudo" "rc=$rc $(cat "$CASE/log")"
grep -q "curl .*$CASE/tmp/" "$CASE/log" && ok "download goes into the mktemp folder, not /tmp" || bad "download goes into the mktemp folder" "$(cat "$CASE/log")"
[ -z "$(ls -A "$CASE/tmp")" ] && ok "temp folder is removed after a failed unzip" || bad "temp folder is removed after a failed unzip" "$(ls "$CASE/tmp")"

fresh success
linux_stubs
stub unzip 'echo "unzip $*" >>"$LOG"'
stub aws 'echo "aws-cli/2.1.0"'
mv "$BIN/aws" "$CASE/aws.later"
stub sudo 'echo "sudo $*" >>"$LOG"; mv "$(dirname "$0")/../aws.later" "$(dirname "$0")/aws"'
ARCH=aarch64 run
rc=$?
{ [ "$rc" -eq 0 ] && grep -q "linux-aarch64.zip" "$CASE/log" && grep -q "ok (aws-cli/2.1.0)" "$CASE/out"; } && ok "linux install runs sudo installer and prints the version" || bad "linux install runs sudo installer" "rc=$rc $(cat "$CASE/log" "$CASE/out" "$CASE/err")"
[ -z "$(ls -A "$CASE/tmp")" ] && ok "temp folder is removed after success" || bad "temp folder is removed after success" "$(ls "$CASE/tmp")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
