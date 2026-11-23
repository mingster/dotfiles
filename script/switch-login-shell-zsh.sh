#!/usr/bin/env bash
# switch-login-shell-zsh.sh makes zsh the login shell on an already set up host.
# Links the zsh files, runs chsh when $SHELL is not zsh, then prints where python3, node and bash resolve.
# Usage: switch-login-shell-zsh.sh [--dotfiles DIR]
set -euo pipefail

usage() { echo "Usage: switch-login-shell-zsh.sh [--dotfiles DIR]"; }
DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  --dotfiles)
    if [ $# -lt 2 ] || [ -z "$2" ]; then echo "switch-login-shell-zsh: --dotfiles needs a directory" >&2; exit 2; fi
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    DOTFILES_ROOT="$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
# shellcheck source=script/lib/dotfiles-source.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
SHELLS_FILE="${SHELLS_FILE:-/etc/shells}"

require_main_dotfiles switch-login-shell-zsh "$DOTFILES_ROOT"

zsh_path="$(command -v zsh || true)"
if [ -z "$zsh_path" ]; then
  echo "switch-login-shell-zsh: zsh not found; install it first" >&2
  exit 1
fi

for f in .zshenv .zshrc .zlogin; do
  ln -sfn "$DOTFILES_ROOT/$f" "$HOME/$f"
done
rm -f "$HOME/.p10k.zsh"

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
