#!/usr/bin/env bash
# setup-vscode.sh links per OS and skips cleanly; install_vscode_extensions.sh installs each active entry once.
# shellcheck source=script/tests/lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
bashbin=$(command -v bash)

mkbin() {
  local d=$1; shift
  mkdir -p "$d"
  for t in mkdir ln dirname date mv id; do ln -s "$(command -v $t)" "$d/$t"; done
  for t in "$@"; do printf '#!/bin/sh\necho "$0 $*" >> "$STUB_LOG"\n' > "$d/$t"; chmod +x "$d/$t"; done
}

dot="$tmp/dotfiles"; mkdir -p "$dot/ide/vscode"
mkdir -p "$dot/script/lib"; cp "$repo/script/lib/link-user-file.sh" "$repo/script/lib/dotfiles-source.sh" "$dot/script/lib/"
echo '{}' > "$dot/ide/vscode/settings.json"; echo '[]' > "$dot/ide/vscode/keybindings.json"

run() {
  local ostype=$1 bin=$2 home=$3
  mkdir -p "$home"
  env -u XDG_CONFIG_HOME OSTYPE=$ostype HOME="$home" DOTFILES="$dot" PATH="$bin" STUB_LOG="$tmp/log" \
    "$bashbin" "$here/setup-vscode.sh" 2>&1
}
linked() { [ "$(readlink "$1/settings.json")" = "$dot/ide/vscode/settings.json" ] && [ "$(readlink "$1/keybindings.json")" = "$dot/ide/vscode/keybindings.json" ]; }
has() { case $1 in *"$2"*) echo 0;; *) echo 1;; esac; }

mkbin "$tmp/bin-code" code
mkbin "$tmp/bin-pacman" code pacman
mkbin "$tmp/bin-none"

h="$tmp/h-darwin"
run darwin "$tmp/bin-code" "$h" >/dev/null
check "darwin with code links Library/Application Support/Code/User" "$(linked "$h/Library/Application Support/Code/User" && echo 0 || echo 1)"

# Without code on PATH the result depends on a real VS Code app on this machine, so only check it does not fail.
h="$tmp/h-darwin-none"
run darwin "$tmp/bin-none" "$h" >/dev/null
check "darwin without code exits 0" "$?"

h="$tmp/h-linux"
run linux-gnu "$tmp/bin-code" "$h" >/dev/null
check "linux without pacman links .config/Code/User" "$(linked "$h/.config/Code/User" && echo 0 || echo 1)"

h="$tmp/h-arch"
run linux-gnu "$tmp/bin-pacman" "$h" >/dev/null
check "linux with pacman links .config/Code - OSS/User" "$(linked "$h/.config/Code - OSS/User" && echo 0 || echo 1)"
check "linux with pacman leaves .config/Code alone" "$([ ! -e "$h/.config/Code" ] && echo 0 || echo 1)"

h="$tmp/h-linux-none"
out=$(run linux-gnu "$tmp/bin-none" "$h")
check "linux without code skips with a message" "$(has "$out" "VS Code not installed; skipping")"
check "linux without code links nothing" "$([ ! -e "$h/.config" ] && echo 0 || echo 1)"

h="$tmp/h-win"
out=$(run msys "$tmp/bin-code" "$h")
check "windows names ide/vscode/settings.json" "$(has "$out" "$dot/ide/vscode/settings.json manually")"

h="$tmp/h-unknown"
out=$(run freebsd "$tmp/bin-code" "$h")
check "unknown OSTYPE skips and names it" "$(has "$out" "unknown OSTYPE=freebsd, skipping")"
check "unknown OSTYPE links nothing" "$([ -z "$(ls -A "$h")" ] && echo 0 || echo 1)"

: > "$tmp/log"
PATH="$tmp/bin-code" STUB_LOG="$tmp/log" "$bashbin" "$here/install_vscode_extensions.sh" >/dev/null 2>&1
active=$(awk '/^pkglist=\(/{f=1;next} f&&/^\)/{exit} f&&NF&&$1!~/^#/{n++} END{print n+0}' "$here/install_vscode_extensions.sh")
calls=$(grep -c -- '--install-extension' "$tmp/log")
check "one install call per active entry ($active)" "$([ "$active" -gt 0 ] && [ "$calls" = "$active" ] && echo 0 || echo 1)"
check "an active entry is installed" "$(grep -q -- '--install-extension biomejs.biome$' "$tmp/log" && echo 0 || echo 1)"
check "a commented entry is skipped" "$(grep -q 'anteprimorac' "$tmp/log" && echo 1 || echo 0)"

check "extensions header has no dead master/vscode curl path" "$(grep -q 'master/vscode/install-vscode-extensions' "$here/install_vscode_extensions.sh" && echo 1 || echo 0)"
curlpath=$(grep -o 'main/[^ ]*install_vscode_extensions.sh' "$here/install_vscode_extensions.sh" | head -1 | sed 's#^main/##')
check "extensions header curl names a file that exists" "$([ -n "$curlpath" ] && [ -f "$repo/$curlpath" ] && echo 0 || echo 1)"
check "antigravity Windows message names ide/antigravity" "$(grep -q '{DOTFILES}/ide/antigravity/settings.json' "$here/setup-antigravity.sh" && [ -f "$repo/ide/antigravity/settings.json" ] && echo 0 || echo 1)"

echo "setup-vscode: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
