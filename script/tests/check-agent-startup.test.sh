#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
path_no_asdf=$(printf '%s\n' "${PATH//:/$'\n'}" | grep -v '/\.asdf/shims$' | paste -sd: -)
python_bin=$(PATH="$path_no_asdf" type -P python3)
[ -x "$python_bin" ] || { echo "missing python3" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DOTFILES="$root"
mkdir -p "$HOME/.gemini/config/rules" "$tmp/bin"
export PATH="$tmp/bin:$(dirname "$python_bin"):/usr/bin:/bin"

if bash "$root/script/check-agent-startup.sh" >"$tmp/out" 2>&1; then
  echo 'FAIL: missing links accepted' >&2
  exit 1
fi
grep -q 'MISSING agy global rule orca-agy.md' "$tmp/out"
echo 'PASS: missing orca-agy.md link is named'

printf 'plain rule\n' >"$HOME/.gemini/config/rules/orca-agy.md"
if bash "$root/script/check-agent-startup.sh" >"$tmp/out" 2>&1; then
  echo 'FAIL: plain file accepted for orca-agy.md' >&2
  exit 1
fi
grep -q 'WRONG agy global rule orca-agy.md' "$tmp/out"
echo 'PASS: plain orca-agy.md is rejected'

touch "$tmp/wrong.md"
ln -sfn "$tmp/wrong.md" "$HOME/.gemini/config/rules/orca-agy.md"
if bash "$root/script/check-agent-startup.sh" >"$tmp/out" 2>&1; then
  echo 'FAIL: wrong target accepted for orca-agy.md' >&2
  exit 1
fi
grep -q 'WRONG agy global rule orca-agy.md' "$tmp/out"
echo 'PASS: wrong orca-agy.md target is named'

export OSTYPE=linux-gnu
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/agy"
chmod +x "$tmp/bin/agy"
export PATH="$tmp/bin:$PATH"
bash "$root/script/setup-antigravity.sh" >"$tmp/setup-out"
bash "$root/script/check-agent-startup.sh"
echo 'PASS: setup-antigravity links pass the checker'

bash "$root/script/setup-antigravity.sh" >>"$tmp/setup-out"
bash "$root/script/check-agent-startup.sh"
echo 'PASS: second setup-antigravity run stays valid'

echo 'PASS: 6 tests'
