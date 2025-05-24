#!/usr/bin/env bash

echo ""
echo -e "\033[1;35mSystem Setup for macos\033[0m"
echo ""

# Install command-line tools using Homebrew.
sh $HOME/dotfiles/mac/osxprep.sh

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
    echo "Installing homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

architecture=$(uname -m)
if [ "$architecture" == "arm64" ]; then
    #echo "This Mac is using Apple Silicon."
    # Add to path (only apple silicon macbooks)
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> $HOME/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ "$architecture" == "x86_64" ]; then
    #echo "This Mac is using Intel."
    eval "$(/usr/local/brew shellenv)"
else
    echo "Unknown architecture: $architecture"
fi

# Make sure we’re using the latest Homebrew.
brew update && brew upgrade

# create missing directories and files
if [ ! -d ${HOME}/.local/bin ]; then
    rm -rf ${HOME}/.local/bin
    #mkdir -p ${HOME}/.local/bin
    #cp ./bin/* ${HOME}/.local/bin/
fi
ln -s -f ${HOME}/dotfiles/mac/bin ${HOME}/.local/bin
chmod +x ${HOME}/.local/bin/*

#ln -s $HOME/GitHub/dotfiles $HOME
#ln -s $HOME/dotfiles/bin $HOME/


echo ""
echo -e "\033[1;35m essential apps \033[0m"
echo ""
brew install --cask google-chrome
brew install --cask megasync

# Install essential binaries.
#brew install iftop iperf nmap tcpflow tcptrace tcpreplay nano svn
brew install mas git gh rsync wget curl unzip neofetch kdiff3 jq trash bat rar
brew install asdf

cp $HOME/dotfiles/.gitconfig-macos $HOME/.gitconfig

# set up cli access for github
gh auth login


echo ""
echo -e "\033[1;35m create missing directories and files \033[0m"
echo ""
if [ ! -d ${HOME}/.config ]; then
    mkdir -p ${HOME}/.config
fi

mkdir -p $HOME/.config/{micro,fish}

echo ""
echo -e "\033[1;35m Fonts \033[0m"
echo ""

# Nerd fonts - Powerline-patched fonts. I use Hack.
brew tap homebrew/cask-fonts
brew install font-hack-nerd-font

echo ""
echo -e "\033[1;35m kitty \033[0m"
echo ""

brew install --cask kitty

if [ ! -d ${HOME}/.config/kitty ]; then
    rm -rf ${HOME}/.config/kitty
fi
ln -s $HOME/dotfiles/.config/kitty $HOME/.config/

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
micro -plugin install editorconfig
micro -plugin install fish
micro -plugin install fzf
ln -s $HOME/dotfiles/.config/micro/bindings.json $HOME/.config/micro/

# neovim
brew install nvim
ln -s $HOME/dotfiles/.config/nvim $HOME/.config/

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

ln -s $HOME/dotfiles/.config/lazygit/config.yml ~/Library/Application\ Support/lazygit/config.yml
ln -s $HOME/dotfiles/.config/tmux $HOME/.config/
ln -s $HOME/dotfiles/.config/lf $HOME/.config/
ln -s $HOME/dotfiles/.config/lazygit $HOME/.config/

# nano
#brew install nano
if [ ! -d ${HOME}/GitHub ]; then
    mkdir -p ${HOME}/GitHub
fi

git clone https://github.com/scopatz/nanorc.git ~/GitHub/nanorc
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
rm -rf $HOME/.config/fish/config.fish
ln -s $HOME/dotfiles/.config/fish/config.fish $HOME/.config/fish/
#cp -rf -v $HOME/dotfiles/.config/fish ${HOME}/.config/

# add fish to system shell
echo $(which fish) | sudo tee -a /etc/shells

#
echo ' change default shell to fish'
#
chsh -s $(which fish)

# Remove outdated versions from the cellar.
brew cleanup && brew doctor


echo ""
echo -e "\033[1;35m cron service script \033[0m"
echo ""
sudo cp ~/bin2/com.mingster.crontab.plist /Library/LaunchAgents/

sudo -v
chmod 755 $HOME/bin2/*.sh
sudo chmod 644 /Library/LaunchAgents/com.mingster.crontab.plist
sudo chown $USER:staff /Library/LaunchAgents/com.mingster.crontab.plist

# test
# plutil /Library/LaunchAgents/com.mingster.crontab.plist

#launchctl bootout gui/501 /Library/LaunchAgents/com.mingster.crontab.plist
#launchctl enable user/501/~/Library/LaunchAgents/com.mingster.crontab.plist
#launchctl bootstrap gui/501 $HOME/Library/LaunchAgents/com.mingster.crontab.plist

# Load task
launchctl load /Library/LaunchAgents/com.mingster.crontab.plist
# Remove task
#launchctl unload ~/Library/LaunchAgents/com.mingster.crontab.plist

# Manually execute task
launchctl start /Library/LaunchAgents/com.mingster.crontab.plist

# List all tasks
#launchctl list | grep mingster
