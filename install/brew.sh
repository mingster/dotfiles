#!/usr/bin/env bash

# Install command-line tools using Homebrew.

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
brew update

# Upgrade any already-installed formulae.
brew upgrade

# Replace cli with gnu/linux
./homebrew-install-gnu.sh

# Install some CTF tools; see https://github.com/ctfs/write-ups.
brew install iftop iperf nmap tcpflow tcptrace tcpreplay

# Install essential binaries.
brew install git
brew install node yarn nvm
mkdir ~/.nvm
export NVM_DIR="$HOME/.nvm"
. "/usr/local/opt/nvm/nvm.sh"

brew install mas

# Core casks
brew cask install iterm2
brew install jenv
#brew cask install --appdir="~/Applications" xquartz

# Development tool casks
#brew cask install sublime-text
#brew cask install virtualbox
#brew cask install vagrant
# Install Docker, which requires virtualbox
brew install docker
brew install boot2docker

brew cask install --appdir="/Applications/_dev" 0xed
brew cask install --appdir="/Applications/_dev" eclipse-ide
brew cask install --appdir="/Applications/_dev" github-desktop
brew cask install --appdir="/Applications/_dev" jd-gui
brew cask install --appdir="/Applications/_dev" sourcetree
brew cask install --appdir="/Applications/_dev" staruml
brew cask install --appdir="/Applications/_dev" visual-studio-code
brew cask install --appdir="/Applications/_dev" wireshark

# essential apps
brew cask install atom
brew cask install macdown
brew cask install google-chrome
brew cask install firefox
brew cask install teamviewer
brew cask install skype
#brew cask install slack
brew cask install dropbox
brew cask install numi
brew cask install alfred
brew cask install keyboard-maestro
brew cask install --appdir="/Applications/Utilities" onyx

# Misc casks
brew cask install aerial #appletv screen saver
brew cask install welly #ptt telnet client
#brew cask install evernote
#brew cask install 1password
#brew cask install gimp
#brew cask install inkscape

#Remove comment to install LaTeX distribution MacTeX
#brew cask install mactex

# Install av staff
brew cask install --appdir="/Applications/_av" aegisub
brew cask install --appdir="/Applications/_av" handbrake
brew cask install --appdir="/Applications/_av" kid3
brew cask install --appdir="/Applications/_av" jubler
brew cask install --appdir="/Applications/_av" kid3

brew cask install --appdir="/Applications/_av" vox
brew cask install --appdir="/Applications/_av" iina

brew tap caskroom/versions
brew cask install google-chrome-canary

# Install developer friendly quick look plugins; see https://github.com/sindresorhus/quick-look-plugins
#brew cask install qlcolorcode qlstephen qlmarkdown quicklook-json qlprettypatch quicklook-csv betterzipql qlimagesize webpquicklook suspicious-package

# install packages listed in Brewfile
#### review Brewfile and manaully pick the app to install ###
#brew bundle

# Remove outdated versions from the cellar.
brew cleanup

# check
brew doctor
