#!/bin/bash

sudo pacman -Syu

sudo pacman -S --needed --noconfirm base-devel git

cd /tmp

git clone https://aur.archlinux.org/yay-git.git

sudo mv yay-git /opt/

cd /opt/yay-git

makepkg -si

# Install GitHub Desktop
yay -S github-desktop-bin --noconfirm


# Update GitHub Desktop
# yay -Syu --devel --timeupdate


# Remove GitHub Desktop
# yay -Rns github-desktop-bin --noconfirm
