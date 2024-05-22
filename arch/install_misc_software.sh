#!/bin/bash

sudo pacman -S telegram-desktop
sudo pacman -S libreoffice


# sudo pacman -S --needed --noconfirm base-devel git
# cd /tmp
# git clone https://aur.archlinux.org/yay-git.git
# sudo mv yay-git /opt/
# cd /opt/yay-git
# makepkg -si

## mega

cd /tmp && \
wget https://mega.nz/linux/repo/Arch_Extra/x86_64/megasync-x86_64.pkg.tar.zst && \
sudo pacman -U "$PWD/megasync-x86_64.pkg.tar.zst"

#yay -S megasync
