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
export HOME="$tmp/home"
mkdir -p "$HOME/.gemini/config/rules" "$tmp/bin"
export OSTYPE=linux-gnu
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/agy"
chmod +x "$tmp/bin/agy"
export PATH="$tmp/bin:$(dirname "$python_bin"):/usr/bin:/bin"
export DOTFILES="$root"

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

bash "$root/script/setup-antigravity.sh" >"$tmp/setup-out"
bash "$root/script/check-agent-startup.sh"
echo 'PASS: setup-antigravity links pass the checker'

bash "$root/script/setup-antigravity.sh" >>"$tmp/setup-out"
bash "$root/script/check-agent-startup.sh"
echo 'PASS: second setup-antigravity run stays valid'

# ~/dotfiles symlink to checkout, DOTFILES unset (install.sh layout).
home2=$(mktemp -d)
trap 'rm -rf "$tmp" "$home2"' EXIT
mkdir -p "$home2/.gemini/config/rules" "$home2/bin"
ln -sfn "$root" "$home2/dotfiles"
printf '#!/bin/sh\nexit 0\n' >"$home2/bin/agy"
chmod +x "$home2/bin/agy"
(
  export HOME="$home2" OSTYPE=linux-gnu
  export PATH="$home2/bin:$(dirname "$python_bin"):/usr/bin:/bin"
  unset DOTFILES
  bash "$root/script/setup-antigravity.sh" >/dev/null
  bash "$root/script/check-agent-startup.sh"
)
echo 'PASS: checker accepts symlinks via ~/dotfiles'

# No agy: checker skips agy links.
home3=$(mktemp -d)
trap 'rm -rf "$tmp" "$home2" "$home3"' EXIT
mkdir -p "$home3"
(
  export HOME="$home3" OSTYPE=linux-gnu
  # Python's directory can also contain antigravity-ide. This case has no agent CLI.
  export PATH="/usr/bin:/bin"
  unset DOTFILES
  bash "$root/script/check-agent-startup.sh" >"$tmp/skip-out"
)
grep -q 'check-agent-startup: Antigravity IDE not installed; skipping agy links.' "$tmp/skip-out"
echo 'PASS: no Antigravity skips agy link checks'

# Missing links with agy present still fails.
home4=$(mktemp -d)
trap 'rm -rf "$tmp" "$home2" "$home3" "$home4"' EXIT
mkdir -p "$home4/bin"
ln -sfn "$root" "$home4/dotfiles"
printf '#!/bin/sh\nexit 0\n' >"$home4/bin/agy"
chmod +x "$home4/bin/agy"
if (
  export HOME="$home4" OSTYPE=linux-gnu
  export PATH="$home4/bin:$(dirname "$python_bin"):/usr/bin:/bin"
  unset DOTFILES
  bash "$root/script/check-agent-startup.sh"
) >"$tmp/miss-out" 2>&1; then
  echo 'FAIL: missing links with agy present accepted' >&2
  exit 1
fi
grep -q 'MISSING agy global rule orca-agy.md' "$tmp/miss-out"
echo 'PASS: missing link with agy present is named'

echo 'PASS: 9 tests'
