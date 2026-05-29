#!/usr/bin/env bash

# Install Java
# brew install openjdk@11
#sudo ln -sfn /usr/local/opt/openjdk@11/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-11.jdk
#fish_add_path /usr/local/opt/openjdk@11/bin
#set -gx CPPFLAGS "-I/usr/local/opt/openjdk@11/include"

## to remove prev installs
#sudo rm -fr $HOME/Library/Java/JavaVirtualMachines/*
#sudo rm -fr /Library/Java/JavaVirtualMachines/*

#brew list | grep -iE 'java|jdk|temurin'
#for pkg in $(brew list | grep -iE 'java|jdk|temurin'); do brew uninstall $pkg; done

#brew install curl jq unzip
#brew install openjdk@11

echo '---- install open jdk ----'


# asdf - https://github.com/halcyon/asdf-java
asdf plugin list 2>/dev/null | grep -q '^java$' || asdf plugin add java https://github.com/halcyon/asdf-java.git

#asdf list all java
asdf list java 2>/dev/null | grep -q 'openjdk-21' || asdf install java openjdk-21
asdf set -u java openjdk-21

grep -qF 'java_macos_integration_enable=yes' "$HOME/.asdfrc" 2>/dev/null || echo 'java_macos_integration_enable=yes' >> "$HOME/.asdfrc"

java --version

# set java_home
#. $HOME/.asdf/plugins/java/set-java-home.fish

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
brew list --cask android-studio  >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" android-studio
brew list --cask intellij-idea-ce >/dev/null 2>&1 || brew install --cask --appdir="/Applications/_dev" intellij-idea-ce

# Remove outdated versions from the cellar.
brew cleanup
