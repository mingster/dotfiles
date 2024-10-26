#!/bin/bash

sudo pacman -S telegram-desktop
sudo pacman -S libreoffice


# sudo pacman -S --needed --noconfirm base-devel git
# cd /tmp
# git clone https://aur.archlinux.org/yay-git.git
# sudo mv yay-git /opt/
# cd /opt/yay-git
# makepkg -si

##
## mega sync
##

#sudo pacman -S megasync
# https://aur.archlinux.org/packages/megasync-bin
#yay -S megasync
#yay -S dolphin-megasync-git

yay -S --noconfirm icu74 megasync-bin
yay -S --noconfirm obsidian

yay -S --noconfirm ktorrent

#
# asdf
# https://asdf-vm.com/guide/getting-started.html
cd /tmp && git clone https://aur.archlinux.org/asdf-vm.git && cd asdf-vm && makepkg -si
