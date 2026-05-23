#!/usr/bin/env bash

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
chmod +x "${HOME}/dotfiles/mac/bin/"*

#ln -s $HOME/GitHub/dotfiles $HOME
#ln -s $HOME/dotfiles/bin $HOME/


echo ""
echo -e "\033[1;35m essential apps \033[0m"
echo ""


# Install essential binaries.

## mas
brew install mas

#brew install iftop iperf nmap tcpflow tcptrace tcpreplay nano svn
brew install coreutils curl git
brew install gh rsync wget unzip fastfetch kdiff3 jq trash bat rar
brew install asdf

# set up cli access for github (skip if already authenticated)
gh auth status >/dev/null 2>&1 || gh auth login

echo ""
echo -e "\033[1;35m create missing directories and files \033[0m"
echo ""
if [ ! -d ${HOME}/.config ]; then
    mkdir -p ${HOME}/.config
fi

mkdir -p $HOME/.config/{micro,fish}

mkdir -p $HOME/dotfiles/.agents
ln -sfn $HOME/dotfiles/.agents $HOME/.agents

bash "$HOME/dotfiles/script/setup-claude-code.sh"
bash "$HOME/dotfiles/script/setup-claude-desktop.sh"

if [ "${DOTFILES_INSTALL_SKILLS:-}" = "1" ]; then
    bash "$HOME/dotfiles/script/bootstrap-agents.sh"
fi

bash "$HOME/dotfiles/script/setup-cursor.sh"
bash "$HOME/dotfiles/script/setup-vscode.sh"
bash "$HOME/dotfiles/script/setup-antigravity.sh"
bash "$HOME/dotfiles/script/setup-obsidian.sh"

echo ""
echo -e "\033[1;35m Fonts \033[0m"
echo ""

# Nerd fonts - only Hack
brew install --cask font-hack-nerd-font

echo ""
echo -e "\033[1;35m kitty \033[0m"
echo ""

brew install --cask kitty

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

# micro editor
brew install micro
micro -plugin list 2>/dev/null | grep -q editorconfig || micro -plugin install editorconfig
micro -plugin list 2>/dev/null | grep -q fish        || micro -plugin install fish
micro -plugin list 2>/dev/null | grep -q fzf         || micro -plugin install fzf
ln -sfn $HOME/dotfiles/.config/micro/bindings.json $HOME/.config/micro/bindings.json

# neovim
brew install nvim
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

brew install tmux # tmux - https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/
brew install lf   # IF file manager - https://www.joshmedeski.com/posts/manage-files-with-lf/
brew install fzf
brew install lazygit
brew install commitizen

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

brew install fish
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
fish "$HOME/dotfiles/script/setup_fishshell.sh"

# Remove outdated versions from the cellar.
brew cleanup && brew doctor

echo ""
echo -e "\033[1;35m cron service script \033[0m"
echo ""

CRON_PLIST_SRC="$HOME/bin2/com.mingster.crontab.plist"
CRON_PLIST_DST="/Library/LaunchAgents/com.mingster.crontab.plist"

cron_warn() {
    echo -e "\033[1;33mWarning:\033[0m $*" >&2
}

if [[ -f "$CRON_PLIST_SRC" ]]; then
    sudo cp "$CRON_PLIST_SRC" "$CRON_PLIST_DST" || cron_warn "could not copy crontab plist to $CRON_PLIST_DST"
else
    cron_warn "$CRON_PLIST_SRC not found; skipping LaunchAgent plist install."
fi

sudo -v

shopt -s nullglob
bin2_scripts=("$HOME/bin2"/*.sh)
shopt -u nullglob
if ((${#bin2_scripts[@]} > 0)); then
    chmod 755 "${bin2_scripts[@]}" || cron_warn "could not chmod scripts in $HOME/bin2/"
else
    cron_warn "no *.sh in $HOME/bin2/; skipping chmod."
fi

if [[ -f "$CRON_PLIST_DST" ]]; then
    sudo chmod 644 "$CRON_PLIST_DST" || cron_warn "could not chmod $CRON_PLIST_DST"
    sudo chown "$USER:staff" "$CRON_PLIST_DST" || cron_warn "could not chown $CRON_PLIST_DST"

    # test
    # plutil "$CRON_PLIST_DST"

    #launchctl bootout gui/501 "$CRON_PLIST_DST"
    #launchctl enable user/501/~/Library/LaunchAgents/com.mingster.crontab.plist
    #launchctl bootstrap gui/501 "$HOME/Library/LaunchAgents/com.mingster.crontab.plist"

    # Load task (may fail on newer macOS; bootstrap as root may be required)
    _load_out=$(launchctl load "$CRON_PLIST_DST" 2>&1) || cron_warn "launchctl load failed: ${_load_out}"
    # Remove task
    #launchctl unload ~/Library/LaunchAgents/com.mingster.crontab.plist

    # Manually execute task
    _start_out=$(launchctl start "$CRON_PLIST_DST" 2>&1) || cron_warn "launchctl start failed: ${_start_out}"

    # List all tasks
    #launchctl list | grep mingster
else
    cron_warn "$CRON_PLIST_DST not present; skipping chmod/chown and launchctl load/start."
fi

sh $HOME/dotfiles/mac/install_my_software.sh
