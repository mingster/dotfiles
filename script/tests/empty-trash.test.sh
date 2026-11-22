#!/usr/bin/env bash
# mac/bin/emptyTrash.sh must touch only the Trash paths, and run find only on a path argument (#1454).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/mac/bin/emptyTrash.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/home/.Trash" "$tmp/vols/disk1/.Trashes" "$tmp/vols/disk2/.Trashes" "$tmp/vols/nodisk" "$tmp/work/proj/.AppleDouble" "$tmp/target/.AppleDouble"
touch "$tmp/home/.Trash/a" "$tmp/vols/disk1/.Trashes/b" "$tmp/vols/disk2/.Trashes/c" "$tmp/vols/nodisk/keep" "$tmp/work/proj/.AppleDouble/x" "$tmp/target/.AppleDouble/y"
# Run without sudo so the test needs no password and cannot touch the real Trash.
run() { (cd "$tmp/work" && HOME="$tmp/home" EMPTYTRASH_VOLUMES="$tmp/vols" EMPTYTRASH_SUDO= sh "$SCRIPT" "$@") >/dev/null; }

run
[ -z "$(ls -A "$tmp/home/.Trash")" ] || fail "home Trash not emptied"
[ -z "$(ls -A "$tmp/vols/disk1/.Trashes")" ] || fail "disk1 .Trashes not emptied"
[ -z "$(ls -A "$tmp/vols/disk2/.Trashes")" ] || fail "disk2 .Trashes not emptied (volumes must be looped)"
[ -e "$tmp/vols/nodisk/keep" ] || fail "non Trash file on a volume removed"
[ -d "$tmp/work/proj/.AppleDouble" ] || fail "default run deleted .AppleDouble under the current directory"
[ -d "$tmp/target/.AppleDouble" ] || fail "default run touched the target tree"

run "$tmp/target"
[ ! -e "$tmp/target/.AppleDouble" ] || fail "path argument did not remove .AppleDouble"
[ -d "$tmp/work/proj/.AppleDouble" ] || fail "path argument removed .AppleDouble outside the argument"
echo "PASS empty-trash"
