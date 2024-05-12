#!/usr/bin/env bash

echo 'Run this file to: 1.osx settings adj; 2.install essential apps; 3.fish shell setup...'

# Install command-line tools using Homebrew.
sh ~/dotfiles/install_mac/osxprep.sh

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
  echo "Installing homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure we’re using the latest Homebrew.
brew update && brew upgrade

echo ""
echo -e "\033[1;35m essential apps \033[0m"
echo ""
brew install --cask iterm2
brew install --cask atom
brew install --cask macdown
brew install --cask readdle-spark
brew install --cask google-chrome
#brew install --cask firefox
#brew install --cask teamviewer
#brew install --cask skype
#brew install --cask slack
#brew install --cask dropbox
brew install --cask megasync
brew install --cask google-drive
#brew install --cask onedrive
#brew install --cask numi
#brew install --cask alfred
#brew install --cask keyboard-maestro
#1176895641  Spark – Email App by Readdle
#mas install 1176895641

# another tile window manager as backup
brew install --cask amethyst # Install Amethyst - https://ianyh.com/amethyst/
ln -s ~/dotfiles/.config/amethyst $HOME/.config/

# Add to path (only apple silicon macbooks)
#echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
#eval "$(/opt/homebrew/bin/brew shellenv)"

# Install essential binaries.
#brew install iftop iperf nmap tcpflow tcptrace tcpreplay nano svn
brew install mas git gh rsync wget curl unzip neofetch kdiff3 jq trash bat

cp ~/dotfiles/.gitconfig-macos ~/.gitconfig

echo ""
echo -e "\033[1;35m create missing directories and files \033[0m"
echo ""
if [ ! -d ${HOME}/.config ];
then
    mkdir -p ${HOME}/.config
fi

mkdir -p ~/.config/{micro,fish}

#ln -s ~/GitHub/dotfiles $HOME
ln -s ~/dotfiles/bin $HOME/


echo ""
echo -e "\033[1;35m fish shell \033[0m"
echo ""

brew install fish

cp -rf -v ~/dotfiles/.config/fish ${HOME}/.config/

# add fish to system shell
echo $(which fish) | sudo tee -a /etc/shells

#
echo ' change default shell to fish'
#
chsh -s $(which fish)

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

if [ ! -d ${HOME}/.config/kitty ];
then
    rm -rf ${HOME}/.config/kitty
fi
ln -s ~/dotfiles/.config/kitty $HOME/.config/

echo ""
echo -e "\033[1;35m alacritty \033[0m"
echo ""

brew install --cask alacritty

if [ ! -d ${HOME}/.config/alacritty ];
then
  rm -rf ${HOME}/.config/alacritty
fi
ln -s ~/dotfiles/.config/alacritty $HOME/.config/

git clone https://github.com/catppuccin/alacritty.git ~/dotfiles/.config/alacritty/catppuccin


# micro editor
brew install micro
micro -plugin install editorconfig
micro -plugin install fish
micro -plugin install fzf
ln -s ~/dotfiles/.config/micro/bindings.json $HOME/.config/micro/

# neovim
brew install nvim
ln -s ~/dotfiles/.config/nvim $HOME/.config/

# optional but recommended
if [ ! -d ${HOME}/.local/share/nvim ];
then
    mkdir -p ${HOME}/.local/share/nvim
fi

if [ ! -d ${HOME}/.local/state/nvim ];
then
    mkdir -p ${HOME}/.local/state/nvim
fi

if [ ! -d ${HOME}/.cache/nvim ];
then
    mkdir -p ${HOME}/.cache/nvim
fi


brew install tmux # tmux - https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/
brew install lf # IF file manager - https://www.joshmedeski.com/posts/manage-files-with-lf/
brew install fzf
brew install jesseduffield/lazygit/lazygit

ln -s ~/dotfiles/.config/tmux $HOME/.config/
ln -s ~/dotfiles/.config/lf $HOME/.config/
ln -s ~/dotfiles/.config/lazygit $HOME/.config/


# Install Yabai
brew install koekeishiya/formulae/yabai
# Install Skhd
brew install koekeishiya/formulae/skhd

ln -s ~/dotfiles/.config/yabai $HOME/.config/
ln -s ~/dotfiles/.config/sxhkd/skhdrc.mac $HOME/.skhdrc

# install sketchybar
brew install FelixKratz/formulae/sketchybar
ln -s ~/dotfiles/.config/sketchybar $HOME/.config/

brew install font-sf-pro
brew install --cask sf-symbols
curl -L https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.18/sketchybar-app-font.ttf \
  -o $HOME/Library/Fonts/sketchybar-app-font.ttf

curl -L https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.18/icon_map_fn.sh \
  -o ~/dotfiles/.config/sketchybar/plugins/icon_map_fn.sh

chmod +x ~/.config/sketchybar/*.sh
chmod +x ~/.config/sketchybar/plugins/*.sh
chmod +x ~/.config/sketchybar/items/*.sh

# Remove outdated versions from the cellar.
brew cleanup && brew doctor
