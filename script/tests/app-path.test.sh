#!/usr/bin/env bash
# app_path: prefers the first folder, falls back to the second, and names the first when the app is in neither.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
new="$tmp/Applications"; old="$tmp/Applications/old"
mkdir -p "$new" "$old"
ap() { APP_PATH_DIRS="$new $old" bash -c '. "$1"; app_path "$2"' _ "$here/lib/app-path.sh" "$1"; }

mkdir "$new/OnlyNew.app" "$old/OnlyOld.app" "$new/Both.app" "$old/Both.app"
check "only in the main folder" "$([ "$(ap OnlyNew.app)" = "$new/OnlyNew.app" ] && echo 0 || echo 1)"
check "only in the old folder" "$([ "$(ap OnlyOld.app)" = "$old/OnlyOld.app" ] && echo 0 || echo 1)"
check "in both picks the main folder" "$([ "$(ap Both.app)" = "$new/Both.app" ] && echo 0 || echo 1)"
check "in neither names the main folder and exits 0" "$([ "$(ap Gone.app)" = "$new/Gone.app" ] && echo 0 || echo 1)"
check "a name with a space" "$(mkdir "$new/Visual Studio Code.app"; [ "$(ap 'Visual Studio Code.app')" = "$new/Visual Studio Code.app" ] && echo 0 || echo 1)"
def=$(bash -c '. "$1"; app_path Nope.app' _ "$here/lib/app-path.sh")
check "default folder is /Applications" "$([ "$def" = /Applications/Nope.app ] && echo 0 || echo 1)"

echo "app-path: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
