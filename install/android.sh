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
  ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
fi

# Make sure we’re using the latest Homebrew.
brew update

# Install Java
#brew tap caskroom/cask

brew cask install java8
brew cask install java
brew install ant
brew install maven
brew install gradle

#Manage Java enviornment - http://www.jenv.be
brew install jenv

brew tap homebrew/cask
brew cask install android-sdk

#############################################
# https://gist.github.com/patrickhammond/4ddbe49a67e5eb1b9c03
#############################################

# Update environment variables:
export ANT_HOME=/usr/local/opt/ant
export MAVEN_HOME=/usr/local/opt/maven
export GRADLE_HOME=/usr/local/opt/gradle

export PATH=$ANT_HOME/bin:$PATH
export PATH=$MAVEN_HOME/bin:$PATH
export PATH=$GRADLE_HOME/bin:$PATH

#brew install Caskroom/cask/android-sdk
brew cask install --appdir="/Applications/_dev" android-studio
#brew cask install --appdir="/Applications/_dev" eclipse-java
#brew cask install --appdir="/Applications/_dev" intellij-idea-ce


# Remove outdated versions from the cellar.
brew cleanup
