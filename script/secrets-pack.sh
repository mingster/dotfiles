#!/usr/bin/env bash
# Pack a directory into an AES-256 encrypted disk image for moving secrets between Macs.
# The passphrase is typed at a hidden prompt (or read from stdin when it is not a terminal).
# It is never an argument, never in the environment and never logged.
#
# Usage: secrets-pack.sh <source-dir> <image.dmg>
set -euo pipefail

src=${1:-}
out=${2:-}
if [ -z "$src" ] || [ -z "$out" ]; then
  echo "usage: secrets-pack.sh <source-dir> <image.dmg>" >&2
  exit 2
fi
[ -d "$src" ] || { echo "not a directory: $src" >&2; exit 1; }
case "$out" in *.dmg) ;; *) out="$out.dmg" ;; esac
[ ! -e "$out" ] || { echo "refusing to overwrite $out" >&2; exit 1; }

if [ -t 0 ]; then
  read -rsp "Passphrase: " pass; echo >&2
  read -rsp "Again: " again; echo >&2
  [ "$pass" = "$again" ] || { echo "passphrases differ" >&2; exit 1; }
else
  IFS= read -r pass
fi
[ -n "$pass" ] || { echo "empty passphrase" >&2; exit 1; }

printf '%s' "$pass" | hdiutil create -quiet -stdinpass -encryption AES-256 \
  -volname secrets -fs APFS -srcfolder "$src" "$out"
unset pass again
chmod 600 "$out"
echo "wrote $out"
