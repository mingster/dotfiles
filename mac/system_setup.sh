#!/usr/bin/env bash

# If run with sh, re-exec under bash so bash-specific features work
if [ -z "$BASH_VERSION" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "This script requires bash. Please run with bash." >&2
    exit 1
  fi
fi

echo ""
echo -e "\033[1;35mSystem Setup for macos\033[0m"
echo ""

# Install command-line tools using Homebrew.
sh $HOME/dotfiles/mac/osxprep.sh

# Check for Homebrew,
# Install if we don't have it
if ! command -v brew >/dev/null 2>&1; then
    echo "Installing homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

architecture=$(uname -m)
if [ "$architecture" == "arm64" ]; then
    #echo "This Mac is using Apple Silicon."
    # Add to path (only apple silicon macbooks); idempotent — do not duplicate lines
    if [ -f "$HOME/.zprofile" ] && grep -q '/opt/homebrew/bin/brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
        :
    else
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ "$architecture" == "x86_64" ]; then
    #echo "This Mac is using Intel."
    if [ -x /usr/local/bin/brew ]; then
        if [ -f "$HOME/.zprofile" ] && grep -q '/usr/local/bin/brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
            :
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$HOME/.zprofile"
        fi
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo "Homebrew not found at /usr/local/bin/brew; add it to PATH and re-run this script."
    fi
else
    echo "Unknown architecture: $architecture"
fi

# Refresh Homebrew metadata; optional full upgrade (slow on reruns)
brew update
if [ "${DOTFILES_BREW_UPGRADE:-}" = "1" ]; then
    brew upgrade
fi

# Symlink ~/dotfiles/mac/scripts into ~/.local/bin (must remove existing dir first:
# if ~/.local/bin is a directory, `ln -s ... ~/.local/bin` creates ~/.local/bin/bin on macOS).
mkdir -p "${HOME}/.local"
rm -rf "${HOME}/.local/bin"
ln -sfn "${HOME}/dotfiles/mac/bin" "${HOME}/.local/bin"
# Make scripts in mac/bin executable only if they exist to avoid chmod errors
if compgen -G "${HOME}/dotfiles/mac/bin/*" >/dev/null 2>&1; then
  for _f in "${HOME}/dotfiles/mac/bin/"*; do
    [ -f "$_f" ] && chmod +x "$_f"
  done
fi

#ln -s $HOME/GitHub/dotfiles $HOME
#ln -s $HOME/dotfiles/bin $HOME/


echo ""
echo -e "\033[1;35m essential apps \033[0m"
echo ""


# Install essential binaries.

## mas — build via brew on arm64; download release pkg on x86_64
if [ "$(uname -m)" = "x86_64" ]; then
  if ! command -v mas >/dev/null 2>&1; then
    MAS_VERSION=$(curl -fsSL https://api.github.com/repos/mas-cli/mas/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    MAS_PKG="mas-${MAS_VERSION}-x86_64.pkg"
    curl -fsSL "https://github.com/mas-cli/mas/releases/download/v${MAS_VERSION}/${MAS_PKG}" -o "/tmp/${MAS_PKG}"
    sudo installer -pkg "/tmp/${MAS_PKG}" -target /
    rm -f "/tmp/${MAS_PKG}"
  fi
else
  brew list mas >/dev/null 2>&1 || brew install mas
fi

#brew install iftop iperf nmap tcpflow tcptrace tcpreplay nano svn nmap  fastfetch kdiff3 jq trash bat rar asdf nmap
for pkg in coreutils curl git rsync wget unzip; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

## gh — download release pkg on x86_64; brew on arm64
if [ "$(uname -m)" = "x86_64" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    GH_PKG="gh_${GH_VERSION}_macOS_amd64.pkg"
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${GH_PKG}" -o "/tmp/${GH_PKG}"
    sudo installer -pkg "/tmp/${GH_PKG}" -target /
    rm -f "/tmp/${GH_PKG}"
  fi
else
  brew list gh >/dev/null 2>&1 || brew install gh
fi


# set up cli access for github (skip if already authenticated)
gh auth status >/dev/null 2>&1 || gh auth login

echo ""
echo -e "\033[1;35m Fonts \033[0m"
echo ""

# Nerd fonts - only Hack
brew list --cask font-hack-nerd-font >/dev/null 2>&1 || brew install --cask font-hack-nerd-font

echo ""
echo -e "\033[1;35m kitty \033[0m"
echo ""

brew list --cask kitty >/dev/null 2>&1 || brew install --cask kitty

ln -sfn $HOME/dotfiles/.config/kitty $HOME/.config/kitty

sh $HOME/dotfiles/mac/install_nodejs_dev.sh
sh $HOME/dotfiles/mac/install_java_dev.sh

echo ""
echo -e "\033[1;35m alacritty \033[0m"
echo ""

#brew install --cask alacritty
#if [ ! -d ${HOME}/.config/alacritty ]; then
#    rm -rf ${HOME}/.config/alacritty
#fi
#ln -s $HOME/dotfiles/.config/alacritty $HOME/.config/
#git clone https://github.com/catppuccin/alacritty.git $HOME/dotfiles/.config/alacritty/catppuccin


# neovim — download pre-built tarball on x86_64; brew on arm64
if [ "$(uname -m)" = "x86_64" ]; then
  if ! command -v nvim >/dev/null 2>&1; then
    NVIM_VERSION=$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-macos-x86_64.tar.gz" -o /tmp/nvim.tar.gz
    tar -xzf /tmp/nvim.tar.gz -C /tmp
    cp /tmp/nvim-macos-x86_64/bin/nvim /usr/local/bin/nvim
    rm -rf /tmp/nvim.tar.gz /tmp/nvim-macos-x86_64
  fi
else
  brew list nvim >/dev/null 2>&1 || brew install nvim
fi
ln -sfn $HOME/dotfiles/.config/nvim $HOME/.config/nvim

# optional but recommended
if [ ! -d ${HOME}/.local/share/nvim ]; then
    mkdir -p ${HOME}/.local/share/nvim
fi

if [ ! -d ${HOME}/.local/state/nvim ]; then
    mkdir -p ${HOME}/.local/state/nvim
fi

if [ ! -d ${HOME}/.cache/nvim ]; then
    mkdir -p ${HOME}/.cache/nvim
fi

brew list tmux >/dev/null 2>&1 || brew install tmux  # https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/

## lf, fzf, lazygit — download pre-built binaries on x86_64; brew on arm64
if [ "$(uname -m)" = "x86_64" ]; then
  if ! command -v lf >/dev/null 2>&1; then
    LF_VERSION=$(curl -fsSL https://api.github.com/repos/gokcehan/lf/releases/latest | grep '"tag_name"' | sed 's/.*"r\([^"]*\)".*/\1/')
    curl -fsSL "https://github.com/gokcehan/lf/releases/download/r${LF_VERSION}/lf-darwin-amd64.tar.gz" -o /tmp/lf.tar.gz
    tar -xzf /tmp/lf.tar.gz -C /usr/local/bin lf
    rm -f /tmp/lf.tar.gz
  fi
  if ! command -v fzf >/dev/null 2>&1; then
    FZF_VERSION=$(curl -fsSL https://api.github.com/repos/junegunn/fzf/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-darwin_amd64.tar.gz" -o /tmp/fzf.tar.gz
    tar -xzf /tmp/fzf.tar.gz -C /usr/local/bin fzf
    rm -f /tmp/fzf.tar.gz
  fi
  if ! command -v lazygit >/dev/null 2>&1; then
    LG_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LG_VERSION}/lazygit_${LG_VERSION}_Darwin_x86_64.tar.gz" -o /tmp/lazygit.tar.gz
    tar -xzf /tmp/lazygit.tar.gz -C /usr/local/bin lazygit
    rm -f /tmp/lazygit.tar.gz
  fi
else
  brew list lf      >/dev/null 2>&1 || brew install lf       # https://www.joshmedeski.com/posts/manage-files-with-lf/
  brew list fzf     >/dev/null 2>&1 || brew install fzf
  brew list lazygit >/dev/null 2>&1 || brew install lazygit
fi
#brew list commitizen >/dev/null 2>&1 || brew install commitizen

mkdir -p "$HOME/Library/Application Support/lazygit"
ln -sfn "$HOME/dotfiles/.config/lazygit/config.yml" "$HOME/Library/Application Support/lazygit/config.yml"
ln -sfn $HOME/dotfiles/.config/tmux $HOME/.config/tmux
ln -sfn $HOME/dotfiles/.config/lf $HOME/.config/lf
ln -sfn $HOME/dotfiles/.config/lazygit $HOME/.config/lazygit

# nano
#brew install nano
if [ ! -d ${HOME}/GitHub ]; then
    mkdir -p ${HOME}/GitHub
fi

[ -d "$HOME/GitHub/nanorc" ] || git clone https://github.com/scopatz/nanorc.git "$HOME/GitHub/nanorc"
#cp ~/GitHub/nanorc/*.nanorc /usr/share/nano/

# Install Yabai
#brew install koekeishiya/formulae/yabai
# Install Skhd
#brew install koekeishiya/formulae/skhd
#ln -s $HOME/dotfiles/.config/yabai $HOME/.config/
#ln -s $HOME/dotfiles/.config/sxhkd/skhdrc.mac $HOME/.skhdrc

# install sketchybar
#brew install FelixKratz/formulae/sketchybar
#ln -s $HOME/dotfiles/.config/sketchybar $HOME/.config/
#chmod +x $HOME/.config/sketchybar/*.sh
#chmod +x $HOME/.config/sketchybar/plugins/*.sh
#chmod +x $HOME/.config/sketchybar/items/*.sh
#curl -L https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.18/sketchybar-app-font.ttf \
#    -o $HOME/Library/Fonts/sketchybar-app-font.ttf

#curl -L https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.18/icon_map_fn.sh \
#    -o $HOME/dotfiles/.config/sketchybar/plugins/icon_map_fn.sh

#brew install font-sf-pro
#brew install --cask sf-symbols

# another tile window manager as backup
#brew install --cask amethyst # Install Amethyst - https://ianyh.com/amethyst/
#ln -s $HOME/dotfiles/.config/amethyst $HOME/.config/

echo ""
echo -e "\033[1;35m fish shell \033[0m"
echo ""

# On Intel Macs, download and install the official pkg release; on Apple Silicon use Homebrew
if [ "$(uname -m)" = "x86_64" ]; then
  if ! command -v fish >/dev/null 2>&1; then
    FISH_VERSION="4.7.1"
    FISH_PKG="fish-${FISH_VERSION}.pkg"
    curl -fsSL "https://github.com/fish-shell/fish-shell/releases/download/${FISH_VERSION}/${FISH_PKG}" -o "/tmp/${FISH_PKG}"
    sudo installer -pkg "/tmp/${FISH_PKG}" -target /
    rm -f "/tmp/${FISH_PKG}"
  fi
else
  brew list fish >/dev/null 2>&1 || brew install fish
fi

ln -sfn $HOME/dotfiles/.config/fish/config.fish $HOME/.config/fish/config.fish

# add fish to system shells list (idempotent)
if ! grep -qF "$(which fish)" /etc/shells; then
    echo "$(which fish)" | sudo tee -a /etc/shells
fi

# change default shell to fish (skip if already set)
if [ "$SHELL" != "$(which fish)" ]; then
    echo ' change default shell to fish'
    chsh -s "$(which fish)"
fi

# install fisher and fish plugins
if command -v fish >/dev/null 2>&1; then
  fish "$HOME/dotfiles/script/setup_fishshell.fish"
else
  echo "system_setup: fish not found; skipping setup_fishshell.fish" >&2
fi

# Remove outdated versions from the cellar.
brew cleanup && brew doctor


echo ""
echo -e "\033[1;35m cron service script \033[0m"
echo ""

CRON_PLIST_SRC="$HOME/bin2/com.mingster.crontab.plist"
CRON_PLIST_DST="$HOME/Library/LaunchAgents/com.mingster.crontab.plist"
CRON_LABEL="com.mingster.crontab"

cron_warn() {
    echo -e "\033[1;33mWarning:\033[0m $*" >&2
}

shopt -s nullglob
bin2_scripts=("$HOME/bin2"/*.sh)
shopt -u nullglob
if ((${#bin2_scripts[@]} > 0)); then
    chmod 755 "${bin2_scripts[@]}" || cron_warn "could not chmod scripts in $HOME/bin2/"
else
    cron_warn "no *.sh in $HOME/bin2/; skipping chmod."
fi

if [[ -f "$CRON_PLIST_SRC" ]]; then
    # Unload existing job before replacing the plist
    launchctl bootout "gui/$(id -u)/$CRON_LABEL" 2>/dev/null || true

    # Ensure destination directory exists so cp doesn't fail
    if ! mkdir -p "$(dirname "$CRON_PLIST_DST")" 2>/dev/null; then
        cron_warn "could not create directory $(dirname "$CRON_PLIST_DST")"
    fi

    if cp "$CRON_PLIST_SRC" "$CRON_PLIST_DST"; then
        chmod 644 "$CRON_PLIST_DST"

        if ! launchctl bootstrap "gui/$(id -u)" "$CRON_PLIST_DST" 2>/dev/null; then
            cron_warn "launchctl bootstrap failed"
        else
            launchctl kickstart "gui/$(id -u)/$CRON_LABEL" || cron_warn "launchctl kickstart failed"
        fi
    else
        cron_warn "could not copy plist to $CRON_PLIST_DST"
    fi
else
    cron_warn "$CRON_PLIST_SRC not found; skipping LaunchAgent install."
fi

if [ -f "$HOME/dotfiles/mac/install_my_software.sh" ]; then
  bash "$HOME/dotfiles/mac/install_my_software.sh"
fi
