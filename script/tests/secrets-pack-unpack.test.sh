#!/usr/bin/env bash
# secrets-pack.sh and secrets-unpack.sh: round trip, wrong passphrase, existing image, empty passphrase,
# and an unpack target that already holds files (#1473).
here=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "SKIP secrets-pack-unpack: hdiutil is missing (macOS only)"
  exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
rc() { "$@" >/dev/null 2>&1 </dev/null; echo $?; }

src="$tmp/src"; mkdir -p "$src/sub"
echo "token-1" > "$src/a.txt"; echo "token-2" > "$src/sub/b.txt"
img="$tmp/s.dmg"

printf 'pw-ok\n' | bash "$here/secrets-pack.sh" "$src" "$img" >/dev/null 2>&1
check "pack writes the image" "$([ -f "$img" ] && echo 0 || echo 1)"

out="$tmp/out"
printf 'pw-ok\n' | bash "$here/secrets-unpack.sh" "$img" "$out" >/dev/null 2>&1
check "unpack with the right passphrase exits 0" "$([ -f "$out/a.txt" ] && echo 0 || echo 1)"
check "files match" "$(diff -r "$src" "$out" >/dev/null 2>&1 && echo 0 || echo 1)"
check "created target is 700" "$([ "$(stat -f %Lp "$out")" = 700 ] && echo 0 || echo 1)"

out2="$tmp/out2"
printf 'wrong\n' | bash "$here/secrets-unpack.sh" "$img" "$out2" >/dev/null 2>&1
check "wrong passphrase exits 1" "$([ $? = 1 ] && echo 0 || echo 1)"
check "wrong passphrase leaves no target" "$([ ! -e "$out2" ] && echo 0 || echo 1)"

before=$(shasum "$img" | cut -d' ' -f1)
printf 'other\n' | bash "$here/secrets-pack.sh" "$src" "$img" >/dev/null 2>&1
check "existing image is refused (exit 1)" "$([ $? = 1 ] && echo 0 || echo 1)"
check "existing image is unchanged" "$([ "$(shasum "$img" | cut -d' ' -f1)" = "$before" ] && echo 0 || echo 1)"

printf '\n' | bash "$here/secrets-pack.sh" "$src" "$tmp/empty.dmg" >/dev/null 2>&1
check "empty passphrase exits 1" "$([ $? = 1 ] && echo 0 || echo 1)"
check "empty passphrase writes no image" "$([ ! -e "$tmp/empty.dmg" ] && echo 0 || echo 1)"

# A target that already holds files is refused and left untouched.
full="$tmp/full"; mkdir -p "$full"; echo keep > "$full/a.txt"; chmod 755 "$full"
printf 'pw-ok\n' | bash "$here/secrets-unpack.sh" "$img" "$full" >/dev/null 2>&1
check "non empty target exits 1" "$([ $? = 1 ] && echo 0 || echo 1)"
check "non empty target file is not overwritten" "$([ "$(cat "$full/a.txt")" = keep ] && echo 0 || echo 1)"
check "non empty target mode is not changed" "$([ "$(stat -f %Lp "$full")" = 755 ] && echo 0 || echo 1)"

# An existing empty folder is allowed, and its mode is left alone.
empty="$tmp/emptydir"; mkdir -p "$empty"; chmod 755 "$empty"
printf 'pw-ok\n' | bash "$here/secrets-unpack.sh" "$img" "$empty" >/dev/null 2>&1
check "empty existing target is filled" "$([ -f "$empty/a.txt" ] && echo 0 || echo 1)"
check "empty existing target mode is not changed" "$([ "$(stat -f %Lp "$empty")" = 755 ] && echo 0 || echo 1)"

# The image root's own mode must not leak onto an existing empty folder, either way.
tight="$tmp/tight"; mkdir -p "$tight"; chmod 700 "$tight"
printf 'pw-ok\n' | bash "$here/secrets-unpack.sh" "$img" "$tight" >/dev/null 2>&1
check "existing 700 target stays 700 (image root is 755)" "$([ "$(stat -f %Lp "$tight")" = 700 ] && echo 0 || echo 1)"
src7="$tmp/src7"; mkdir -p "$src7"; chmod 700 "$src7"; echo t > "$src7/c.txt"
printf 'pw-ok\n' | bash "$here/secrets-pack.sh" "$src7" "$tmp/s7.dmg" >/dev/null 2>&1
open="$tmp/open"; mkdir -p "$open"; chmod 755 "$open"
printf 'pw-ok\n' | bash "$here/secrets-unpack.sh" "$tmp/s7.dmg" "$open" >/dev/null 2>&1
check "existing 755 target stays 755 (image root is 700)" "$([ "$(stat -f %Lp "$open")" = 755 ] && echo 0 || echo 1)"

check "missing image exits 1" "$([ "$(printf 'x\n' | bash "$here/secrets-unpack.sh" "$tmp/none.dmg" "$tmp/o3" >/dev/null 2>&1; echo $?)" = 1 ] && echo 0 || echo 1)"

echo "secrets-pack-unpack: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
