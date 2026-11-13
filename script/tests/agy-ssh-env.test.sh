#!/usr/bin/env bash
# agy started from a login shell or from an Orca that a script reopened never sees the SSH variables (#911).
root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/asdf-pin.sh
. "$root/script/tests/lib/asdf-pin.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

# A home whose .zprofile puts the real agy first, as the Antigravity installer does.
home="$tmp/home"
mkdir -p "$home/.local/bin" "$home/dotfiles/bin"
cp "$root/bin/agy" "$home/dotfiles/bin/agy"
printf '#!/bin/sh\necho "conn=${SSH_CONNECTION-unset}"\n' > "$home/.local/bin/agy"
chmod +x "$home/.local/bin/agy"
# shellcheck disable=SC2016
echo 'export PATH="$HOME/.local/bin:$PATH"' > "$home/.zprofile"
ln -s "$root/.zlogin" "$home/.zlogin"
if command -v zsh >/dev/null 2>&1; then
  out=$(cd "$tmp" && env -i HOME="$home" PATH=/usr/bin:/bin SSH_CONNECTION='a b c d' zsh -l -c agy 2>&1)
  check "a login shell runs agy through the wrapper" "$([ "$out" = conn=unset ]; echo $?)"
  [ "$out" = conn=unset ] || echo "  got: $out"
else
  echo "skip login shell check: no zsh"
fi

# shellcheck disable=SC2016
check "install.sh links .zlogin" "$(grep -qF '"$DOTFILES_ROOT/.zlogin" "$HOME/.zlogin"' "$root/install.sh"; echo $?)"
check "switch-login-shell-zsh.sh links .zlogin" "$(grep -qE '^for f in .*\.zlogin' "$root/script/switch-login-shell-zsh.sh"; echo $?)"

# open hands the caller's environment to the app, so every scripted Orca reopen drops the SSH variables.
opens=$(cd "$root" && git grep -nE "open -g .*orca_app" -- 'script/*.sh' 'mac/*.sh' 'mac/bin/*.sh' ':!script/tests')
bad=$(printf '%s\n' "$opens" | grep -v 'env -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT open -g')
check "scripted Orca reopens are found" "$([ -n "$opens" ]; echo $?)"
check "scripted Orca reopens drop the SSH variables" "$([ -z "$bad" ]; echo $?)"
[ -z "$bad" ] || echo "$bad"

echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
