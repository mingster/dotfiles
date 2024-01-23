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
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure we’re using the latest Homebrew.
brew update && brew upgrade

# Install some CTF tools; see https://github.com/ctfs/write-ups.
#brew install iftop iperf nmap tcpflow tcptrace tcpreplay nano svn

# Install essential binaries.
brew install mas

#1176895641  Spark – Email App by Readdle
#mas install 1176895641

# essential cask apps
brew install --cask iterm2
brew install --cask atom
brew install --cask macdown
brew install --cask google-chrome
#brew install --cask firefox
#brew install --cask teamviewer
brew install --cask skype
#brew install --cask slack
#brew install --cask dropbox
brew install --cask megasync
brew install --cask onebox
#brew install --cask numi
#brew install --cask alfred
#brew install --cask keyboard-maestro

# Remove outdated versions from the cellar.
brew cleanup && brew doctor


# 先執行這行，才能用 homebrew 安裝字型。曾經執行過的人可以跳過這個指令
#brew tap homebrew/cask-fonts
# 安裝指令
#brew install --cask font-sourcecodepro-nerd-font

##zsh
#oh-my-zsh
# https://github.com/robbyrussell/oh-my-zsh
#sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended
git clone https://github.com/robbyrussell/oh-my-zsh.git ~/.oh-my-zsh
cp ../.zshrc ~/

# font for powerlevel9k theme
cd ~/Library/Fonts && curl -fLo "Droid Sans Mono for Powerline Nerd Font Complete.otf" https://github.com/ryanoasis/nerd-fonts/raw/master/patched-fonts/DroidSansMono/complete/Droid%20Sans%20Mono%20Nerd%20Font%20Complete.otf

# powerlevel10k theme
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k

# powerlevel9k theme
#git clone https://github.com/bhilburn/powerlevel9k.git ~/.oh-my-zsh/custom/themes/powerlevel9k

#zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions

#brew install zsh
#use mac built-in zsh
chsh -s $(which zsh)
