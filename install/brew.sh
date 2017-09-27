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

# Install `wget` with IRI support.
brew install wget --with-iri

# Install more recent versions of some OS X tools.
brew install vim --override-system-vi

# Install some CTF tools; see https://github.com/ctfs/write-ups.
brew install iftop iperf nmap tcpflow tcptrace tcpreplay

# Install other useful binaries.
brew install git
brew install node yarn
brew install mas

# Core casks
brew cask install --appdir="~/Applications" iterm2
#brew cask install --appdir="~/Applications" java
#brew cask install --appdir="~/Applications" xquartz

# Development tool casks
#brew cask install --appdir="/Applications" sublime-text
brew cask install --appdir="/Applications" atom
#brew cask install --appdir="/Applications" virtualbox
#brew cask install --appdir="/Applications" vagrant
brew cask install --appdir="/Applications" macdown
brew cask install --appdir="/Applications/_dev" 0xed
brew cask install --appdir="/Applications/_dev" android-studio
brew cask install --appdir="/Applications/_dev" eclipse-ide
brew cask install --appdir="/Applications/_dev" github-desktop
brew cask install --appdir="/Applications/_dev" jd-gui
brew cask install --appdir="/Applications/_dev" sourcetree
brew cask install --appdir="/Applications/_dev" staruml
brew cask install --appdir="/Applications/_dev" visual-studio-code
brew cask install --appdir="/Applications/_dev" wireshark

# Misc casks
brew cask install google-chrome
brew cask install firefox

brew cask install teamviewer

brew cask install skype
#brew cask install --appdir="/Applications" slack
brew cask install dropbox
#brew cask install --appdir="/Applications" evernote
#brew cask install --appdir="/Applications" 1password
#brew cask install --appdir="/Applications" gimp
#brew cask install --appdir="/Applications" inkscape

#Remove comment to install LaTeX distribution MacTeX
#brew cask install --appdir="/Applications" mactex

# Install Docker, which requires virtualbox
brew install docker
brew install boot2docker

# Install av staff
brew cask install --appdir="/Applications/_av" aegisub
brew cask install --appdir="/Applications/_av" handbrake
brew cask install --appdir="/Applications/_av" kid3
brew cask install --appdir="/Applications/_av" jubler
brew cask install --appdir="/Applications/_av" kid3

brew cask install --appdir="/Applications/_av" vox
brew cask install --appdir="/Applications/_av" vlc

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
