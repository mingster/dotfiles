#!/usr/bin/env bash

# Install Java
# https://wiki.archlinux.org/title/java
sudo pacman -S jdk11-openjdk
java -version

sudo pacman -S gradle

# ide
yay -S android-studio
yay -S intellij-idea-community-edition
