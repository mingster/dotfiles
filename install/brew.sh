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
brew install mas neofetch git rsync micro meld

brew install fish
brew install tmux # tmux - https://www.joshmedeski.com/posts/manage-terminal-sessions-with-tmux/
brew install nvim
brew install lf # IF file manager - https://www.joshmedeski.com/posts/manage-files-with-lf/

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


ln -s ~/GitHub/dotfiles/bin $HOME/bin

ln -s ~/GitHub/dotfiles/.config/kitty $HOME/.config/kitty
ln -s ~/GitHub/dotfiles/.config/fish $HOME/.config/fish
ln -s ~/GitHub/dotfiles/.config/tmux $HOME/.config/tmux
ln -s ~/GitHub/dotfiles/.config/nvim $HOME/.config/nvim
ln -s ~/GitHub/dotfiles/.config/lf $HOME/.config/lf
ln -s ~/GitHub/dotfiles/.config/lazygit $HOME/.config/lazygit

# add fish to system shell
su
echo $(which fish) >> /etc/shells

#
# change shell to fish
#
chsh -s $(which fish)

## enter fish shell
fish

# install fisher - https://github.com/jorgebucaran/fisher
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher

# install shell theme
fisher install IlanCosman/tide@v6

# icon of lf
fisher install joshmedeski/fish-lf-icons

# Install z to quickly jump across known directories:
fisher install jethrokuan/z

# Install fzf, a CLI fuzzy-finder, and make it work amazingly well with fish:
brew install fzf && fisher install patrickf1/fzf.fish

# Install a plugin that avoids issues where fish doesn't recognize global npm scripts:
fisher install rstacruz/fish-npm-global

# Install a fish-compatible version of nvm:
fisher install jorgebucaran/nvm.fish

# install node 20.12.2
nvm install v20.12.2
