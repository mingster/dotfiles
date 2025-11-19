#!/usr/bin/env bash

# Install Java
# https://wiki.archlinux.org/title/java
rm -rf ~/.asdf/plugins/java
asdf plugin add java https://github.com/halcyon/asdf-java.git
asdf install java openjdk-21
asdf set -u java openjdk-21
echo 'java_macos_integration_enable=yes' >> ~/.asdfrc

java -version

#sudo pacman -S jdk11-openjdk
#sudo pacman -S gradle

# ide
yay -S android-studio
yay -S intellij-idea-community-edition
