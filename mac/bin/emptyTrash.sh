#!/bin/sh
# Empty the Trash on this Mac and on every mounted volume.
# Usage: emptyTrash.sh [dir]   With dir, also remove .AppleDouble folders under it. Without it, nothing else is touched.
# EMPTYTRASH_VOLUMES and EMPTYTRASH_SUDO exist so the test can run without sudo.
SUDO=${EMPTYTRASH_SUDO-sudo}
VOLUMES=${EMPTYTRASH_VOLUMES:-/Volumes}
[ -z "$SUDO" ] || sudo -v
# find, not a glob: a plain * skips hidden names such as .DS_Store.
$SUDO find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
for trash in "$VOLUMES"/*/.Trashes; do
  [ -d "$trash" ] || continue
  $SUDO find "$trash" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
done

if [ -n "$1" ]; then
  find "$1" -name .AppleDouble -exec rm -rf {} +
fi

# in linux
#find . -name ".AppleDouble" -delete
#find . \( -name '.AppleDouble' -or -name '._*' \) -delete -print
