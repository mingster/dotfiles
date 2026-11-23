#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# mac/system_setup.sh x86_64 downloads (#1628): every tarball goes into one mktemp folder that an EXIT trap removes,
# also when tar fails, and no fixed /tmp/<name> path is left in the script. The x86_64 blocks are cut out of the
# script and run with stub curl, tar, cp, uname, sudo and installer; mas and gh stubs make those two blocks skip.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
script="$ROOT/mac/system_setup.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

if grep -nE '/tmp/[A-Za-z]' "$script" >"$tmp/fixed"; then bad "fixed /tmp paths remain: $(head -3 "$tmp/fixed")"; else ok; fi

mkdir -p "$tmp/bin" "$tmp/tmpdir" "$tmp/home"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
stub uname 'echo x86_64'
stub curl 'out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
if [ -n "$out" ]; then echo "$out" >> "$STUB_LOG.dl"; echo data > "$out"; else echo "\"tag_name\": \"v1.2.3\""; fi'
stub tar 'echo "tar $*" >> "$STUB_LOG"; exit "${TAR_RC:-0}"'
stub cp 'echo "cp $*" >> "$STUB_LOG"'
stub chmod 'true'
stub sudo 'echo "sudo $*" >> "$STUB_LOG"'
stub mas 'true'
stub gh 'true'

# The setup lines plus every top level x86_64 block (col 0 `if ... x86_64 ... then` to the next col 0 `fi`).
{
  grep -E '^(dl_dir=|trap )' "$script"
  awk '/^if \[ "\$\(uname -m\)" = "x86_64" \]; then/ {on=1} on {print} on && /^fi$/ {on=0}' "$script"
} > "$tmp/blocks.sh"
grep -q 'uname -m' "$tmp/blocks.sh" || bad "no x86_64 blocks extracted"

for rc in 1 0; do
  rm -rf "$tmp/tmpdir" "$tmp/stub.log" "$tmp/stub.log.dl"; mkdir -p "$tmp/tmpdir"
  env -i HOME="$tmp/home" TMPDIR="$tmp/tmpdir" PATH="$tmp/bin:/usr/bin:/bin" STUB_LOG="$tmp/stub.log" TAR_RC="$rc" \
    "$BASH" "$tmp/blocks.sh" >"$tmp/out" 2>&1
  if [ -z "$(ls -A "$tmp/tmpdir")" ]; then ok; else bad "tar rc=$rc left $(ls -A "$tmp/tmpdir")"; fi
  if [ -s "$tmp/stub.log.dl" ] && ! grep -v "^$tmp/tmpdir/" "$tmp/stub.log.dl" >/dev/null; then ok; else bad "tar rc=$rc: a download went outside the temp folder: $(cat "$tmp/stub.log.dl" 2>/dev/null)"; fi
  [ "$(wc -l <"$tmp/stub.log.dl")" -eq 5 ] && ok || bad "tar rc=$rc: expected 5 downloads, got $(wc -l <"$tmp/stub.log.dl")"
done
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
