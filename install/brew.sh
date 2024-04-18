#!/usr/bin/env bash

echo 'Run this file to: 1.osx settings adj; 2.install essential apps; 3.zsh setup...'

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
brew install neofetch

brew install fish
#mkdir ~/.config/fish
ln -s ~/GitHub/dotfiles/.config/fish $HOME/.config/fish

# tmux - https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/
brew install tmux
ln -s ~/GitHub/dotfiles/.config/tmux $HOME/.config/tmux

brew install nvim
# lazyvim
# required
mkdir ~/.config
# optional but recommended
mkdir ~/.local/share/nvim
mkdir ~/.local/state/nvim
mkdir ~/.cache/nvim

ln -s ~/GitHub/dotfiles/.config/nvim $HOME/.config/nvim

#brew install stow

#1176895641  Spark – Email App by Readdle
#mas install 1176895641

# essential cask apps

#brew install borgbackup

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

# Remove outdated versions from the cellar.
brew cleanup && brew doctor



# IF file manager - https://www.joshmedeski.com/posts/manage-files-with-lf/
brew install lf
ln -s ~/GitHub/dotfiles/.config/lf $HOME/.config/lf


# Nerd fonts - Powerline-patched fonts. I use Hack.
brew tap homebrew/cask-fonts
brew install font-hack-nerd-font


# lazygit
brew install jesseduffield/lazygit/lazygit
ln -s ~/GitHub/dotfiles/.config/lazygit $HOME/.config/lazygit

# add fish to system shell
su
echo $(which fish) >> /etc/shells

# change shell to fish
chsh -s $(which fish)

# install fisher - https://github.com/jorgebucaran/fisher
## enter fish shell
fish
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

# install shell theme
fisher install IlanCosman/tide@v6

# icon of lf
fisher install joshmedeski/fish-lf-icons

# nvm
fisher install jorgebucaran/nvm.fish

nvm install v20.12.2
