#!/usr/bin/env bash

echo 'Run this file to: 1.osx settings adj; 2.install essential apps; 3.fish shell setup...'

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
brew install mas neofetch git rsync micro kdiff3

brew install fish
brew install tmux # tmux - https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/
brew install nvim
brew install lf # IF file manager - https://www.joshmedeski.com/posts/manage-files-with-lf/
brew install  fzf

# lazygit
brew install jesseduffield/lazygit/lazygit

# Nerd fonts - Powerline-patched fonts. I use Hack.
brew tap homebrew/cask-fonts
brew install font-hack-nerd-font

# essential cask apps
brew install --cask iterm2
brew install --cask kitty

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


# Remove outdated versions from the cellar.
brew cleanup && brew doctor


if [ ! -d ${HOME}/.config ];
then
    mkdir -p ${HOME}/.config
fi

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

ln -s ~/GitHub/dotfiles $HOME
ln -s ~/dotfiles/bin $HOME/bin

ln -s ~/dotfiles/.config/kitty $HOME/.config/kitty

#ln -s ~/dotfiles/.config/fish $HOME/.config/fish
if [ ! -d ${HOME}/.config/fish ];
then
    mkdir -p ${HOME}/.config/fish
fi
cp -rf -v ~/dotfiles/.config/fish/ ${HOME}/.config/fish/

# add fish to system shell
echo $(which fish) | sudo tee -a /etc/shells

#
echo ' change default shell to fish'
#
chsh -s $(which fish)

ln -s ~/dotfiles/.config/tmux $HOME/.config/tmux
ln -s ~/dotfiles/.config/nvim $HOME/.config/nvim
ln -s ~/dotfiles/.config/lf $HOME/.config/lf
ln -s ~/dotfiles/.config/lazygit $HOME/.config/lazygit

# install node 20.12.2
nvm install v20.12.2

# install fish shell plug-ins
../script/setup_fishsell.sh
