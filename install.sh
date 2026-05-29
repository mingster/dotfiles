#!/usr/bin/env bash
# Idempotent: safe to re-run. Always points ~/dotfiles at this repo and refreshes home symlinks,
# then delegates to the platform system_setup.sh. Individual installs inside system_setup are
# guarded so already-installed software is skipped.
# Use pwd -P so DOTFILES_ROOT is the real filesystem path (avoids symlink loops when ~/dotfiles
# or the repo path repeats the same link chain).
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

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
  if [ -f "$DOTFILES_ROOT/.gitconfig-x64" ]; then
    cp -f "$DOTFILES_ROOT/.gitconfig-x64" "$HOME/.gitconfig"
  else
    cp -f "$DOTFILES_ROOT/.gitconfig" "$HOME/.gitconfig"
  fi

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

# Common directories
mkdir -p "$HOME/.config/micro" "$HOME/.config/fish"

# Agents: ~/.agents -> dotfiles/.agents (skills CLI + Claude Code + Cursor share this tree)
mkdir -p "$DOTFILES_ROOT/.agents"
ln -sfn "$DOTFILES_ROOT/.agents" "$HOME/.agents"

# AI tooling: each script handles OS-specific install paths internally
bash "$DOTFILES_ROOT/script/setup-claude-code.sh"
bash "$DOTFILES_ROOT/script/setup-claude-desktop.sh"
bash "$DOTFILES_ROOT/script/setup-cursor.sh"
bash "$DOTFILES_ROOT/script/setup-obsidian.sh"
bash "$DOTFILES_ROOT/script/setup-vscode.sh"
bash "$DOTFILES_ROOT/script/setup-antigravity.sh"

if [ "${DOTFILES_INSTALL_SKILLS:-}" = "1" ]; then
  bash "$DOTFILES_ROOT/script/bootstrap-agents.sh"
fi

# Platform-specific full system setup (Homebrew stack, distro packages, etc.).
# Each install inside system_setup.sh is guarded; already-installed items are skipped.
# Set DOTFILES_SKIP_SYSTEM_SETUP=1 to skip entirely (CI, unsupported distro, etc.).

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
