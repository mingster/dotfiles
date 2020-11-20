#!/usr/bin/env bash

# Install command-line tools using Homebrew.
sh ./osxprep.sh

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Check for Homebrew,
# Install if we don't have it
if test ! $(which brew); then
  echo "Installing homebrew..."
  /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
fi

# Make sure we’re using the latest Homebrew.
brew update && brew upgrade

# Install some CTF tools; see https://github.com/ctfs/write-ups.
brew install iftop iperf nmap tcpflow tcptrace tcpreplay

# Install essential binaries.
brew install mas

# essential cask apps
brew cask install iterm2
brew cask install atom
brew cask install macdown
brew cask install google-chrome
brew cask install firefox
brew cask install teamviewer
brew cask install skype
#brew cask install slack
brew cask install dropbox
brew cask install megasync
brew cask install numi
#brew cask install alfred
#brew cask install keyboard-maestro
brew cask install --appdir="/Applications/Utilities" onyx

# Development tool casks
mkdir /Applications/_dev
brew cask install --appdir="/Applications/_dev" github
brew cask install --appdir="/Applications/_dev" sourcetree
brew cask install --appdir="/Applications/_dev" staruml
brew cask install --appdir="/Applications/_dev" visual-studio-code


# Remove outdated versions from the cellar.
brew cleanup && brew doctor

# https://github.com/ryanoasis/nerd-fonts/releases/download/v2.1.0/SourceCodePro.zip

cd ~/Library/Fonts && curl -fLo "Droid Sans Mono for Powerline Nerd Font Complete.otf" https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/DroidSansMono/complete/Droid%20Sans%20Mono%20Nerd%20Font%20Complete.otf
#cd ~/Library/Fonts && curl -fLo "Sauce Code Pro Medium Nerd Font Complete.ttf" https://github.com/ryanoasis/nerd-fonts/blob/master/patched-fonts/SourceCodePro/Regular/complete/Sauce%20Code%20Pro%20Nerd%20Font%20Complete.ttf

brew tap homebrew/cask-fonts && brew cask install font-source-code-pro

# 先執行這行，才能用 homebrew 安裝字型。曾經執行過的人可以跳過這個指令
#brew tap homebrew/cask-fonts
# 安裝指令
#brew cask install font-sourcecodepro-nerd-font

##zsh
#oh-my-zsh
# https://github.com/robbyrussell/oh-my-zsh
#sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended
git clone https://github.com/robbyrussell/oh-my-zsh.git ~/.oh-my-zsh
cp ../.zshrc ~/

#powerlevel9k theme
git clone https://github.com/bhilburn/powerlevel9k.git ~/.oh-my-zsh/custom/themes/powerlevel9k

#zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

#brew install zsh
#use mac built-in zsh
chsh -s $(which zsh)
