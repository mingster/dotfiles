#!/usr/bin/env bash
# Idempotent: safe to re-run. Always points ~/dotfiles at this repo and refreshes home symlinks.
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -e "$HOME/dotfiles" ] && [ ! -L "$HOME/dotfiles" ]; then
  echo "install: error: $HOME/dotfiles exists and is not a symlink. Remove or rename it, then re-run." >&2
  exit 1
fi

ln -sfn "$DOTFILES_ROOT" "$HOME/dotfiles"
echo "install: $HOME/dotfiles -> $DOTFILES_ROOT"

echo 'create / refresh symlinks...'

ln -sfn "$DOTFILES_ROOT/.csvignore" "$HOME/.csvignore"
ln -sfn "$DOTFILES_ROOT/.editorconfig" "$HOME/.editorconfig"
ln -sfn "$DOTFILES_ROOT/.gitattributes" "$HOME/.gitattributes"

architecture=$(uname -m)
if [ "$architecture" == "arm64" ]; then
  cp -f "$DOTFILES_ROOT/.gitconfig" "$HOME/.gitconfig"

elif [ "$architecture" == "x86_64" ]; then
  cp -f "$DOTFILES_ROOT/.gitconfig-x64" "$HOME/.gitconfig"

else
    echo "Unknown architecture: $architecture"
fi

ln -sfn "$DOTFILES_ROOT/.gitflow_export" "$HOME/.gitflow_export"
ln -sfn "$DOTFILES_ROOT/.gitignore" "$HOME/.gitignore"
ln -sfn "$DOTFILES_ROOT/.gitignore_global" "$HOME/.gitignore_global"
ln -sfn "$DOTFILES_ROOT/.hgignore_global" "$HOME/.hgignore_global"
ln -sfn "$DOTFILES_ROOT/.nanorc" "$HOME/.nanorc"
ln -sfn "$DOTFILES_ROOT/.vimrc" "$HOME/.vimrc"
ln -sfn "$DOTFILES_ROOT/.vim" "$HOME/.vim"

git config --global core.excludesfile "$DOTFILES_ROOT/.gitignore_global"
git config --global core.attributesfile "$DOTFILES_ROOT/.gitattributes"

# Agent skills: ~/.agents → ~/dotfiles/.agents (idempotent; ok on reruns)
if [ -d "$HOME/dotfiles" ]; then
  mkdir -p "$HOME/dotfiles/.agents"
  ln -sfn "$HOME/dotfiles/.agents" "$HOME/.agents"

  # Claude Code: ~/.claude/* → ~/dotfiles/.agents (skills + .agents/claude; see script/setup-claude-code.sh)
  bash "$HOME/dotfiles/script/setup-claude-code.sh"

  # Cursor global rules: ~/.cursor/rules → ~/dotfiles/cursor/rules
  mkdir -p "$HOME/dotfiles/cursor/rules"
  mkdir -p "$HOME/.cursor"
  ln -sfn "$HOME/dotfiles/cursor/rules" "$HOME/.cursor/rules"

  # Optional: restore skills from .skill-lock.json (needs Node/npx)
  if [ "${DOTFILES_INSTALL_SKILLS:-}" = "1" ]; then
    bash "$HOME/dotfiles/script/bootstrap-agents.sh"
  fi

  # Cursor app User folder: settings + keybindings -> dotfiles/cursor (riben.life standard)
  bash "$HOME/dotfiles/script/link-cursor-user.sh"
fi

# Platform-specific full system setup (Homebrew stack, distro packages, etc.)

if [ "${DOTFILES_SKIP_SYSTEM_SETUP:-}" = "1" ]; then
  echo "dotfiles: DOTFILES_SKIP_SYSTEM_SETUP=1 — skipping system_setup scripts."
  exit 0
fi

case "$OSTYPE" in
  darwin*)
    echo "dotfiles: macOS — running mac/system_setup.sh"
    bash "$DOTFILES_ROOT/mac/system_setup.sh"
    ;;
  linux-gnu* | linux-musl*)
    if [ ! -r /etc/os-release ]; then
      echo "dotfiles: Linux but /etc/os-release not readable; skipping system_setup." >&2
      exit 0
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      arch)
        echo "dotfiles: Arch Linux — running arch/system_setup.sh"
        bash "$DOTFILES_ROOT/arch/system_setup.sh"
        ;;
      debian | ubuntu | linuxmint | pop | zorin)
        echo "dotfiles: ${ID} — running debian/system_setup.sh"
        bash "$DOTFILES_ROOT/debian/system_setup.sh"
        ;;
      *)
        if echo "${ID_LIKE:-}" | grep -q 'arch'; then
          echo "dotfiles: Arch-like ($ID) — running arch/system_setup.sh"
          bash "$DOTFILES_ROOT/arch/system_setup.sh"
        elif echo "${ID_LIKE:-}" | grep -q 'debian'; then
          echo "dotfiles: Debian-like ($ID) — running debian/system_setup.sh"
          bash "$DOTFILES_ROOT/debian/system_setup.sh"
        else
          echo "dotfiles: unsupported Linux distro ID=${ID:-unknown} ID_LIKE=${ID_LIKE:-none}" >&2
          echo "dotfiles: symlinks above are installed; add ID mapping in install.sh if needed." >&2
        fi
        ;;
    esac
    ;;
  msys* | cygwin*)
    echo "dotfiles: Windows ($OSTYPE) — no system_setup; symlinks above may not apply."
    ;;
  *)
    echo "dotfiles: unknown OSTYPE=$OSTYPE — no system_setup."
    ;;
esac
