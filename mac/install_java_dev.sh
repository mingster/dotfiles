#!/usr/bin/env bash

# Install command-line tools using Homebrew.

# Ask for the administrator password upfront.
sudo -v

# Keep-alive: update existing `sudo` time stamp until the script has finished.
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Make sure we’re using the latest Homebrew.
brew update

# Install Java
# brew install openjdk@11
sudo ln -sfn /usr/local/opt/openjdk@11/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-11.jdk
fish_add_path /usr/local/opt/openjdk@11/bin
set -gx CPPFLAGS "-I/usr/local/opt/openjdk@11/include"

## to remove prev installs
#sudo rm -fr $HOME/Library/Java/JavaVirtualMachines/*
#sudo rm -fr /Library/Java/JavaVirtualMachines/*

brew uninstall openjdk@11
brew list | grep -iE 'java|jdk|temurin'
for pkg in $(brew list | grep -iE 'java|jdk|temurin'); do brew uninstall $pkg; done


brew install curl jq unzip

# asdf - https://github.com/halcyon/asdf-java
asdf plugin add java https://github.com/halcyon/asdf-java.git

asdf list all java

asdf install java latest:adoptopenjdk-11

#asdf install java adoptopenjdk-11.0.24+8
#asdf global java adoptopenjdk-11.0.24+8
#sudo ln -sfn /usr/local/opt/openjdk@11/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-11.jdk
#sudo ln -s /usr/local//opt/homebrew/opt/openjdk@11 /Library/Java/JavaVirtualMachines

java -version

# set java_home
. $HOME/.asdf/plugins/java/set-java-home.fish

#brew tap caskroom/cask
#brew install java11
#brew install --cask oracle-jdk
#brew install --cask java8
#brew install ant
#brew install maven
#brew install gradle
#brew install android-sdk
#brew install android-ndk

#Manage Java enviornment - http://www.jenv.be
#brew install jenv

#############################################
# https://gist.github.com/patrickhammond/4ddbe49a67e5eb1b9c03
#############################################

# Update environment variables:
#export ANT_HOME=/usr/local/opt/ant
#export MAVEN_HOME=/usr/local/opt/maven
#export GRADLE_HOME=/usr/local/opt/gradle

#export PATH=$ANT_HOME/bin:$PATH
#export PATH=$MAVEN_HOME/bin:$PATH
#export PATH=$GRADLE_HOME/bin:$PATH

#brew install Caskroom/cask/android-sdk
brew install --cask --appdir="/Applications/_dev" android-studio
#brew install --cask --appdir="/Applications/_dev" eclipse-java
brew install --cask --appdir="/Applications/_dev" intellij-idea-ce

# Remove outdated versions from the cellar.
brew cleanup

# Periodically run these commands again to ensure you're staying up to date:
#android update sdk --no-ui
