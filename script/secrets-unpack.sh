#!/usr/bin/env bash
# Unlock an encrypted image made by secrets-pack.sh and copy its files to a directory.
# The passphrase is typed at a hidden prompt (or read from stdin when it is not a terminal).
# It is never an argument, never in the environment and never logged.
#
# Usage: secrets-unpack.sh <image.dmg> <target-dir>
set -euo pipefail

img=${1:-}
dest=${2:-}
if [ -z "$img" ] || [ -z "$dest" ]; then
  echo "usage: secrets-unpack.sh <image.dmg> <target-dir>" >&2
  exit 2
fi
[ -f "$img" ] || { echo "no such image: $img" >&2; exit 1; }

if [ -t 0 ]; then
  read -rsp "Passphrase: " pass; echo >&2
else
  IFS= read -r pass
fi

mp=$(mktemp -d)
attached=0
cleanup() {
  if [ "$attached" = 1 ]; then hdiutil detach -quiet "$mp" || true; fi
  rmdir "$mp" 2>/dev/null || true
}
trap cleanup EXIT

if ! printf '%s' "$pass" | hdiutil attach -quiet -stdinpass -nobrowse -readonly -mountpoint "$mp" "$img" >/dev/null 2>&1; then
  echo "could not open the image (wrong passphrase?)" >&2
  exit 1
fi
unset pass
attached=1

umask 077
mkdir -p "$dest"
rsync -a --exclude '.fseventsd' --exclude '.Spotlight-V100' --exclude '.Trashes' "$mp/" "$dest/"
chmod 700 "$dest"
echo "unpacked to $dest"
