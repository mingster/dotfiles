#!/usr/bin/env bash
# switch-login-shell-zsh.sh makes zsh the login shell on an already set up host.
# Links the zsh files, runs chsh when $SHELL is not zsh, then prints where python3, node and bash resolve.
# Usage: switch-login-shell-zsh.sh [--dotfiles DIR]
set -euo pipefail

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--dotfiles" ]; then
  DOTFILES_ROOT="$2"
fi
SHELLS_FILE="${SHELLS_FILE:-/etc/shells}"

zsh_path="$(command -v zsh || true)"
if [ -z "$zsh_path" ]; then
  echo "switch-login-shell-zsh: zsh not found; install it first" >&2
  exit 1
fi

for f in .zshenv .zshrc .p10k.zsh; do
  ln -sfn "$DOTFILES_ROOT/$f" "$HOME/$f"
done

if ! grep -qxF "$zsh_path" "$SHELLS_FILE" 2>/dev/null; then
  echo "$zsh_path" | sudo tee -a "$SHELLS_FILE" >/dev/null
fi

case "${SHELL:-}" in
  */zsh) echo "login shell is already zsh" ;;
  *)
    echo "change login shell to $zsh_path"
    chsh -s "$zsh_path"
    ;;
esac

zsh -lic 'command -v python3 node bash'
